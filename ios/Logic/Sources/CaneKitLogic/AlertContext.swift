//
//  AlertContext.swift
//  CaneKitLogic
//
//  What the phone knew when a cane event fired, and how that becomes (a) extra fields on the
//  webhook payload and (b) a prompt for a cheap model that writes one family-facing sentence.
//
//  Why both: `note` on an `OpenCaneEvent` is the detector's own words ("Door ahead."). That is
//  precise and useless to a parent 40 miles away, who needs to know *where*, *how fast*, and
//  *whether the phone is about to die*. The deterministic fields answer that; the model sentence
//  makes it readable.
//
//  ⚠ The model NEVER authors `note`. A language model is not allowed to be the only factual line
//  in a safety alert — it goes in `extra.ai_context`, alongside the facts it was given, so the bot
//  (and a human reading the run log) can always check it against `extra`. If the model is slow,
//  wrong or unconfigured, the event still carries every fact it would have summarised.
//
//  Owner: `FamilyAlerts` (app) fills an `AlertContext` from `AppModel` per event; `AlertSummarizer`
//  (app) posts `AlertContextPrompt.text(…)` to whichever cheap model has a key.
//
//  Key invariants:
//    · Pure: no clock, no network, no truncation surprises — every limit here is a constant below.
//    · Every field is optional and omitted when nil: "unknown" must never arrive as 0 or "".
//    · Strings are truncated (`maxTextLength`) because an instruction is model output upstream and
//      could be arbitrarily long; the payload is read by an SMS writer, not a database.
//  Tests: AlertContextTests.swift.
//

import Foundation

/// The phone's state at the moment an event fired. Everything optional: a fix may be missing, the
/// simulator reports no battery, and a walker not on a route has no destination.
public struct AlertContext: Sendable, Equatable {
    /// True while a route is being walked.
    public var navigating: Bool = false
    /// Where the walker is heading ("CIF").
    public var destination: String?
    /// The current spoken navigation instruction ("Cross Springfield Avenue").
    public var instruction: String?
    /// Metres to the next waypoint.
    public var distanceToNextM: Double?
    /// Phone battery 0–100; nil when unknown.
    public var batteryPct: Int?
    /// `ProcessInfo` thermal state name — a hot phone drops obstacle naming, which family may
    /// need to know if the walker says the app went quiet.
    public var thermalState: String?
    /// Ground speed m/s. Zero-ish with a `fall` is a very different story from 1.4 m/s.
    public var speedMps: Double?
    /// Degrees from true north.
    public var headingDeg: Double?
    /// Obstacle cue active at that moment ("left" / "center" / "right" / "head" / "clear").
    public var activeCue: String?
    /// Last LiDAR ground hazard spoken ("Two meters ahead, drop-off.").
    public var lastGroundHazard: String?
    /// True when the phone had a usable GPS fix; false says the coordinates are stale or absent,
    /// which changes how much a family member should trust the position.
    public var hasFix: Bool = false

    public init() {}

    /// Longest string kept for any one text field. Long enough for a full instruction, short
    /// enough that the whole payload stays a readable webhook body.
    public static let maxTextLength = 160

    /// The extra fields for `OpenCaneEvent.extra`. Nil fields are omitted entirely, so the bot can
    /// tell "unknown" from "zero"; text is truncated to `maxTextLength`.
    public func extraFields() -> [String: OpenCaneJSON] {
        var out: [String: OpenCaneJSON] = ["navigating": .bool(navigating), "has_fix": .bool(hasFix)]
        func put(_ key: String, _ text: String?) {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            out[key] = .string(String(text.prefix(Self.maxTextLength)))
        }
        put("destination", destination)
        put("instruction", instruction)
        put("thermal_state", thermalState)
        put("active_cue", activeCue)
        put("last_ground_hazard", lastGroundHazard)
        if let distanceToNextM, distanceToNextM.isFinite {
            out["distance_to_next_m"] = .number((distanceToNextM * 10).rounded() / 10)
        }
        if let batteryPct, batteryPct >= 0 { out["battery_pct"] = .number(Double(batteryPct)) }
        if let speedMps, speedMps.isFinite, speedMps >= 0 {
            out["speed_mps"] = .number((speedMps * 10).rounded() / 10)
        }
        if let headingDeg, headingDeg.isFinite { out["heading_deg"] = .number(headingDeg.rounded()) }
        return out
    }
}

/// Builds the prompt that asks a cheap model for one sentence a family member can act on.
public enum AlertContextPrompt {
    /// Sentences the model may return. One: this becomes an SMS.
    public static let maxSentences = 2
    /// Hard ceiling on the reply, enforced again on the app side (`AlertSummarizer.clean`).
    public static let maxReplyCharacters = 240

    /// The instruction + the facts, as plain text. Deliberately not JSON-in-JSON: a small model
    /// follows a labelled list more reliably than it re-reads its own input format.
    ///
    /// The bans matter. Without them a cheap model reliably invents a reassurance ("they are
    /// fine", "help is on the way") that nobody has any basis for, and that is the single worst
    /// sentence this system could text to a parent.
    public static func text(eventType: String, severity: String?, note: String?,
                            lat: Double?, lng: Double?, context: AlertContext) -> String {
        var lines: [String] = []
        lines.append("event: \(eventType)")
        if let severity { lines.append("severity: \(severity)") }
        if let note { lines.append("detector said: \(String(note.prefix(AlertContext.maxTextLength)))") }
        if let lat, let lng {
            lines.append("position: \(String(format: "%.5f", lat)), \(String(format: "%.5f", lng))")
        } else {
            lines.append("position: unknown")
        }
        lines.append("gps fix: \(context.hasFix ? "yes" : "no")")
        lines.append("on a route: \(context.navigating ? "yes" : "no")")
        if let d = context.destination { lines.append("destination: \(d)") }
        if let i = context.instruction { lines.append("current instruction: \(i)") }
        if let d = context.distanceToNextM { lines.append("metres to next waypoint: \(Int(d.rounded()))") }
        if let s = context.speedMps { lines.append("speed m/s: \(String(format: "%.1f", s))") }
        if let b = context.batteryPct, b >= 0 { lines.append("phone battery percent: \(b)") }
        if let t = context.thermalState { lines.append("phone thermal state: \(t)") }
        if let c = context.activeCue { lines.append("active obstacle cue: \(c)") }
        if let h = context.lastGroundHazard { lines.append("last ground hazard: \(h)") }

        return """
        You are writing one short status line about a blind person walking with the OpenCane \
        smart cane, to be read by their family.

        Write at most \(maxSentences) plain sentences, under \(maxReplyCharacters) characters. \
        State only what the facts below say. Be calm and specific.

        Never do any of these:
        - never say the person is safe, fine, unharmed, or that help is coming — nobody knows that
        - never invent a street, building, injury, or anything not listed below
        - never tell the family what to do
        - never mention JSON, fields, or that you are a model

        Facts:
        \(lines.joined(separator: "\n"))
        """
    }
}

/// Text-only request bodies for the two provider dialects the app already speaks. The *responses*
/// are parsed by the existing `VLMResponse.openAICompatible` / `.anthropic`, which read the same
/// shapes whether the request carried an image or not.
public enum TextRequest {
    /// Token ceiling for the reply.
    ///
    /// ⚠ This budget has to cover a REASONING model's thinking, not just its two sentences, and
    /// the visible answer is ~60 tokens of it. Measured against the real Muse endpoint on
    /// 2026-09-12, one alert prompt:
    ///
    /// | max_completion_tokens | reasoning_effort | reasoning tokens | result |
    /// |---|---|---|---|
    /// | 200  | low     | 197  | `finish_reason: length`, `content: null` |
    /// | 1024 | low     | 1021 | `finish_reason: length`, `content: null` |
    /// | 4096 | low     | 794  | 7.1 s — over `AlertSummarizer.requestTimeout` |
    /// | 4096 | minimal | 154  | 2.1 s, good sentence ← what ships |
    ///
    /// Both null cases would have failed **silently**: HTTP 200, no `ai_context`, every time.
    /// Same failure and same fix as `VLMRequest.openAIMaxTokens`. `AlertContextPrompt` is what
    /// keeps the visible reply short; this is only a ceiling on the thinking.
    public static let maxOutputTokens = 4096

    /// OpenAI `chat/completions` with a single user message.
    public static func openAICompatible(model: String, prompt: String,
                                        reasoningEffort: String? = nil) throws -> Data {
        struct Message: Encodable { let role = "user"; let content: String }
        struct Body: Encodable {
            let model: String
            let messages: [Message]
            let max_completion_tokens: Int
            let reasoning_effort: String?
        }
        return try JSONEncoder().encode(Body(model: model, messages: [Message(content: prompt)],
                                             max_completion_tokens: maxOutputTokens,
                                             reasoning_effort: reasoningEffort))
    }

    /// Anthropic Messages API with a single user message.
    public static func anthropic(model: String, prompt: String) throws -> Data {
        struct Content: Encodable { let type = "text"; let text: String }
        struct Message: Encodable { let role = "user"; let content: [Content] }
        struct Body: Encodable {
            let model: String
            let max_tokens: Int
            let messages: [Message]
        }
        return try JSONEncoder().encode(Body(model: model, max_tokens: maxOutputTokens,
                                             messages: [Message(content: [Content(text: prompt)])]))
    }
}
