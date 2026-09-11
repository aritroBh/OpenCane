//
//  OnDeviceVision.swift
//  CaneKit
//
//  Scene understanding with no network and no API key, using only Apple frameworks:
//    · Vision `ClassifyImageRequest`  → what is in view (sidewalk, tree, bicycle, stairs …)
//    · Vision `RecognizeTextRequest`  → sign text ("SIDEWALK CLOSED", "DETOUR", "EXIT")
//    · Foundation Models (Apple's on-device LLM, iOS 26) → phrases those detections, plus the
//      LiDAR context the app passes in, as one sentence for a blind pedestrian. When Apple
//      Intelligence is off or the model is not downloaded, a deterministic template does it.
//
//  `OnDeviceVLMClient` plugs into the same `VLMClient` protocol as the cloud providers, so
//  "Where am I" and the hazard watch work offline, and are the automatic fallback when no cloud
//  key is set. The public Foundation Models API in iOS 26 takes text only, which is why Vision
//  does the seeing and the LLM only does the wording — it must never invent objects.
//
//  Threading / isolation: everything here is `nonisolated` and Sendable; work runs in the caller's
//  task (the describer / hazard scanner call it off the main actor). Vision requests are created
//  per call (they are value types); a `LanguageModelSession` is created per call too, so no state
//  is shared across concurrent requests.
//

import CaneKitLogic
import Foundation
import FoundationModels
import Synchronization
import Vision

// MARK: - Raw detections

/// What Vision found in one image.
nonisolated struct VisionDetections: Sendable, Equatable {
    /// Classification identifiers with confidence ≥ the threshold, most confident first.
    var labels: [(name: String, confidence: Float)]
    /// Recognized text lines with confidence.
    var texts: [(text: String, confidence: Float)]
    /// Line-box height of each entry in `texts`, as a fraction of the image height (same order).
    /// Lets `SignPolicy` require one-word phrases to be close (`shortPhraseMinHeight`).
    var textHeights: [Float] = []
    /// Line-box position of each entry in `texts` (same order), so far lines stacked on one sign
    /// can be joined ("SIDEWALK" over "CLOSED") while unrelated far words cannot.
    var textBoxes: [SignPolicy.SeenText.Box?] = []

    /// `texts` + `textHeights` in the shape `SignPolicy.line(for:now:)` wants. A missing height
    /// counts as far (0), so it can never bypass the close-text rule (Muse, final review).
    var seenTexts: [SignPolicy.SeenText] {
        texts.enumerated().map { i, t in
            SignPolicy.SeenText(text: t.text, confidence: t.confidence,
                                height: i < textHeights.count ? textHeights[i] : 0,
                                box: i < textBoxes.count ? textBoxes[i] : nil)
        }
    }

    static func == (a: VisionDetections, b: VisionDetections) -> Bool {
        a.labels.map(\.name) == b.labels.map(\.name) && a.texts.map(\.text) == b.texts.map(\.text)
    }
}

nonisolated enum OnDeviceVision {

    /// Last scene-classification outcome (labels kept, or the error), for the trip log
    /// (`describe_result` → `labels` / `vision_error`). A silent `try?` hid that classification
    /// returned nothing in the simulator (Street View e2e).
    static let lastClassify = Mutex<(labels: [String], error: String?)>(([], nil))

    /// Labels below this confidence are noise for our purposes.
    static let labelThreshold: Float = 0.25
    /// Labels too generic to be worth saying.
    static let boringLabels: Set<String> = ["outdoor", "structure", "material", "blue_sky", "sky",
                                            "daytime", "night_sky", "land"]

    /// Classify + read text in one pass over a JPEG (already upright).
    /// - Parameters:
    ///   - readText: text recognition is the expensive half; skip it when not needed.
    ///   - minTextHeight: smallest text to read, as a fraction of the image height (nil = Vision's
    ///     default, 1/32). Sign scans pass 1/128: 7.5 cm sign letters read from ≈ 7 m, not 1.7 m
    ///     (measured with ios/scripts/sign_probe.swift on the route frames).
    /// `@concurrent`: runs on the global executor, never on the caller's actor (main).
    @concurrent
    static func detect(jpeg: Data, readText: Bool = true, classify: Bool = true,
                       minTextHeight: Float? = nil) async -> VisionDetections {
        var labels: [(String, Float)] = []
        if classify {
            do {
                // In the simulator this throws "Failed to create espresso context" (no neural-network
                // context; even VNClassifyImageRequest pinned to the CPU returns all 1,303 labels at
                // ~0 confidence), so scene words can only be tested on the phone or with
                // ios/scripts/vision_probe.swift on the Mac. The error lands in `lastClassify`.
                let raw = try await ClassifyImageRequest().perform(on: jpeg).map { ($0.identifier, $0.confidence) }
                // No top-N cut here: Vision's hierarchy gives parents and synonyms the same score,
                // so the first 8 were "conveyance, portal, window, people, adult, path, sidewalk,
                // road" and the crosswalk (56 %) was cut (Claude review workflow). SceneVocabulary
                // caps what is said; the log keeps the first 12.
                labels = raw.filter { $0.1 >= labelThreshold && !boringLabels.contains($0.0) }
                    .sorted { $0.1 > $1.1 }
                    .map { ($0.0, $0.1) }
                let kept = labels.prefix(12).map { "\($0.0) \(Int($0.1 * 100))%" }
                let rawCount = raw.count
                lastClassify.withLock { $0 = (kept, kept.isEmpty ? "no labels (\(rawCount) raw)" : nil) }
            } catch {
                lastClassify.withLock { $0 = ([], String(describing: error)) }
            }
        }
        var texts: [(String, Float)] = []
        var heights: [Float] = []
        var boxes: [SignPolicy.SeenText.Box?] = []
        if readText {
            var req = RecognizeTextRequest()
            req.recognitionLevel = .fast
            req.usesLanguageCorrection = true
            if let minTextHeight { req.minimumTextHeightFraction = minTextHeight }
            if let obs = try? await req.perform(on: jpeg) {
                for o in obs {
                    guard let c = o.topCandidates(1).first else { continue }
                    texts.append((c.string, c.confidence))
                    let r = o.boundingBox.cgRect
                    heights.append(Float(r.height))
                    boxes.append(.init(minX: Float(r.minX), maxX: Float(r.maxX), minY: Float(r.minY)))
                }
            }
        }
        return VisionDetections(labels: labels, texts: texts, textHeights: heights, textBoxes: boxes)
    }

}

// MARK: - Path hazards from labels (on-device hazard watch)

nonisolated enum OnDeviceHazards {
    /// EXACT Vision classification identifiers that mean "something that can be in the walking
    /// path" → the word to say. Exact, not substring: substring matching turned `license_plate`
    /// into "ice", `scone` into "cones" and `shopping_cart` into "a car" (review, checked against
    /// `VNClassifyImageRequest.supportedIdentifiers()`: it has no "cone" or "barrier" id; the closest,
    /// `road_safety_equipment`, is unmapped until a probe on a real cone photo shows it fires; the
    /// cloud model covers road-work gear). Cars, trucks and water are left out: they are always
    /// on a street and a whole-frame label says nothing about where.
    static let map: [String: String] = [
        "fence": "a fence", "stairs": "stairs", "staircase": "stairs", "scooter": "a scooter",
        "bicycle": "a bicycle", "motorcycle": "a motorcycle", "pole": "a pole",
        "fire_hydrant": "a fire hydrant", "hydrant": "a fire hydrant", "bench": "a bench",
        "trash_can": "a trash can", "snow": "snow", "ice": "ice", "dog": "a dog",
    ]

    /// A hazard reply only when the depth sensor already sees something ahead (`lidarAhead`):
    /// the camera names what LiDAR confirmed, so a parked bike across the street stays silent.
    static func reply(for d: VisionDetections, lidarAhead: Bool) -> String {
        guard lidarAhead else { return "NONE" }
        for (label, conf) in d.labels where conf >= 0.35 {
            if let say = map[label.lowercased()] { return "\(say) ahead" }
        }
        return "NONE"
    }
}

// MARK: - LiDAR context shared with the describer

/// The latest LiDAR facts the app knows ("Obstacle ahead at 1.4 meters. Drop-off ahead, two
/// meters."), written by AppModel on the main actor, read by the on-device client off-main.
nonisolated final class SceneContext: Sendable {
    private let text = Mutex("")
    func set(_ s: String) { text.withLock { $0 = s } }
    func get() -> String { text.withLock { $0 } }
}

// MARK: - VLMClient conformance

/// The on-device "vision language model": Vision sees, Foundation Models (or a template) speaks.
nonisolated struct OnDeviceVLMClient: VLMClient {
    let name = "On-device"
    let context: SceneContext

    func describe(jpeg: Data, prompt: String) async throws -> String {
        let hazardMode = prompt == HazardPrompt.text
        let d = await OnDeviceVision.detect(jpeg: jpeg, readText: !hazardMode)
        if hazardMode { return OnDeviceHazards.reply(for: d, lidarAhead: !context.get().isEmpty) }

        let facts = Self.facts(d, lidar: context.get())
        // The model's sentence is only used when it is faithful to the facts (names something that
        // was detected, invents no numbers); otherwise the deterministic template speaks.
        if let sentence = await Self.phrase(facts),
           SceneVocabulary.isFaithful(sentence, facts: facts, nouns: SceneVocabulary.nouns(d.labels, max: 5)) {
            // The LiDAR fact is the safety-relevant one: say it first, as the template does,
            // unless the model already gave its distance (Claude review workflow: the model
            // dropped "Obstacle ahead at 1.4 meters" entirely).
            let lidar = context.get()
            if !lidar.isEmpty, !sentence.lowercased().contains("meter") { return lidar + " " + sentence }
            return sentence
        }
        return Self.template(d, lidar: context.get())
    }

    /// Plain-text facts handed to the language model (never the image). Scene labels go through
    /// `SceneVocabulary` first: raw Vision identifiers ("conveyance", "portal", "machine") were
    /// read out verbatim on the Street View mock of the route.
    static func facts(_ d: VisionDetections, lidar: String) -> String {
        var lines: [String] = []
        if !lidar.isEmpty { lines.append("Depth sensor: \(lidar)") }
        let things = SceneVocabulary.nouns(d.labels, max: 5)
        if !things.isEmpty { lines.append("Camera sees: " + things.joined(separator: ", ")) }
        // Only text that looks like words: Street View OCR junk ("11", "J.I") became invented
        // distances in the model's sentence.
        // …and only text the sign rule would allow: a far lone word stays out of the prompt too.
        let policy = SignPolicy()
        let nearby = d.seenTexts.filter { $0.confidence >= 0.5 && policy.mayMention($0) }.map(\.text)
        let signs = SceneVocabulary.readableTexts(nearby).prefix(3)
        if !signs.isEmpty { lines.append("Visible text: " + signs.map { "\"\($0)\"" }.joined(separator: ", ")) }
        return lines.isEmpty ? "Nothing detected." : lines.joined(separator: "\n")
    }

    /// Apple's on-device model, when available. nil → use the template.
    static func phrase(_ facts: String) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        // Street View mock: "Hazards and distances first" made the model answer "No hazards
        // detected. Distance: 0 meters." — so: name what is there, numbers only from the facts.
        let session = LanguageModelSession(instructions: """
            You tell a blind pedestrian what is around them using ONLY the facts given. One \
            sentence, under 20 words. Name the listed things in plain words, in the order given. \
            Mention a distance only if the facts give one, and use exactly that number. Never add \
            an object or a number that is not in the facts. Never say "no hazards". No preamble.
            """)
        guard let response = try? await session.respond(to: facts,
                                                        options: GenerationOptions(temperature: 0.2)) else { return nil }
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Deterministic fallback: "Obstacle ahead at 1.4 meters. Ahead: a crosswalk, the street and
    /// cars. Sign: detour." Scene words come from `SceneVocabulary` (plain nouns, crossing first).
    static func template(_ d: VisionDetections, lidar: String) -> String {
        var parts: [String] = []
        if !lidar.isEmpty { parts.append(lidar) }
        if let scene = SceneVocabulary.sentence(d.labels) { parts.append(scene) }
        var policy = SignPolicy()
        // Sized text, like the sign scanner: a tiny far "EXIT" must not be read here either.
        if let sign = policy.line(for: d.seenTexts, now: 0) { parts.append(sign) }
        return parts.isEmpty ? "Nothing recognized ahead." : parts.joined(separator: " ")
    }
}
