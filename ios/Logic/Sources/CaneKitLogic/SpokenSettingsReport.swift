//
//  SpokenSettingsReport.swift
//  CaneKitLogic
//
//  "Read my settings." — the whole Settings screen as one spoken line, so a blind walker never has
//  to find a switch to learn what it is set to (docs/UX.md rule 3).
//
//  Why a read-back and not "go to Settings": the switches are spread over the Sense and Settings
//  pages behind a tab bar, and a VoiceOver scan of them is ~20 swipes with a thumb on a phone
//  clamped to a sweeping cane (docs/UX.md §1). The state of a *warning channel* is safety
//  information — "is drop-off detection on?" has a different answer to "is the cane broken?" — so it
//  has to be answerable in one utterance.
//
//  Key invariants:
//    · **Safety first in the sentence.** The cue level, the place and whether haptics are silenced
//      come first, because they are what changes whether the walker is being warned at all. The
//      nine feature switches follow, grouped on / off. A walker who stops listening after four
//      seconds has still heard the part that matters (`theReportLeadsWithTheSafetyState`).
//    · **Grouped, not enumerated.** "On: sign reading, the audio beacon." is shorter than nine
//      "X is on" sentences and much shorter than reading the ones that are at their default. The
//      auditory budget is the constraint (docs/auditory-load.md), and this line is spoken at
//      `.scene`, the lowest band, so a curb warning cuts it (`SpeechResume` resumes it by clause —
//      which is why the groups are separated by `.` and the members by `,`).
//    · **Every feature appears exactly once**, in `Feature.allCases` order, whatever its value
//      (`everyFeatureIsReportedExactlyOnce`). A read-back that omits a switch is worse than no
//      read-back: it reads as "that feature does not exist".
//    · **Silenced haptics are called out in words, not omitted.** Silencing routes obstacle cues to
//      the watch and to speech (AGENTS.md), so it is a mode, not an absence.
//    · Pure and nonisolated: it takes a snapshot, it returns a string. No clock, no I/O.
//
//  Owner / callers: `AppModel.speakSettingsReport()` builds the snapshot from its own properties and
//  speaks the result at `.scene`. Tests: `VoiceControlGrammarTests.swift` (suite "Settings report").
//

import Foundation

/// The spoken form of every switch the walker can change.
public enum SpokenSettingsReport {

    /// Everything the read-back needs, gathered by the app in one place so this stays pure.
    public struct Snapshot: Sendable, Equatable {
        /// How much the app volunteers.
        public var level: CueLevel
        /// Where the walker is.
        public var place: CuePlace
        /// True when cane haptics are silenced (obstacle cues go to the watch and to speech).
        public var hapticsSilenced: Bool
        /// True when the voice-only screen is on (`GuideLayout.voiceOnly`). Named because a walker
        /// who cannot see the tab bar must be able to ask whether it is gone.
        public var voiceOnly: Bool
        /// Each tier-2 feature and whether it is on. ⚠ A missing key is reported as off, because a
        /// feature the app could not read is a feature the walker is not getting.
        public var features: [VoiceControlGrammar.Feature: Bool]

        /// - Parameters:
        ///   - level: the cue level.
        ///   - place: the cue place.
        ///   - hapticsSilenced: whether cane haptics are silenced.
        ///   - features: the nine switches; omissions read as off.
        ///   - voiceOnly: whether the voice-only screen is on. Defaults false so a test that
        ///     does not care about layout can omit it.
        public init(level: CueLevel, place: CuePlace, hapticsSilenced: Bool,
                    features: [VoiceControlGrammar.Feature: Bool],
                    voiceOnly: Bool = false) {
            self.level = level
            self.place = place
            self.hapticsSilenced = hapticsSilenced
            self.voiceOnly = voiceOnly
            self.features = features
        }
    }

    /// One line naming the profile, the haptics state, and which features are on and off.
    ///
    /// Shape: "Detailed cues, outdoors. Cane haptics on. Voice-only screen off. On: sign reading,
    /// the audio beacon. Off: drop-off detection, …. Head-height warnings are always on."
    ///
    /// The last clause is not padding: it is the one thing a walker must not have to infer from a
    /// list of switches, because there is deliberately no switch for it (docs/UX.md rule 7) and its
    /// absence from the list would otherwise read as "off".
    /// - Parameter s: the snapshot.
    /// - Returns: the spoken line.
    public static func line(_ s: Snapshot) -> String {
        var parts: [String] = ["\(s.level.title) cues, \(s.place.title.lowercased())."]
        parts.append(s.hapticsSilenced
                     ? "Cane haptics are silenced; obstacles go to the watch and to speech."
                     : "Cane haptics on.")
        parts.append(s.voiceOnly ? "Voice-only screen on." : "Voice-only screen off.")

        let on = VoiceControlGrammar.Feature.allCases.filter { s.features[$0] == true }
        let off = VoiceControlGrammar.Feature.allCases.filter { s.features[$0] != true }
        if on.isEmpty {
            parts.append("Nothing else is on.")
        } else {
            parts.append("On: " + on.map(\.listName).joined(separator: ", ") + ".")
        }
        if !off.isEmpty {
            parts.append("Off: " + off.map(\.listName).joined(separator: ", ") + ".")
        }
        parts.append(alwaysOnClause)
        return parts.joined(separator: " ")
    }

    /// The closing clause of every report. ⚠ Its exact words are the promise the safety floor makes
    /// (`CueSpeechPolicy`, `CueDecider`, the `.head` haptic, `GroundHazardDetector`'s warning path):
    /// nothing a walker can say turns these off. Pinned by `theReportPromisesTheSafetyFloor`.
    public static let alwaysOnClause = "Head-height warnings are always on."

    /// Every fixed line this report can speak on its own, for the natural-voice prefetch.
    /// The full report is built per call and cannot be prefetched — it is spoken at `.scene`, so a
    /// cache miss costs it a race, never a warning (`VoiceEngineChoice`).
    public static let fixedLines: [String] = [alwaysOnClause]
}
