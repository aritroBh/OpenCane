//
//  VoiceEngineChoice.swift
//  CaneKitLogic
//
//  Which voice speaks a line, decided once, in one place, before the line is dispatched.
//
//  Why this file exists (Step 53): `SpeechQueue.speakNow` used to choose a backend inline — key,
//  cache, warning priority, an `immediate` flag, a 60 s timestamp — and nothing wrote the choice
//  down. The first cane-mounted walk (2026-09-13) alternated between the ElevenLabs voice and
//  Apple's every few lines and the trip log could not say which line took which path, let alone
//  why. The decision is now a pure function whose result is logged on every `speech_dispatch`
//  record (`engine`, `engine_reason`) and, when it was a race, resolved by a `speech_engine`
//  record (`race_won` / `race_timeout` / `race_failed`, `wait_ms`). `ios/scripts/cue_audit.py`
//  counts engine flips from those fields.
//
//  The rules (owner decision 2026-09-13, "ElevenLabs is the one voice for everything"):
//    · muted automation → no sound at all;
//    · no key → system voice (hard rule 4: no key, no crash, no silence);
//    · the Settings picker on System → system voice (the founder's valve at a venue with bad Wi-Fi);
//    · on disk → the natural voice, always — a warning too, breaker open or not (no fetch needed);
//    · an uncached `.obstacle` / `.safety` line → system voice now (warnings never wait for the
//      network, AGENTS.md; the launch prefetch makes this case rare);
//    · breaker open → system voice now (one flip per outage, see `VoiceBreaker`);
//    · anything else → a race: fetch for at most `raceDeadline`, then the system voice.
//  `immediate:` (Step 31, "conversational answers skip the fetch") is gone: an answer now takes
//  the same cache → race path as every other line, so a finite, prefetched answer is heard in
//  the natural voice and a novel one costs at most 2.5 s (accepted in the owner decision).
//
//  Owner / callers: `SpeechQueue.speakNow` (app) calls `decide` before firing `onDispatch`, so the
//  dispatch timestamp `cue_audit.py` measures pauses from does not move; `resolvedEngine` and
//  `describe` feed the `speech_engine` record and the Details tab's Scene-engine card.
//  Isolation: stateless and nonisolated; every type here is a plain `Sendable` value.
//  Tests: VoiceEngineChoiceTests.swift (the table, the pinned raw values, the 2.5 s deadline).
//

import Foundation

/// The backend a line is handed to at dispatch time. `race` means "not decided yet": the fetch
/// and the deadline are racing, and a `speech_engine` record will say who won.
/// ⚠ Raw values are the trip log's `speech_dispatch.engine` (pinned by
/// `engineAndReasonRawValuesArePinned`); never rename.
public enum VoiceEngine: String, Sendable, Equatable {
    /// ElevenLabs mp3 (the natural voice), from disk or freshly fetched.
    case natural = "elevenlabs"
    /// `AVSpeechSynthesizer`, always available offline.
    case system = "system"
    /// A fetch is racing the deadline; resolved later (`VoiceEngineChoice.resolvedEngine`).
    case race = "race"
    /// Automation mute (`CANEKIT_MUTE` / `CANEKIT_UITEST`): timing simulated, no audio.
    case muted = "muted"
}

/// Why a line took the engine it took. The first seven are dispatch-time reasons; the last four
/// are how a race ended (`speech_engine`). ⚠ Raw values are a log contract; never rename.
public enum VoiceEngineReason: String, Sendable, Equatable, CaseIterable {
    /// Automation mute.
    case muted = "muted"
    /// No `ELEVENLABS_API_KEY` in Secrets.plist.
    case noKey = "no_key"
    /// The Settings "Voice" picker is on System (`AppModel.naturalVoiceEnabled == false`).
    case naturalOff = "natural_off"
    /// The mp3 was on disk: played at once, no network.
    case cached = "cached"
    /// An `.obstacle` / `.safety` line that was not cached: system voice now, never a fetch.
    case warningMiss = "warning_miss"
    /// `VoiceBreaker` is open after a race failed or timed out: system voice now, no new race.
    case breakerOpen = "breaker_open"
    /// A fetch was started against `raceDeadline`; see the `speech_engine` record for the outcome.
    case race = "race"
    /// Resolution: the fetch finished first and the natural voice played.
    case raceWon = "race_won"
    /// Resolution: the deadline fired first; the system voice spoke and the breaker opened.
    case raceTimeout = "race_timeout"
    /// Resolution: the fetch failed; the system voice spoke and the breaker opened.
    case raceFailed = "race_failed"
    /// Resolution: the mp3 was on disk or fetched but `AVAudioPlayer` could not play it; the
    /// system voice spoke the remainder under the same generation (never a mid-line handoff).
    case playbackFailed = "playback_failed"
    /// A `.safety` line whose first attempt stalled past the speech watchdog is spoken again once in
    /// the system voice at once (`SpeechQueue.armWatchdog`, Step 51a): a stalled backend must not
    /// swallow "Head height.". Not a `decide` outcome; set by the queue.
    case watchdogFallback = "watchdog_fallback"
    /// ElevenLabs refused the key: quota used up (HTTP 401 `quota_exceeded`), a revoked key, or a
    /// voice / model the account cannot use (401 / 403 / 422, `VoicePrefetch.isFatal`). The whole
    /// session then speaks in the system voice — cached lines too — so the walker hears one voice,
    /// not the natural voice for old lines and Apple's for new ones (first-launch report, 2026-09-13).
    case naturalUnavailable = "natural_unavailable"
}

/// One decision: the engine and the reason, as written to the trip log.
public struct VoiceEngineDecision: Sendable, Equatable {
    /// What the line is handed to.
    public let engine: VoiceEngine
    /// Why.
    public let reason: VoiceEngineReason

    /// Memberwise.
    public init(engine: VoiceEngine, reason: VoiceEngineReason) {
        self.engine = engine
        self.reason = reason
    }
}

/// The decision table. Namespace only; every function is pure.
public enum VoiceEngineChoice {

    /// Total time a cache miss may wait for the natural voice before the system voice speaks,
    /// seconds — a *total* deadline task racing the fetch, not URLRequest's idle timeout (a slow
    /// trickle could outlast that). At walking pace 2.5 s is ~3.5 m, the most a direction may
    /// arrive late by. Pinned by `raceDeadlineIsPinned`; the app's `SpeechQueue` reads it here.
    public static let raceDeadline: TimeInterval = 2.5

    /// Decide the engine for one line. Order matters and is the order of the file header.
    /// - Parameters:
    ///   - muted: `SpeechQueue.muted` (automation).
    ///   - hasKey: an ElevenLabs key is configured (`naturalVoice != nil`).
    ///   - naturalEnabled: the Settings picker is on Natural (`useNaturalVoice`).
    ///   - cached: the exact line's mp3 is on disk.
    ///   - isWarning: the line is `.obstacle` or `.safety`.
    ///   - breakerOpen: `VoiceBreaker.isOpen`.
    ///   - naturalUnavailable: the service refused the key this session (`naturalUnavailable`
    ///     reason); checked before the cache so the session stays in one voice.
    /// - Returns: the engine and the reason. `.race` means the caller must start the fetch and
    ///   the `raceDeadline` timer and log the outcome as a `speech_engine` record.
    /// Pinned by the first seven tests of `VoiceEngineChoiceTests`.
    public static func decide(muted: Bool = false, hasKey: Bool, naturalEnabled: Bool, cached: Bool,
                              isWarning: Bool, breakerOpen: Bool,
                              naturalUnavailable: Bool = false) -> VoiceEngineDecision {
        if muted { return VoiceEngineDecision(engine: .muted, reason: .muted) }
        guard hasKey else { return VoiceEngineDecision(engine: .system, reason: .noKey) }
        guard naturalEnabled else { return VoiceEngineDecision(engine: .system, reason: .naturalOff) }
        guard !naturalUnavailable else { return VoiceEngineDecision(engine: .system, reason: .naturalUnavailable) }
        if cached { return VoiceEngineDecision(engine: .natural, reason: .cached) }
        if isWarning { return VoiceEngineDecision(engine: .system, reason: .warningMiss) }
        if breakerOpen { return VoiceEngineDecision(engine: .system, reason: .breakerOpen) }
        return VoiceEngineDecision(engine: .race, reason: .race)
    }

    /// The engine that actually spoke once a race (or a playback) resolved: only a won race is
    /// the natural voice. Pinned by `aResolvedRaceNamesTheEngineThatSpoke`.
    /// - Parameter resolution: `raceWon`, `raceTimeout`, `raceFailed` or `playbackFailed`
    ///   (any other reason is returned as the engine `decide` already named — `cached` → natural,
    ///   the rest system).
    public static func resolvedEngine(_ resolution: VoiceEngineReason) -> VoiceEngine {
        switch resolution {
        case .raceWon, .cached: return .natural
        case .muted: return .muted
        case .race: return .race
        case .raceTimeout, .raceFailed, .playbackFailed, .noKey, .naturalOff, .warningMiss, .breakerOpen,
             .watchdogFallback, .naturalUnavailable:
            return .system
        }
    }

    /// Words for the Details tab (Scene-engine card, last row) and its VoiceOver label: the voice
    /// that spoke first, the reason second, joined with " · ". Never a raw value.
    /// Pinned by `everyReasonHasWordsForTheDetailsCard`.
    /// - Parameters:
    ///   - engine: the engine as dispatched, or as resolved (`resolvedEngine`).
    ///   - reason: the dispatch reason or the resolution.
    public static func describe(engine: VoiceEngine, reason: VoiceEngineReason) -> String {
        let voice: String
        switch engine {
        case .natural: voice = "Natural voice"
        case .system: voice = "System voice"
        case .race: voice = "Fetching natural voice"
        case .muted: voice = "Muted"
        }
        let why: String
        switch reason {
        case .muted: why = "automation mute"
        case .noKey: why = "no ElevenLabs key"
        case .naturalOff: why = "System chosen in Settings"
        case .cached: why = "cached"
        case .warningMiss: why = "warning not cached yet"
        case .breakerOpen: why = "natural voice offline"
        case .race: why = "not cached, fetching"
        case .raceWon: why = "fetched in time"
        case .raceTimeout: why = "natural voice took over \(raceDeadlineText) s"
        case .raceFailed: why = "natural voice fetch failed"
        case .playbackFailed: why = "natural voice file would not play"
        case .watchdogFallback: why = "warning repeated after a stall"
        case .naturalUnavailable: why = "ElevenLabs refused the key or its quota is used up"
        }
        return "\(voice) · \(why)"
    }

    /// "2.5" — the deadline without a trailing zero, for `describe`.
    private static var raceDeadlineText: String {
        raceDeadline == raceDeadline.rounded() ? "\(Int(raceDeadline))" : "\(raceDeadline)"
    }
}
