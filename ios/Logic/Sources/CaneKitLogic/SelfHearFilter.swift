//
//  SelfHearFilter.swift
//  CaneKitLogic
//
//  Drops a voice transcript that is the app's own recent line, so OpenCane never answers itself.
//
//  Why (Step 55): the first cane-mounted walk logged `conv_error query: "Head height"`. The walker
//  was dictating, "Head height." (`.safety`) broke through the voice hold as designed, the
//  microphone has no echo control (hard rule 7: one `.playback` session, `.playAndRecord` only
//  under the `.voiceInput` lease, never `.voiceChat` / HFP), and the recogniser transcribed the
//  phone's own warning as the walker's question. Two defences now exist in the app:
//    1. `VoiceInputEngine`'s tap drops microphone buffers while `SpeechQueue.isSpeaking` and for
//       `tailSeconds` after (`SpeechBufferBox`, a `Mutex<Bool>` read on the audio thread);
//    2. this filter, on the final transcript: dropped silently when it equals a line the app
//       dispatched inside `window`, or one whole clause of it.
//  The match is *whole line or whole clause*, never "line contains transcript": the help list
//  ("One, route. Two, where am I. …") contains "route", and "route" is the one word the shell must hear.
//  A transcript shorter than `minTranscriptCharacters` is never dropped: the IVR digits "1"…"8"
//  and "no" must always get through, and a one- or two-letter echo is not worth guessing about.
//
//  Owner: `VoiceInputEngine` (app) holds one value per press: `AppModel`'s `speech.onDispatch`
//  hook calls `record(line:at:)` only while the engine is listening or starting (a line dispatched
//  before the microphone opened — "OpenCane ready.", the help list, an answer — can never be in the
//  history, so answering the help list with one of its own words is never dropped); `stopListeningAndSubmit` calls
//  `shouldDrop(transcript:now:)` and logs `voice_self_hear {action: dropped, transcript,
//  matched_line}`; `startListening` calls `reset()`.
//  Isolation: a plain `Sendable` value; single owner, `mutating` updates; no clock of its own.
//  Tests: SelfHearFilterTests.swift (8).
//

import Foundation

/// The app's recently dispatched lines and the rule that says a transcript is one of them.
public struct SelfHearFilter: Sendable, Equatable {

    // MARK: Numbers ([H]: tune from `voice_self_hear` records)

    /// Seconds after a line's dispatch during which the same words are the app's, not the
    /// walker's. Lines are short (a warning is ~1 s); 3 s covers the line plus the recogniser's
    /// finalisation lag. Pinned by `selfHearNumbersArePinned`.
    public static let window: TimeInterval = 3

    /// Seconds the microphone tap stays deaf after `SpeechQueue.isSpeaking` goes false: the
    /// AirPods' audio path and the player's end callback both lag the last sample. Read by
    /// `VoiceInputEngine`, pinned here (hard rule 3).
    public static let tailSeconds: TimeInterval = 0.3

    /// Transcripts shorter than this (after `normalize`) are never dropped.
    public static let minTranscriptCharacters = 3

    // MARK: State

    /// One dispatched line and when.
    public struct Entry: Sendable, Equatable {
        /// The whole line as dispatched.
        public let line: String
        /// Reference-date seconds of the dispatch.
        public let at: TimeInterval
    }

    /// Lines dispatched inside the window, oldest first. Pruned on every `record`.
    public private(set) var history: [Entry] = []

    /// Empty.
    public init() {}

    // MARK: Normalisation

    /// Lower-cased, every punctuation or symbol character replaced by a space, whitespace
    /// collapsed to single spaces, trimmed. Digits are kept ("1" is an IVR alias, "2.5" a
    /// distance — the decimal point becomes a space here, on both sides of the comparison).
    /// Pinned by `punctuationAndCaseDoNotMatter`.
    /// - Parameter text: a transcript or a spoken line.
    public static func normalize(_ text: String) -> String {
        let breakers = CharacterSet.punctuationCharacters.union(.symbols)
        let scalars = text.lowercased().unicodeScalars.map { breakers.contains($0) ? " " : Character($0) }
        return String(scalars).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The line's clauses, normalised, empty ones dropped. A clause ends at one of
    /// `SpeechResume.clauseEnders` followed by whitespace or the end of the line — the same rule a
    /// resumed line is cut by — so "2.5" (no whitespace after the point) never splits.
    /// Pinned by `aClauseOfARecentLineIsDropped`.
    /// - Parameter line: the whole spoken line.
    public static func clauses(of line: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(line)
        for (i, c) in chars.enumerated() {
            if SpeechResume.clauseEnders.contains(c) {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if next == nil || next!.isWhitespace {
                    let clause = normalize(current)
                    if !clause.isEmpty { out.append(clause) }
                    current = ""
                    continue
                }
            }
            current.append(c)
        }
        let last = normalize(current)
        if !last.isEmpty { out.append(last) }
        return out
    }

    // MARK: Recording and matching

    /// Remember a line the app just handed to a voice backend. Blank lines are ignored; entries
    /// older than `window` are pruned.
    /// - Parameters:
    ///   - line: the whole line (`SpeechQueue.onDispatch`'s text).
    ///   - at: reference-date seconds of the dispatch.
    public mutating func record(line: String, at: TimeInterval) {
        prune(now: at)
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        history.append(Entry(line: line, at: at))
    }

    /// Forget everything (a new press starts clean).
    public mutating func reset() {
        history.removeAll()
    }

    /// Whether `transcript` is the app's own voice: equal, after `normalize`, to a line dispatched
    /// within `window` before `now`, or to one whole clause of it. Never a substring match.
    /// - Parameters:
    ///   - transcript: the recogniser's final text.
    ///   - now: reference-date seconds.
    /// - Returns: the matched line (for the `voice_self_hear` record), or nil to keep the transcript.
    /// Pinned by `exactLineWithinThreeSecondsIsDropped`, `aClauseOfARecentLineIsDropped`,
    /// `theWalkersOwnWordsAreKept`, `oldLinesAgeOut`, `shortFragmentsNeverMatch`.
    public func shouldDrop(transcript: String, now: TimeInterval) -> String? {
        let heard = Self.normalize(transcript)
        guard heard.count >= Self.minTranscriptCharacters else { return nil }
        for entry in history.reversed() where now - entry.at <= Self.window && now >= entry.at {
            if Self.normalize(entry.line) == heard { return entry.line }
            if Self.clauses(of: entry.line).contains(heard) { return entry.line }
        }
        return nil
    }

    /// Drop entries older than `window`.
    private mutating func prune(now: TimeInterval) {
        history.removeAll { now - $0.at > Self.window }
    }
}
