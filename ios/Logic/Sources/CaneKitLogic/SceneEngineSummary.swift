//
//  SceneEngineSummary.swift
//  CaneKitLogic
//
//  The words on the Details tab's "Scene engine" card: which model actually answered the last
//  "Where am I", why the cloud was or was not used, how long it took, when, and what triggered it —
//  plus the same for the hazard watch and a one-line summary of the cue profile.
//
//  Why this exists: the owner asked for the Details tab to be *specific* about when Muse (the cloud
//  model) is used and when the on-device model answers instead ("we need this to be more
//  adaptive"). Until Step 47 the only evidence on screen was a pill saying "Muse + On-device", which
//  names the chain and nothing about any actual run. The app already knows the answer to every one
//  of those questions (`VLMAnswer`, `SceneDescriber`, `HazardScanner`); this file is only the
//  wording, kept pure so every string is unit-tested and the numbers in it (the 8 s watch interval,
//  the 2.5 s cloud deadline) are the app's real constants passed in, never literals typed twice.
//
//  Key invariants:
//    · **Words, never colour.** Every state has a sentence; the card carries no state that lives
//      only in a tint (docs/design.md §7).
//    · **Two spellings of each line**: `text` for the screen (short: "1.9 s", "2 min ago") and
//      `spoken` for VoiceOver (full words: "1.9 seconds", "2 minutes ago"), because VoiceOver
//      reads "s" as the letter.
//    · **Numbers come from the app's constants.** `SceneEngineFacts.hazardWatchIntervalS` and
//      `hazardCloudDeadlineS` are filled from `HazardWatchPolicy.interval` and
//      `FallbackVLMClient.hazardDeadline`; nothing here knows 8 or 2.5.
//    · **A failure is said as a failure.** "Where am I failed — <reason>" and "no camera frame";
//      never a blank row a reader could take for "nothing to report".
//
//  Owner: `SceneEngineCard` (ios/CaneKit/UI/ContentView.swift) builds one `SceneEngineFacts` from
//  `SceneDescriber`, `HazardScanner` and `AppModel` and renders `SceneEngineSummary.*`.
//  `DescribeTrigger` is also used by `SceneDescriber.describe(trigger:)` / `AppModel.describeScene(trigger:)`
//  and logged (`trigger`) in `describe` / `describe_result`.
//  Isolation: stateless and nonisolated; `SceneEngineFacts` is a plain `Sendable` value.
//  Tests: SceneEngineSummaryTests.swift.
//

import Foundation

/// Who asked for "Where am I". The raw value is written to the trip log (`describe {trigger}`,
/// `describe_result {trigger}`); `spoken` is the phrase the Scene engine card uses ("from the
/// watch"). Raw values are a log contract: add cases, never rename them.
public enum DescribeTrigger: String, Sendable, CaseIterable, Codable {
    /// The "Where am I" button on the Guide card (the default).
    case button
    /// The watch's Describe button (`WatchToPhone.describe`).
    case watch
    /// The Action button / Siri App Shortcut (`WhereAmIIntent`; the intent cannot tell the two
    /// apart, and a spoken "where am I" through the assistant is a `.question`). There is no
    /// separate Siri case on purpose: a case no caller can produce is a dead log contract.
    case actionButton
    /// A Camera Control / volume press while ARKit owns the camera (`AppModel.cameraControlPressed`).
    case cameraControl
    /// The `CANEKIT_DESCRIBE_EVERY_WAYPOINT` automation hook (route start and every waypoint).
    case waypoint
    /// "Ask OpenCane …" — a question about the frame, not a plain description.
    case question

    /// The phrase after "from" on the card and in VoiceOver. Pinned by `triggerWordsAreSpoken`.
    public var spoken: String {
        switch self {
        case .button: return "the Guide button"
        case .watch: return "the watch"
        case .actionButton: return "the Action button or Siri"
        case .cameraControl: return "Camera Control"
        case .waypoint: return "a waypoint"
        case .question: return "a question"
        }
    }
}

/// Everything the Scene engine card is allowed to know, gathered by the app. Plain data on purpose:
/// no engine types reach this package. `nil` everywhere means "never happened yet".
public struct SceneEngineFacts: Sendable, Equatable {
    /// The cloud model's display name ("Muse", "Gemini", …), or nil when the app runs on-device only.
    public var cloudName: String?
    /// The on-device client's display name ("On-device").
    public var onDeviceName: String

    /// Who wrote the last spoken "Where am I" / answer: `cloudName` or `onDeviceName`; nil when
    /// nothing has been asked yet or the last run failed.
    public var lastSource: String?
    /// Cloud round trip of the last run in ms, when the cloud was tried (it answered, or it failed
    /// after this long and the on-device client took over); nil when the cloud was not tried.
    public var lastCloudMs: Int?
    /// Wall-clock ms of the last successful client call (whoever answered). nil before the first.
    public var lastLatencyMs: Int?
    /// Why the cloud did not answer the last run ("The request timed out.", "HTTP 429: …"); nil
    /// when it answered or was not tried.
    public var lastFallbackReason: String?
    /// The `CloudSceneGate` verdict of the last run: "spoken", "edited: …", "refused: …",
    /// "on-device" (no gate needed), "error", "no frame"; nil before the first run.
    public var lastGate: String?
    /// The error of the last run when it failed ("No camera frame", a thrown description); nil
    /// otherwise.
    public var lastError: String?
    /// Seconds since the last run finished; nil before the first.
    public var secondsSinceLast: TimeInterval?
    /// What triggered the last run; nil before the first.
    public var lastTrigger: DescribeTrigger?

    /// The "Hazard watch" switch.
    public var hazardWatchOn: Bool
    /// `HazardWatchPolicy.interval` — seconds between hazard-watch asks while a route guides.
    public var hazardWatchIntervalS: TimeInterval
    /// `FallbackVLMClient.hazardDeadline` in seconds — how long the cloud gets before the on-device
    /// client answers a hazard prompt; nil when there is no cloud.
    public var hazardCloudDeadlineS: TimeInterval?
    /// Who answered the last hazard-watch request; nil before the first (or after a failure).
    public var lastWatchSource: String?
    /// Round trip of the last hazard-watch request, ms; nil before the first or after a failure.
    public var lastWatchMs: Int?
    /// Why the cloud did not answer the last hazard-watch request; nil when it did.
    public var lastWatchReason: String?
    /// Seconds since the last hazard-watch reply; nil before the first.
    public var secondsSinceWatch: TimeInterval?
    /// `HazardScanner.lastError` ("Hazard watch: <reason>") when the last check threw and nobody
    /// answered; nil after a success. Without it a dead hazard watch read as an idle one (Muse
    /// review, Step 47). The "Hazard watch: " prefix is stripped when the line is built.
    public var lastWatchError: String?

    /// `CueLevel.title` ("Detailed").
    public var cueLevelTitle: String
    /// `CuePlace.title` ("Outdoors").
    public var cuePlaceTitle: String
    /// "Speak obstacle names" switch.
    public var namesOn: Bool

    /// `AppModel.lightState` — `LowLightPolicy`'s verdict (Step 49). `.unknown` before the first
    /// ARKit light estimate (and always in the simulator).
    public var lightState: LowLightPolicy.State
    /// The smoothed ambient lux behind that verdict (`LowLightPolicy.smoothedLux`); nil before the first estimate.
    public var ambientLux: Float?
    /// `AppModel.torchEnabled` — the flashlight as the switch shows it.
    public var torchOn: Bool
    /// `AppModel.torchLitByApp` — the app lit it for the dark (it will switch it off again).
    public var torchByApp: Bool

    /// Memberwise, every field required so a new fact cannot be forgotten at the one call site
    /// (the Step 47 review's `lastWatchError` and the Step 49 light facts default, so older
    /// tests and call sites keep compiling).
    public init(cloudName: String?, onDeviceName: String, lastSource: String?, lastCloudMs: Int?,
                lastLatencyMs: Int?, lastFallbackReason: String?, lastGate: String?, lastError: String?,
                secondsSinceLast: TimeInterval?, lastTrigger: DescribeTrigger?, hazardWatchOn: Bool,
                hazardWatchIntervalS: TimeInterval, hazardCloudDeadlineS: TimeInterval?,
                lastWatchSource: String?, lastWatchMs: Int?, lastWatchReason: String?,
                secondsSinceWatch: TimeInterval?, lastWatchError: String? = nil,
                cueLevelTitle: String, cuePlaceTitle: String,
                namesOn: Bool,
                lightState: LowLightPolicy.State = .unknown, ambientLux: Float? = nil,
                torchOn: Bool = false, torchByApp: Bool = false) {
        self.cloudName = cloudName
        self.onDeviceName = onDeviceName
        self.lastSource = lastSource
        self.lastCloudMs = lastCloudMs
        self.lastLatencyMs = lastLatencyMs
        self.lastFallbackReason = lastFallbackReason
        self.lastGate = lastGate
        self.lastError = lastError
        self.secondsSinceLast = secondsSinceLast
        self.lastTrigger = lastTrigger
        self.hazardWatchOn = hazardWatchOn
        self.hazardWatchIntervalS = hazardWatchIntervalS
        self.hazardCloudDeadlineS = hazardCloudDeadlineS
        self.lastWatchSource = lastWatchSource
        self.lastWatchMs = lastWatchMs
        self.lastWatchReason = lastWatchReason
        self.secondsSinceWatch = secondsSinceWatch
        self.lastWatchError = lastWatchError
        self.cueLevelTitle = cueLevelTitle
        self.cuePlaceTitle = cuePlaceTitle
        self.namesOn = namesOn
        self.lightState = lightState
        self.ambientLux = ambientLux
        self.torchOn = torchOn
        self.torchByApp = torchByApp
    }
}

/// One row of the card: what is drawn and what VoiceOver says for it.
public struct SceneEngineLine: Sendable, Equatable {
    /// The visible text (short units: "1.9 s", "2 min ago").
    public let text: String
    /// The VoiceOver sentence (full words: "1.9 seconds", "2 minutes ago").
    public let spoken: String
}

/// The wording of the Scene engine card. Namespace only; every function is pure.
public enum SceneEngineSummary {

    // MARK: Small formatters

    /// Milliseconds → "850 ms" under a second, else one decimal of seconds ("1.9 s"; `spoken`
    /// "1.9 seconds" / "850 milliseconds"). Pinned by `latencyReadsInSecondsAboveOne`.
    public static func latency(_ ms: Int, spoken: Bool = false) -> String {
        if ms < 1000 { return "\(ms) \(spoken ? "milliseconds" : "ms")" }
        let s = (Double(ms) / 100).rounded() / 10
        let unit = spoken ? (s == 1 ? "second" : "seconds") : "s"
        return "\(formatted(s)) \(unit)"
    }

    /// Seconds → "2.5 s" / "8 s" (no trailing ".0"); `spoken` "2.5 seconds" / "8 seconds".
    public static func seconds(_ s: TimeInterval, spoken: Bool = false) -> String {
        let unit = spoken ? (s == 1 ? "second" : "seconds") : "s"
        return "\(formatted(s)) \(unit)"
    }

    /// The "just now" window (s); also the card's age-refresh period (`SceneEngineCard`), so the
    /// first change a reader sees is real. Here, not in the view, because it is a number with a
    /// meaning (Codex review, Step 47).
    public static let justNowWindow: TimeInterval = 10

    /// How long ago, relative: under `justNowWindow` "just now"; under a minute "N s ago"; under an hour
    /// "N min ago"; else "N h ago" (`spoken`: "N seconds / minutes / hours ago").
    /// Pinned by `ageIsRelative`.
    public static func age(_ seconds: TimeInterval, spoken: Bool = false) -> String {
        if seconds < justNowWindow { return "just now" }
        if seconds < 60 {
            let n = Int(seconds)
            return "\(n) \(spoken ? "seconds" : "s") ago"
        }
        if seconds < 3600 {
            let n = Int(seconds / 60)
            return "\(n) \(spoken ? (n == 1 ? "minute" : "minutes") : "min") ago"
        }
        let n = Int(seconds / 3600)
        return "\(n) \(spoken ? (n == 1 ? "hour" : "hours") : "h") ago"
    }

    /// One decimal at most, no trailing ".0" (2.5 → "2.5", 8.0 → "8").
    private static func formatted(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(r)
    }

    // MARK: Rows

    /// The provider-chain pill: "Muse → On-device" with a cloud, "On-device only" without.
    /// `spoken` says what the arrow means. Pinned by `chainPillNamesTheOrder`.
    public static func chain(_ f: SceneEngineFacts) -> SceneEngineLine {
        guard let cloud = f.cloudName else {
            return SceneEngineLine(text: "\(f.onDeviceName) only",
                                   spoken: "Where am I uses the on-device model only. No cloud model is in use.")
        }
        return SceneEngineLine(text: "\(cloud) → \(f.onDeviceName)",
                               spoken: "Where am I asks \(cloud) first, then the on-device model when \(cloud) fails.")
    }

    /// Who answered the last "Where am I" and how fast — the card's headline row.
    ///   · never asked: "Not asked yet." (the row caption already says WHERE AM I)
    ///   · failed: "Failed — <error>" / "No camera frame."
    ///   · cloud answered: "Muse answered in 1.9 s"
    ///   · cloud failed, on-device answered: "On-device answered — Muse: The request timed out."
    ///   · on-device only: "On-device answered in 0.4 s"
    /// Pinned by `cloudAnswerNamesTheModelAndLatency`, `fallbackSaysWhy`, `neverAskedYet`,
    /// `aFailureIsSaidAsAFailure`.
    public static func lastAnswer(_ f: SceneEngineFacts) -> SceneEngineLine {
        guard f.lastGate != nil || f.lastSource != nil else {
            return SceneEngineLine(text: "Not asked yet.",
                                   spoken: "Where am I has not been asked yet.")
        }
        if f.lastGate == "no frame" {
            return SceneEngineLine(text: "No camera frame.",
                                   spoken: "The last Where am I had no camera frame.")
        }
        guard let source = f.lastSource else {
            let why = f.lastError ?? "unknown error"
            return SceneEngineLine(text: "Failed — \(why)",
                                   spoken: "The last Where am I failed: \(why)")
        }
        if let reason = f.lastFallbackReason, let cloud = f.cloudName {
            var text = "\(source) answered — \(cloud): \(reason)"
            var spoken = "\(source) answered the last Where am I, because \(cloud) failed: \(reason)"
            if let ms = f.lastCloudMs {
                text += " (after \(latency(ms)))"
                spoken += " It gave up after \(latency(ms, spoken: true))."
            }
            return SceneEngineLine(text: text, spoken: spoken)
        }
        let ms = f.lastCloudMs ?? f.lastLatencyMs
        guard let ms else {
            return SceneEngineLine(text: "\(source) answered", spoken: "\(source) answered the last Where am I.")
        }
        return SceneEngineLine(text: "\(source) answered in \(latency(ms))",
                               spoken: "\(source) answered the last Where am I in \(latency(ms, spoken: true)).")
    }

    /// When the last run finished and what asked for it: "2 min ago · from the watch"; nil
    /// before the first run. Pinned by `whenLineJoinsAgeAndTrigger`.
    public static func when(_ f: SceneEngineFacts) -> SceneEngineLine? {
        guard let since = f.secondsSinceLast else { return nil }
        guard let trigger = f.lastTrigger else {
            return SceneEngineLine(text: age(since), spoken: "\(age(since, spoken: true).capitalizedFirst)")
        }
        return SceneEngineLine(text: "\(age(since)) · from \(trigger.spoken)",
                               spoken: "\(age(since, spoken: true).capitalizedFirst), from \(trigger.spoken).")
    }

    /// What `CloudSceneGate` did to the cloud sentence — only when the cloud answered:
    /// "spoken" → "Muse's sentence passed the gate."; "edited: dropped count" → "Muse's sentence was
    /// edited: dropped count."; "refused: invented distance" → "Muse's sentence was refused:
    /// invented distance. On-device spoke instead."; nil for an on-device answer, a failure or no
    /// run yet. Pinned by `gateRefusalIsExplained`, `gateLineOnlyWhenTheCloudAnswered`.
    public static func gate(_ f: SceneEngineFacts) -> SceneEngineLine? {
        guard let cloud = f.cloudName, f.lastSource == cloud, let gate = f.lastGate else { return nil }
        if gate == "spoken" {
            let s = "\(cloud)'s sentence passed the gate."
            return SceneEngineLine(text: s, spoken: s)
        }
        if let detail = after("edited:", in: gate) {
            let s = "\(cloud)'s sentence was edited: \(detail)."
            return SceneEngineLine(text: s, spoken: s)
        }
        if let detail = after("refused:", in: gate) {
            let s = "\(cloud)'s sentence was refused: \(detail). \(f.onDeviceName) spoke instead."
            return SceneEngineLine(text: s, spoken: s)
        }
        return nil
    }

    /// The hazard watch, in one line:
    ///   · off: "Hazard watch off — when on, asks Muse every 8 s while a route guides, on-device
    ///     after 2.5 s" (no cloud: "… asks the on-device model every 8 s while a route guides")
    ///   · on, nothing asked: "Hazard watch on — asks Muse every 8 s while a route guides,
    ///     on-device after 2.5 s. Nothing asked yet."
    ///   · on, answered: "Hazard watch: Muse answered in 1.2 s · 30 s ago" /
    ///     "Hazard watch: On-device answered — Muse: The request timed out. · 30 s ago"
    ///   · on, last check threw: "Hazard watch: last check failed — The request timed out. · 30 s ago"
    /// Pinned by `hazardWatchOffSaysWhenItWouldRun`, `hazardWatchOnNamesTheLastAnswer`,
    /// `hazardWatchFailureIsSaidAsAFailure`.
    public static func hazardWatch(_ f: SceneEngineFacts) -> SceneEngineLine {
        let every = seconds(f.hazardWatchIntervalS)
        let everySpoken = seconds(f.hazardWatchIntervalS, spoken: true)
        var plan: String
        var planSpoken: String
        if let cloud = f.cloudName {
            plan = "asks \(cloud) every \(every) while a route guides"
            planSpoken = "asks \(cloud) every \(everySpoken) while a route guides"
            if let deadline = f.hazardCloudDeadlineS {
                plan += ", on-device after \(seconds(deadline))"
                planSpoken += ", and the on-device model answers if \(cloud) takes more than \(seconds(deadline, spoken: true))"
            }
        } else {
            plan = "asks the on-device model every \(every) while a route guides"
            planSpoken = plan.replacingOccurrences(of: every, with: everySpoken)
        }
        guard f.hazardWatchOn else {
            return SceneEngineLine(text: "Hazard watch off — when on, \(plan)",
                                   spoken: "Hazard watch is off. When on, it \(planSpoken).")
        }
        guard let source = f.lastWatchSource else {
            // A check that threw (no reply from anyone) is said as a failure, never as "idle".
            if let error = f.lastWatchError, let since = f.secondsSinceWatch {
                let why = error.hasPrefix("Hazard watch: ") ? String(error.dropFirst("Hazard watch: ".count)) : error
                return SceneEngineLine(text: "Hazard watch: last check failed — \(why) · \(age(since))",
                                       spoken: "The last hazard watch check failed \(age(since, spoken: true)): \(why)")
            }
            return SceneEngineLine(text: "Hazard watch on — \(plan). Nothing asked yet.",
                                   spoken: "Hazard watch is on. It \(planSpoken). Nothing has been asked yet.")
        }
        var text: String
        var spoken: String
        if let reason = f.lastWatchReason, let cloud = f.cloudName {
            text = "Hazard watch: \(source) answered — \(cloud): \(reason)"
            spoken = "Hazard watch: \(source) answered the last check, because \(cloud) failed: \(reason)"
        } else if let ms = f.lastWatchMs {
            text = "Hazard watch: \(source) answered in \(latency(ms))"
            spoken = "Hazard watch: \(source) answered the last check in \(latency(ms, spoken: true))."
        } else {
            text = "Hazard watch: \(source) answered"
            spoken = "Hazard watch: \(source) answered the last check."
        }
        if let since = f.secondsSinceWatch {
            text += " · \(age(since))"
            spoken += " \(age(since, spoken: true).capitalizedFirst)."
        }
        return SceneEngineLine(text: text, spoken: spoken)
    }

    /// The cue profile in one glance: "Detailed · Outdoors · names off" (spoken "Cues: Detailed,
    /// Outdoors, obstacle names off."). Pinned by `cuesLineNamesLevelPlaceAndNames`.
    public static func cues(_ f: SceneEngineFacts) -> SceneEngineLine {
        let names = f.namesOn ? "names on" : "names off"
        return SceneEngineLine(text: "\(f.cueLevelTitle) · \(f.cuePlaceTitle) · \(names)",
                               spoken: "Cues: \(f.cueLevelTitle), \(f.cuePlaceTitle), obstacle \(names).")
    }

    /// The light the cameras have (Step 49), in one line — the answer to "how do you cope with the
    /// dark" that a blind walker cannot see for themselves:
    ///   · unknown: "Light: unknown" (no ARKit estimate yet; always in the simulator)
    ///   · lit: "Light: lit (640 lux)" ("Light: lit" without a number)
    ///   · dark, torch on by the app: "Light: dark (12 lux) · flashlight on (by OpenCane)"
    ///   · dark, torch on by the walker: "Light: dark (12 lux) · flashlight on"
    ///   · dark, torch off: "Light: dark (12 lux) · flashlight off — cameras may miss things"
    /// The lux is the policy's smoothed value, rounded. Pinned by `lightRowSaysWhatTheCamerasHave`,
    /// `lightRowNamesWhoLitTheTorch`, `lightRowUnknownBeforeAnEstimate`.
    public static func light(_ f: SceneEngineFacts) -> SceneEngineLine {
        let lux = f.ambientLux.map { " (\(Int($0.rounded())) lux)" } ?? ""
        let luxSpoken = f.ambientLux.map { ", \(Int($0.rounded())) lux" } ?? ""
        switch f.lightState {
        case .unknown:
            return SceneEngineLine(text: "Light: unknown",
                                   spoken: "Light level unknown. No camera light estimate yet.")
        case .lit:
            return SceneEngineLine(text: "Light: lit\(lux)", spoken: "Light: lit\(luxSpoken).")
        case .dark:
            if f.torchOn {
                let who = f.torchByApp ? " (by OpenCane)" : ""
                let whoSpoken = f.torchByApp ? ", switched on by OpenCane" : ""
                return SceneEngineLine(text: "Light: dark\(lux) · flashlight on\(who)",
                                       spoken: "Light: dark\(luxSpoken). Flashlight on\(whoSpoken).")
            }
            return SceneEngineLine(text: "Light: dark\(lux) · flashlight off — cameras may miss things",
                                   spoken: "Light: dark\(luxSpoken). Flashlight off, so the cameras may miss things. Obstacle detection still works.")
        }
    }

    /// The whole card as one VoiceOver paragraph (chain, last answer, when, gate, hazard watch,
    /// light, cues — in that fixed order, empty rows skipped). Pinned by `summaryReadsEveryRowInOrder`.
    public static func spokenSummary(_ f: SceneEngineFacts) -> String {
        [chain(f).spoken, lastAnswer(f).spoken, when(f)?.spoken, gate(f)?.spoken,
         hazardWatch(f).spoken, light(f).spoken, cues(f).spoken]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    /// The text after `prefix` in `s`, trimmed, or nil when `s` does not start with it.
    private static func after(_ prefix: String, in s: String) -> String? {
        guard s.hasPrefix(prefix) else { return nil }
        let rest = s.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }
}

private extension String {
    /// "just now" → "Just now" (the start of a VoiceOver sentence).
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
