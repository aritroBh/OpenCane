//
//  OnDeviceVision.swift
//  CaneKit
//
//  Scene understanding with no network and no API key, using only Apple frameworks:
//    · Vision `ClassifyImageRequest`          → what is in view (sidewalk, tree, bicycle, stairs …)
//    · Vision `RecognizeTextRequest`          → sign text ("SIDEWALK CLOSED", "DETOUR", "EXIT")
//    · Vision `DetectHumanRectanglesRequest`  → **where the people are** (iOS 18+; `HumanObservation`)
//    · Vision `RecognizeAnimalsRequest`       → dogs and cats (iOS 18+; `RecognizedObjectObservation`)
//    · Foundation Models (Apple's on-device LLM, iOS 26) → phrases those detections, plus the
//      LiDAR context the app passes in, as one sentence for a blind pedestrian. When Apple
//      Intelligence is off or the model is not downloaded, a deterministic template does it.
//
//  `OnDeviceVLMClient` plugs into the same `VLMClient` protocol as the cloud providers, so
//  "Where am I" and the hazard watch work offline, and are the automatic fallback when no cloud
//  key is set. The public Foundation Models API in iOS 26 takes text only, which is why Vision
//  does the seeing and the LLM only does the wording — it must never invent objects.
//
//  The classifier and the body detector are *different models*: on the real phone the 1,303-class
//  classifier can return 1,303 observations and none over the 0.25 confidence floor
//  (`vision_error: "no labels (1303 raw)"`, iPhone trip log 2026-09-11), while the body detector
//  still finds the people in the frame. That is why this file no longer relies on one model.
//
//  Owners / callers: `OnDeviceVLMClient` is built once by `VLMClientFactory.resolved(context:)` and
//  shared by `SceneDescriber` ("Where am I") and `HazardScanner` (hazard watch). `OnDeviceVision.detect`
//  is also called directly by `HazardScanner.scanSigns` (text only, every 3 s) and by
//  `SceneDescriber.grounded` / `groundedAnswer` / `withPeople` (evidence for the cloud gate and
//  the people line). `SceneContext` is `AppModel.sceneContext`.
//  Tests: none in this file can run in the simulator's Vision (see `classifyPass`); the pure
//  rules it feeds are pinned in CaneKitLogic — `SceneVocabularyTests` (words, `isFaithful`),
//  `PeopleAheadTests`, `DepthSnapshotTests`, `HazardTests` (`SignPolicy`). `OnDeviceHazards.map`
//  is checked on the Mac with `swift ios/scripts/vision_probe.swift ios/scripts/streetview`, and
//  the whole path by `make uitest-streetview`; the device check is "Where am I" in airplane mode.
//
//  Threading / isolation: everything here is `nonisolated` and Sendable. `detect` and its passes
//  are `@concurrent`, so they run on the global executor whoever calls them; the rest of
//  `OnDeviceVLMClient.describe` runs on the caller's executor. Vision requests are created
//  per call (they are value types); a `LanguageModelSession` is created per call too, so no state
//  is shared across concurrent requests. The three image passes are independent, so `detect` runs
//  them with `async let` on the global executor: the wall clock is the **slowest** of them, not
//  their sum (before this change classification and text ran in series).
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
    /// People and animals from Vision's dedicated detectors, with their normalized boxes.
    /// Distances are attached later, from the depth grid of the same frame (`OnDeviceVLMClient`).
    var sightings: [Sighting] = []

    /// `texts` + `textHeights` in the shape `SignPolicy.line(for:now:)` wants. A missing height
    /// counts as far (0), so it can never bypass the close-text rule (Muse, final review).
    var seenTexts: [SignPolicy.SeenText] {
        texts.enumerated().map { i, t in
            SignPolicy.SeenText(text: t.text, confidence: t.confidence,
                                height: i < textHeights.count ? textHeights[i] : 0,
                                box: i < textBoxes.count ? textBoxes[i] : nil)
        }
    }

    /// Hand-written because the tuple arrays are not `Equatable`: compares label names, text
    /// strings and sightings only — confidences, heights and boxes are ignored.
    static func == (a: VisionDetections, b: VisionDetections) -> Bool {
        a.labels.map(\.name) == b.labels.map(\.name) && a.texts.map(\.text) == b.texts.map(\.text)
            && a.sightings == b.sightings
    }
}

/// The text pass's three parallel arrays, boxed so they can cross an `async let`.
nonisolated struct TextDetections: Sendable {
    /// Recognized lines with confidence.
    var texts: [(text: String, confidence: Float)] = []
    /// Line-box height of each entry, as a fraction of the image height.
    var heights: [Float] = []
    /// Line-box position of each entry (nil = unknown).
    var boxes: [SignPolicy.SeenText.Box?] = []
}

/// Namespace for the Vision passes (`detect`) and the two trip-log side channels
/// (`lastClassify`, `lastPeople`) that `AppModel.wireDescriber` reads into `describe_result`.
nonisolated enum OnDeviceVision {

    /// Last scene-classification outcome (labels kept, or the error), for the trip log
    /// (`describe_result` → `labels` / `vision_error`). A silent `try?` hid that classification
    /// returned nothing in the simulator (Street View e2e).
    static let lastClassify = Mutex<(labels: [String], error: String?)>(([], nil))

    /// Labels below this confidence are noise for our purposes.
    static let labelThreshold: Float = 0.25
    /// Labels too generic to be worth saying. "people" / "adult" used to be here and were removed
    /// on purpose: people are said, via `SceneVocabulary` and the body detector.
    static let boringLabels: Set<String> = ["outdoor", "structure", "material", "blue_sky", "sky",
                                            "daytime", "night_sky", "land"]

    /// Last "Where am I" body / animal outcome ("2 person, 1 dog"), for the trip log
    /// (`describe_result` → `people`); "" when nothing was detected or the switch is off.
    ///
    /// Written by `OnDeviceVLMClient.describe`, not by the detector: the sign scanner calls
    /// `detect` every 3 s and would otherwise clear this between a description and the log line
    /// that reads it.
    static let lastPeople = Mutex("")

    /// Classify + read text + find bodies in one pass over a JPEG (already upright).
    ///
    /// The three Vision models are independent, so they run **concurrently** (`async let`): the
    /// added wall clock is bounded by the *slowest* pass, not by their sum. On the "Where am I"
    /// path text recognition is the long pole, so making classification and text concurrent makes
    /// that path faster than it was, and the body detectors have to be slower than the text pass
    /// before they cost anything at all. ⚠ Estimate, not a measurement: Vision's neural models do
    /// not run in the simulator, so the real per-pass times can only come from the phone (the
    /// `describe_result` → `ms` field in the trip log is the number to watch).
    /// - Parameters:
    ///   - readText: text recognition is the expensive half; skip it when not needed.
    ///   - classify: run the 1,303-class scene classifier.
    ///   - minTextHeight: smallest text to read, as a fraction of the image height (nil = Vision's
    ///     default, 1/32). Sign scans pass 1/128: 7.5 cm sign letters read from ≈ 7 m, not 1.7 m
    ///     (measured with ios/scripts/sign_probe.swift on the route frames).
    ///   - detectPeople: run the body + animal detectors. Off for the hazard watch (which runs
    ///     every 8 s while walking); on for "Where am I" (user-initiated, a few times a walk).
    /// `@concurrent`: runs on the global executor, never on the caller's actor (main).
    /// Never throws: a failed pass yields its empty result (and, for classification, an error in
    /// `lastClassify`). Callers: `OnDeviceVLMClient.describe`, `HazardScanner.scanSigns`
    /// (`classify: false`, `minTextHeight: 1/128`), `SceneDescriber.grounded` / `groundedAnswer`
    /// (defaults) and `SceneDescriber.withPeople` (people only).
    /// - Parameter jpeg: an upright JPEG from `DepthFrameProcessor.jpegSnapshot*`.
    /// - Returns: the detections; `sightings` carry no distance yet (`withDistances` adds it).
    @concurrent
    static func detect(jpeg: Data, readText: Bool = true, classify: Bool = true,
                       minTextHeight: Float? = nil, detectPeople: Bool = false) async -> VisionDetections {
        async let labelPass = classifyPass(jpeg: jpeg, run: classify)
        async let textPass = textPass(jpeg: jpeg, run: readText, minTextHeight: minTextHeight)
        async let bodyPass = bodyPass(jpeg: jpeg, run: detectPeople)

        let labels = await labelPass
        let text = await textPass
        let sightings = await bodyPass
        return VisionDetections(labels: labels, texts: text.texts, textHeights: text.heights,
                                textBoxes: text.boxes, sightings: sightings)
    }

    /// The scene classifier, or `[]` when `run` is false. Writes `lastClassify` either way.
    ///
    /// In the simulator this throws "Failed to create espresso context" (no neural-network
    /// context; even VNClassifyImageRequest pinned to the CPU returns all 1,303 labels at
    /// ~0 confidence), so scene words can only be tested on the phone or with
    /// ios/scripts/vision_probe.swift on the Mac. The error lands in `lastClassify`.
    @concurrent
    private static func classifyPass(jpeg: Data, run: Bool) async -> [(name: String, confidence: Float)] {
        guard run else { return [] }
        do {
            let raw = try await ClassifyImageRequest().perform(on: jpeg).map { ($0.identifier, $0.confidence) }
            // No top-N cut here: Vision's hierarchy gives parents and synonyms the same score,
            // so the first 8 were "conveyance, portal, window, people, adult, path, sidewalk,
            // road" and the crosswalk (56 %) was cut (Claude review workflow). SceneVocabulary
            // caps what is said; the log keeps the first 12.
            let labels = raw.filter { $0.1 >= labelThreshold && !boringLabels.contains($0.0) }
                .sorted { $0.1 > $1.1 }
                .map { (name: $0.0, confidence: $0.1) }
            let kept = labels.prefix(12).map { "\($0.name) \(Int($0.confidence * 100))%" }
            let rawCount = raw.count
            // When nothing clears the threshold, record what the best guesses actually
            // were. The phone's first real run logged "no labels (1303 raw)", which cannot
            // distinguish "the lens was against a wall, so Vision correctly saw nothing"
            // from "the classifier scores everything at zero on this device" — and those
            // call for opposite fixes. The top three raw scores separate them in one line,
            // and cost nothing on a path that already holds all 1,303.
            let best = raw.sorted { $0.1 > $1.1 }.prefix(3)
                .map { "\($0.0) \(Int($0.1 * 100))%" }.joined(separator: ", ")
            lastClassify.withLock {
                $0 = (kept, kept.isEmpty ? "no labels (\(rawCount) raw; best: \(best))" : nil)
            }
            return labels
        } catch {
            lastClassify.withLock { $0 = ([], String(describing: error)) }
            return []
        }
    }

    /// Sign / OCR text with its line boxes, or an empty result when `run` is false.
    /// `.fast` recognition with language correction, top candidate per line; a Vision error is
    /// swallowed (`try?`) into an empty result. Heights and boxes come from the same observation,
    /// so the three arrays stay index-aligned.
    /// - Parameter minTextHeight: `minimumTextHeightFraction`, or nil for Vision's 1/32 default.
    @concurrent
    private static func textPass(jpeg: Data, run: Bool, minTextHeight: Float?) async -> TextDetections {
        guard run else { return TextDetections() }
        var req = RecognizeTextRequest()
        req.recognitionLevel = .fast
        req.usesLanguageCorrection = true
        if let minTextHeight { req.minimumTextHeightFraction = minTextHeight }
        var out = TextDetections()
        if let obs = try? await req.perform(on: jpeg) {
            for o in obs {
                guard let c = o.topCandidates(1).first else { continue }
                out.texts.append((c.string, c.confidence))
                let r = o.boundingBox.cgRect
                out.heights.append(Float(r.height))
                out.boxes.append(.init(minX: Float(r.minX), maxX: Float(r.maxX), minY: Float(r.minY)))
            }
        }
        return out
    }

    /// People and animals, or `[]` when `run` is false.
    ///
    /// `DetectHumanRectanglesRequest` (iOS 18+, `Result = [HumanObservation]`) and
    /// `RecognizeAnimalsRequest` (iOS 18+, `Result = [RecognizedObjectObservation]`, identifiers
    /// "dog" / "cat") are two more independent models, so they run concurrently with each other
    /// too. Boxes come back as `NormalizedRect` in Vision's bottom-left origin on the upright
    /// JPEG — `NormalizedBox` keeps that convention and `PeopleAhead` / `DepthSnapshot` flip it.
    ///
    /// Only the exact identifiers "dog" and "cat" are accepted. iOS 27 adds `dogHead` / `catHead`
    /// to `RecognizeAnimalsRequest.Identifier`; matching those as well (or by prefix) would count
    /// one dog twice — a body observation and a head observation — and say "two dogs". Missing a
    /// dog seen only head-on is the cheaper mistake, and it keeps this off the iOS 27-only enum.
    ///
    /// `upperBodyOnly` stays at Apple's default (false, whole-body rectangles): it is the
    /// better-trodden path, and switching it on is a device probe, not a guess — a walker close
    /// enough that only their upper body is in frame is also close enough for the LiDAR lanes to
    /// have buzzed already. ⚠ Only verifiable on the phone: Vision's neural models do not run in
    /// the simulator ("Failed to create espresso context").
    @concurrent
    private static func bodyPass(jpeg: Data, run: Bool) async -> [Sighting] {
        guard run else { return [] }
        var humans = DetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        async let bodies = (try? await humans.perform(on: jpeg)) ?? []
        async let animals = (try? await RecognizeAnimalsRequest().perform(on: jpeg)) ?? []

        var out: [Sighting] = await bodies.map {
            Sighting(kind: .person, box: box(from: $0.boundingBox.cgRect), confidence: $0.confidence)
        }
        for a in await animals {
            guard let top = a.labels.max(by: { $0.confidence < $1.confidence }) else { continue }
            let kind: SightingKind? = switch top.identifier.lowercased() {
            case RecognizeAnimalsRequest.Animal.dog.rawValue: SightingKind.dog
            case RecognizeAnimalsRequest.Animal.cat.rawValue: SightingKind.cat
            default: nil
            }
            guard let kind else { continue }
            // The strictest of the two scores: `RecognizedObjectObservation.confidence` says
            // "there is an object here", its label says "and it is a dog". A confident box with
            // an uncertain label (0.9 / 0.35) must not clear the animal floor (Muse review).
            out.append(Sighting(kind: kind, box: box(from: a.boundingBox.cgRect),
                                confidence: min(a.confidence, top.confidence)))
        }
        return out
    }

    /// Vision's normalized rect (bottom-left origin) → the Foundation-only `NormalizedBox`
    /// CaneKitLogic works in, so the pure rules never import Vision.
    private static func box(from r: CGRect) -> NormalizedBox {
        NormalizedBox(minX: Float(r.minX), minY: Float(r.minY),
                      width: Float(r.width), height: Float(r.height))
    }
}

// MARK: - Path hazards from labels (on-device hazard watch)

/// The on-device half of the hazard watch: turns classification labels into a reply in the same
/// shape a cloud model gives (`"<word> ahead"` or `"NONE"`), which `HazardWatchPolicy` then
/// words as a caution. Used by `OnDeviceVLMClient.describe` in hazard mode only.
nonisolated enum OnDeviceHazards {
    /// EXACT Vision classification identifiers that mean "something that can be in the walking
    /// path" → the word to say. Exact, not substring: substring matching turned `license_plate`
    /// into "ice", `scone` into "cones" and `shopping_cart` into "a car" (review, checked against
    /// `VNClassifyImageRequest.supportedIdentifiers()`: it has no "cone" or "barrier" id; the closest,
    /// `road_safety_equipment`, is unmapped until a probe on a real cone photo shows it fires; the
    /// cloud model covers road-work gear). Cars, trucks and water are left out: they are always
    /// on a street and a whole-frame label says nothing about where.
    /// ⚠ `ios/scripts/vision_probe.swift` keeps a copy (`hazardMap`): change both together.
    static let map: [String: String] = [
        "fence": "a fence", "stairs": "stairs", "staircase": "stairs", "scooter": "a scooter",
        "bicycle": "a bicycle", "motorcycle": "a motorcycle", "pole": "a pole",
        "fire_hydrant": "a fire hydrant", "hydrant": "a fire hydrant", "bench": "a bench",
        "trash_can": "a trash can", "snow": "snow", "ice": "ice", "dog": "a dog",
    ]

    /// A hazard reply only when the depth sensor already sees something ahead (`lidarAhead`):
    /// the camera names what LiDAR confirmed, so a parked bike across the street stays silent, and
    /// railings that score "fence" 44–62 % all along the route (ios/scripts/streetview/README.md)
    /// do not chatter. The first label, in confidence order, that is ≥ 0.35 and in `map` wins.
    /// - Parameters:
    ///   - d: detections of the hazard-watch frame (labels only; text is not read in hazard mode).
    ///   - lidarAhead: true when `SceneContext.get()` is non-empty, i.e. `AppModel.contextLine`
    ///     saw something in the centre lane < 3 m, at head height, a ground hazard or a mesh hit.
    /// - Returns: `"<word> ahead"` (e.g. "a bench ahead") or `"NONE"`.
    static func reply(for d: VisionDetections, lidarAhead: Bool) -> String {
        guard lidarAhead else { return "NONE" }
        for (label, conf) in d.labels where conf >= 0.35 {
            if let say = map[label.lowercased()] { return "\(say) ahead" }
        }
        return "NONE"
    }
}

// MARK: - LiDAR context shared with the describer

/// The latest LiDAR facts the app knows ("1.4 meters ahead, obstacle. Two meters ahead,
/// drop-off."), written by AppModel on the main actor, read by the on-device client off-main.
/// Also the channel for the two settings and the one grid the describer needs but the
/// `VLMClient` protocol (jpeg in, sentence out) has nowhere to carry.
///
/// Every field is its own `Mutex`, so the class is Sendable without `@unchecked`: the main actor
/// writes, the on-device client (off main) reads. Owner: `AppModel.sceneContext`, created in
/// `AppModel.init` and passed to `VLMClientFactory.resolved` and `SceneDescriber`.
nonisolated final class SceneContext: Sendable {
    /// The LiDAR context line (`AppModel.contextLine(report)`), rewritten on every depth report
    /// by `AppModel.handle`; "" when nothing is noteworthy and cleared to "" on background and when
    /// "Both cameras" pauses ARKit (stale facts must not reach a description).
    private let text = Mutex("")
    /// LiDAR depths of the frame being described, in scene space. Written by `SceneDescriber`
    /// from `DepthFrameProcessor.jpegSnapshotWithDepth`, which takes the image and the grid in one
    /// critical section and only pairs them when their ARKit frame timestamps agree; empty when
    /// depth is unavailable, stale, or could not be proved to belong to that frame.
    private let depth = Mutex(DepthSnapshot.empty)
    /// "Name people ahead" (Hazards card). Read once per description.
    private let people = Mutex(true)
    /// `AppModel.mirrorLeftRight`: the mount swaps left and right, so the spoken direction must
    /// swap too (the camera image itself is never mirrored).
    private let mirror = Mutex(false)
    /// Did the on-device client already handle the people facts for this description?
    private let peopleDone = Mutex(false)

    /// Replaces the LiDAR context line. Caller: `AppModel` (main actor), ~30 Hz.
    func set(_ s: String) { text.withLock { $0 = s } }
    /// The current LiDAR context line ("" = LiDAR sees nothing noteworthy). Read by
    /// `OnDeviceVLMClient.describe` (facts, hazard gate) and `SceneDescriber.run` (captured once
    /// beside the JPEG, so the answer is paired with that frame's distance).
    func get() -> String { text.withLock { $0 } }

    /// Replaces the depth grid for the next description (`DepthSnapshot.empty` = no depth).
    /// One writer at a time: `SceneDescriber.isDescribing` allows one description at a time, and
    /// the hazard watch shares this client but returns before it reads depth (Muse review).
    func setDepth(_ d: DepthSnapshot) { depth.withLock { $0 = d } }

    /// Cleared by `SceneDescriber` before every description and set by `OnDeviceVLMClient` when it
    /// has run the body detectors and folded the people line into its own answer.
    ///
    /// A cloud primary answers "Where am I" without ever reaching the on-device client
    /// (`FallbackVLMClient` only falls back on a throw), so on a build with an API key the
    /// detectors would never run and a detected person would never be spoken while the Hazards
    /// card promised otherwise. `SceneDescriber` checks this flag and does the detection itself
    /// when it is still clear (adversarial review of this change).
    func setPeopleHandled(_ on: Bool) { peopleDone.withLock { $0 = on } }
    /// True when the on-device client already spoke for the people facts this description.
    func peopleHandled() -> Bool { peopleDone.withLock { $0 } }
    /// The depth grid of the frame being described.
    func getDepth() -> DepthSnapshot { depth.withLock { $0 } }

    /// Turns the people / animal detectors on or off (Hazards card toggle).
    func setPeopleEnabled(_ on: Bool) { people.withLock { $0 = on } }
    /// True when "Where am I" should run the body detectors.
    func peopleEnabled() -> Bool { people.withLock { $0 } }

    /// Mirrors the spoken left / right, like `LaneConfig.mirrorLeftRight` mirrors the lanes.
    func setMirrored(_ on: Bool) { mirror.withLock { $0 = on } }
    /// True when left and right must be swapped in speech.
    func mirrored() -> Bool { mirror.withLock { $0 } }
}

// MARK: - VLMClient conformance

/// The on-device "vision language model": Vision sees, Foundation Models (or a template) speaks.
/// Never throws in practice (every step degrades to a template or "NONE"), so it is the floor of
/// the fallback chain. It ignores any prompt other than `HazardPrompt.text` — which is why
/// `cloudPrimary` is nil for it and "Ask OpenCane" never reaches it.
nonisolated struct OnDeviceVLMClient: VLMClient {
    /// Display / log name; the fallback client shows "<cloud> + On-device".
    let name = "On-device"
    /// Its sentences already passed `SceneVocabulary.isFaithful`, so `SceneDescriber` speaks them
    /// as they are; running them through `CloudSceneGate` would cap the template's LiDAR-plus-scene
    /// pair back to the LiDAR line alone.
    let isOnDevice = true
    /// The app's shared side channel (LiDAR line, depth grid, people / mirror switches).
    let context: SceneContext

    /// Two modes, chosen by the prompt:
    ///   · hazard mode (`prompt == HazardPrompt.text`): labels only, no text, no people →
    ///     `OnDeviceHazards.reply` gated on the LiDAR line;
    ///   · anything else ("Where am I"; any other prompt is treated the same): labels + text +
    ///     people (when enabled) → facts → Apple's on-device model, spoken only if
    ///     `SceneVocabulary.isFaithful`, with the people line and the LiDAR line prefixed when the
    ///     model left them out; otherwise the deterministic `template`.
    /// Side effects: writes `OnDeviceVision.lastPeople` and, when people are enabled, sets
    /// `context.setPeopleHandled(true)` so `SceneDescriber` does not detect them twice.
    func describe(jpeg: Data, prompt: String) async throws -> String {
        let hazardMode = prompt == HazardPrompt.text
        // One LiDAR snapshot, taken as close to the frame as possible, for the facts, the prefix
        // and the template alike. Reading it again after the model replied (~0.7 s later) mixed
        // two moments on the real phone: "Half a meter ahead, obstacle… looks like a table. A
        // door is one meter ahead." (first iPhone run; the facts had said door, one meter).
        let lidar = context.get()
        let d0 = await OnDeviceVision.detect(jpeg: jpeg, readText: !hazardMode,
                                             detectPeople: !hazardMode && context.peopleEnabled())
        if hazardMode { return OnDeviceHazards.reply(for: d0, lidarAhead: !lidar.isEmpty) }
        // Distance for each body comes from the depth grid of the *same* frame, read inside the
        // detection's own box; nil stays nil, and the walker then hears a direction with no number.
        let d = Self.withDistances(d0, depth: context.getDepth())

        let people = PeopleAhead.line(d.sightings, mirrored: context.mirrored())
        let detected = PeopleAhead.nouns(d.sightings)
        // For the trip log: what the detectors saw, even when the sentence ends up saying nothing.
        OnDeviceVision.lastPeople.withLock { $0 = PeopleAhead.summary(d.sightings) }
        // Tell the describer it does not have to detect people itself (see `setPeopleHandled`).
        if context.peopleEnabled() { context.setPeopleHandled(true) }
        let facts = Self.facts(d, lidar: lidar, people: people)
        // The model's sentence is only used when it is faithful to the facts (names something that
        // was detected, invents no numbers); otherwise the deterministic template speaks.
        if let sentence = await Self.phrase(facts),
           SceneVocabulary.isFaithful(sentence, facts: facts,
                                      nouns: SceneVocabulary.narrationNouns(d.labels),
                                      detected: detected) {
            var out = sentence
            // A detected person is a fact, like the LiDAR distance: unless the model's sentence
            // carries the whole fact (every detected noun, every number), the authoritative line
            // is spoken too. The rule is `PeopleAhead.needsSpeaking` and it fails closed.
            if let people, PeopleAhead.needsSpeaking(people, given: sentence, detected: detected) {
                out = people + " " + out
            }
            // The LiDAR fact is the safety-relevant one: say it first, as the template does,
            // unless the model already gave its distance (Claude review workflow: the model
            // dropped "1.4 meters ahead, obstacle" entirely).
            if !lidar.isEmpty, !SceneVocabulary.mentionsDistance(sentence, from: lidar) { return lidar + " " + out }
            return out
        }
        return Self.template(d, lidar: lidar, people: people)
    }

    /// Attaches a distance to every sighting from the frame's depth grid (nil where LiDAR has
    /// nothing trustworthy). Pure plumbing; the geometry lives in `DepthSnapshot`.
    static func withDistances(_ d: VisionDetections, depth: DepthSnapshot) -> VisionDetections {
        guard !d.sightings.isEmpty, !depth.isEmpty else { return d }
        var out = d
        out.sightings = d.sightings.map { s in
            var s = s
            s.distance = depth.distance(inVisionBox: s.box)
            return s
        }
        return out
    }

    /// Plain-text facts handed to the language model (never the image). Scene labels go through
    /// `SceneVocabulary` first: raw Vision identifiers ("conveyance", "portal", "machine") were
    /// read out verbatim on the Street View mock of the route.
    /// - Parameters:
    ///   - d: this frame's detections, distances already attached.
    ///   - lidar: the LiDAR context line, or "".
    ///   - people: `PeopleAhead.line`, or nil when nothing was detected. It goes in above the
    ///     scene labels: a person is the thing a walker most needs named, and on the frames that
    ///     made this feature necessary it is the *only* thing the camera could say.
    static func facts(_ d: VisionDetections, lidar: String, people: String? = nil) -> String {
        var lines: [String] = []
        if !lidar.isEmpty { lines.append("Depth sensor: \(lidar)") }
        if let people { lines.append("People detector: \(people)") }
        let things = SceneVocabulary.narrationNouns(d.labels)
        if !things.isEmpty { lines.append("Camera sees: " + things.joined(separator: ", ")) }
        // One sign phrase at most: the sign policy already joins stacked safety words and rejects
        // storefront/OCR noise. Passing three raw lines invited the model to turn text into a
        // second scene inventory.
        var policy = SignPolicy()
        if let sign = policy.line(for: d.seenTexts, now: 0) {
            lines.append("Visible text: \"\(sign)\"")
        }
        return lines.isEmpty ? "Nothing detected." : lines.joined(separator: "\n")
    }

    /// Apple's on-device model, when available. nil → use the template.
    static func phrase(_ facts: String) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        // Street View mock: "Hazards and distances first" made the model answer "No hazards
        // detected. Distance: 0 meters." — so: name what is there, numbers only from the facts.
        let session = LanguageModelSession(instructions: """
            You tell a blind pedestrian what is around them using ONLY the facts given. One \
            sentence, under 20 words. Mention at most two listed scene items, choosing the most \
            useful or actionable ones and omitting background detail. Mention a distance only if \
            the facts give one, and use exactly that number. Never add an object or a number that is \
            not in the facts. Never say "no hazards". No preamble.
            """)
        guard let response = try? await session.respond(to: facts,
                                                        options: GenerationOptions(temperature: 0.2)) else { return nil }
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Deterministic fallback: "1.4 meters ahead, obstacle. About 3 meters ahead, two people.
    /// Ahead: a crosswalk, the street and cars. Sign: detour." Scene words come from
    /// `SceneVocabulary` (plain nouns, crossing first).
    ///
    /// This is the path that runs when Apple Intelligence is off, when the model produced nothing,
    /// or when its sentence failed the faithfulness gate — so the people line has to be here too,
    /// or a detected person could be silently dropped.
    /// - Parameters:
    ///   - d: this frame's detections, distances already attached.
    ///   - lidar: the LiDAR context line, or "".
    ///   - people: `PeopleAhead.line`, or nil.
    static func template(_ d: VisionDetections, lidar: String, people: String? = nil) -> String {
        var parts: [String] = []
        if !lidar.isEmpty { parts.append(lidar) }
        if let people { parts.append(people) }
        if let scene = SceneVocabulary.sentence(d.labels, max: SceneVocabulary.narrationMaxItems) {
            parts.append(scene)
        }
        var policy = SignPolicy()
        // Sized text, like the sign scanner: a tiny far "EXIT" must not be read here either.
        if let sign = policy.line(for: d.seenTexts, now: 0) { parts.append(sign) }
        return parts.isEmpty ? "Nothing recognized ahead." : parts.joined(separator: " ")
    }
}
