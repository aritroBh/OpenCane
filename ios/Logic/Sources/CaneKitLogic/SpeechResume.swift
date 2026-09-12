//
//  SpeechResume.swift
//  CaneKitLogic
//
//  Where a cut line picks up again, and how long the pause is between two different kinds of line
//  (Step 37, "talk floor": directions and obstacle alerts must not talk over each other).
//
//  Why: "Head height." has to cut a direction at once (a walker reaches a 1.5 m overhang in ~1.5 s,
//  so the words cannot wait — Muse review of the first talk-floor plan). What made that sound like
//  the app "interrupting itself" was the second half: the cut direction restarted from its first
//  word. Trip log 2026-09-12T22-20-53Z had 5 such restarts in 58 lines, and 9 line starts < 1 s apart.
//  Owner decision 2026-09-12: "Cut in, then resume" — the warning is instant, and the direction
//  continues from the clause it was cut in, after a short audible pause.
//
//  Units: offsets are UTF-16 code units, the unit `AVSpeechSynthesizerDelegate.willSpeakRangeOf…`
//  reports. A natural-voice (mp3) clip has no word timings, so its progress is mapped
//  proportionally (played time / duration × text length) and its resume starts `clipLead` early —
//  hearing the end of the previous word beats losing the first word of the clause.
//
//  Pure: Foundation-only. Owner: `SpeechQueue.requeueCurrent` (resume point, `nextResume`),
//  `speakNow` (`remainder`, mp3 `clipTime`), `say` / `lineEnded` / `startNext` (`gapSeconds`).
//  Trip log: `speech_dispatch.resume_from` (> 0 = a cut line continuing) — the evidence to tune
//  every [H] constant below. Isolation: stateless and nonisolated; called on the main actor.
//  Tests: `SpeechResumeTests.swift` (15).
//

import Foundation

/// Resume points and inter-line pauses for the speech queue. Stateless; every input is passed in.
public enum SpeechResume {

    /// Characters that end a clause when followed by whitespace. A decimal point ("2.5") is not
    /// followed by whitespace, so it never splits a number.
    public static let clauseEnders: Set<Character> = [".", "!", "?", ",", ";", ":"]
    /// Seconds an mp3 resume starts before the proportional clause position (proportional mapping
    /// is approximate; starting early never clips a word). [H] tune on device.
    public static let clipLead: TimeInterval = 0.25
    /// Most times one line may be resumed after cuts (`nextResume`).
    public static let maxResumes = 3
    /// Pause (s) before a line of a different band than the one that just ended. [H] Long enough to
    /// hear "Head height." and the direction as two things, short enough not to delay a turn.
    public static let crossBandGap: TimeInterval = 0.35
    /// UTF-16 code units subtracted from an mp3 progress estimate before its clause is chosen: about
    /// half a second of speech at ~15 characters a second. A natural voice does not spend time evenly
    /// (a pause inside a clause pushes the proportional estimate ahead of what was heard), and
    /// resuming one clause early costs a few repeated words while resuming one clause late loses an
    /// instruction (Muse, Step 37). [H] tune on device with `resume_from` in the trip log.
    public static let mp3MarginUTF16 = 8

    /// Words that end in a period without ending a clause (street and title abbreviations in route
    /// and MapKit lines). Initialisms like "U.S." are recognised by shape in `isAbbreviation`.
    public static let abbreviations: Set<String> = [
        "St", "Dr", "Jr", "Sr", "Ave", "Rd", "Blvd", "Ln", "Ct", "Pl", "Hwy", "Rte", "Mt", "Ft",
        "Mr", "Mrs", "Ms", "Prof", "No", "approx", "vs", "etc",
    ]

    /// True when `word` (the text before a period, back to the previous whitespace) is an
    /// abbreviation: in `abbreviations`, or an initialism — single letters joined by periods ("U.S").
    static func isAbbreviation(_ word: Substring) -> Bool {
        if abbreviations.contains(String(word)) { return true }
        let parts = word.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count > 1 && parts.allSatisfy { $0.count == 1 && $0.first!.isLetter }
    }

    /// UTF-16 offsets where a clause starts: 0, plus the first non-whitespace character after every
    /// clause ender followed by whitespace — except a period that ends an abbreviation ("St. Mary's",
    /// "U.S. Route": splitting there resumed a street name without its verb — review agents, Step 37).
    static func clauseStarts(_ text: String) -> [Int] {
        var starts = [0]
        let chars = Array(text.utf16)
        // Every ender is ASCII, so comparing code units is exact (a surrogate half never matches).
        let enders = Set(clauseEnders.compactMap { $0.utf16.count == 1 ? $0.utf16.first : nil })
        var i = 0
        while i < chars.count {
            if enders.contains(chars[i]), i + 1 < chars.count, isSpace(chars[i + 1]),
               !(chars[i] == 0x2E && isAbbreviation(wordBefore(chars, i))) {
                var j = i + 1
                while j < chars.count, isSpace(chars[j]) { j += 1 }
                if j < chars.count { starts.append(j) }
                i = j
                continue
            }
            i += 1
        }
        return starts
    }

    /// The word ending just before code unit `i` (back to the previous whitespace), as text.
    private static func wordBefore(_ chars: [UInt16], _ i: Int) -> Substring {
        var j = i
        while j > 0, !isSpace(chars[j - 1]) { j -= 1 }
        return Substring(String(decoding: chars[j..<i], as: UTF16.self))
    }

    /// True for the ASCII / Unicode space and newline code units the queue's lines contain.
    private static func isSpace(_ u: UInt16) -> Bool {
        guard let s = UnicodeScalar(u) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(s)
    }

    /// Where a line cut after `spokenUTF16` code units should resume.
    /// - Parameters:
    ///   - text: the whole line.
    ///   - spokenUTF16: start of the word being spoken when the cut came (system voice), or the
    ///     proportional estimate from `spokenUTF16(text:playedFraction:)` (mp3).
    ///   - finishesWord: true for the system voice, which stops at a word boundary
    ///     (`stopSpeaking(at: .word)`) — the word at `spokenUTF16` is heard in full, so only what
    ///     follows it counts as left (a cut during the last word finishes the line).
    /// - Returns: the start of the clause containing that point (0 = restart from the top), or nil
    ///   when nothing but punctuation / whitespace is left (the line is effectively finished).
    public static func resumeOffset(text: String, spokenUTF16: Int, finishesWord: Bool = false) -> Int? {
        let count = text.utf16.count
        guard spokenUTF16 > 0 else { return 0 }
        guard spokenUTF16 < count else { return nil }
        var left = characterStart(in: text, atOrBefore: spokenUTF16)
        if finishesWord {
            // Skip to the end of the word being spoken.
            let chars = Array(text.utf16)
            while left < chars.count, !isSpace(chars[left]) { left += 1 }
        }
        let rest = remainder(of: text, from: left)
        guard rest.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return nil }
        return clauseStarts(text).last(where: { $0 <= spokenUTF16 }) ?? 0
    }

    /// The text from `offset` (UTF-16) to the end; the whole text for an offset ≤ 0, empty past the
    /// end. An offset inside a multi-unit character (an emoji, a combining accent) starts at that
    /// character — `String.Index(_:within:)` is nil there, and an empty remainder read as "finished"
    /// dropped the line (Antigravity, Step 37).
    public static func remainder(of text: String, from offset: Int) -> String {
        guard offset > 0 else { return text }
        guard offset < text.utf16.count else { return "" }
        let start = characterStart(in: text, atOrBefore: offset)
        let utf16 = text.utf16
        let i = utf16.index(utf16.startIndex, offsetBy: start)
        return String(text[i...])
    }

    /// UTF-16 offset of the start of the character (extended grapheme cluster) containing `offset`.
    static func characterStart(in text: String, atOrBefore offset: Int) -> Int {
        var position = 0
        var start = 0
        for character in text {
            if position > offset { break }
            start = position
            position += character.utf16.count
        }
        return start
    }

    /// Proportional progress through an mp3 clip, in UTF-16 code units of its text.
    /// - Parameter playedFraction: `currentTime / duration`; non-finite or < 0 → 0, > 1 → the end.
    public static func spokenUTF16(text: String, playedFraction: Double) -> Int {
        guard playedFraction.isFinite, playedFraction > 0 else { return 0 }
        let count = text.utf16.count
        return Int((min(playedFraction, 1) * Double(count)).rounded(.down))
    }

    /// The progress to resume an mp3 clip from: its proportional estimate less `mp3MarginUTF16`,
    /// never negative. The system voice reports real word positions and does not need this.
    public static func mp3HeardUTF16(estimate: Int) -> Int {
        max(0, estimate - mp3MarginUTF16)
    }

    /// Clip time (s) at which an mp3 resume at `resumeUTF16` starts: the proportional position less
    /// `clipLead`, never negative; 0 for a restart or an unusable duration.
    public static func clipTime(text: String, resumeUTF16: Int, duration: TimeInterval) -> TimeInterval {
        let count = text.utf16.count
        guard resumeUTF16 > 0, count > 0, duration.isFinite, duration > 0 else { return 0 }
        return max(0, Double(resumeUTF16) / Double(count) * duration - clipLead)
    }

    /// Where a cut line resumes next time, or nil when it may not go back in the queue.
    /// - Parameters:
    ///   - previousOffset: the offset it last resumed from, nil if it was never cut before.
    ///   - newOffset: the offset its progress points at now (`resumeOffset`).
    ///   - resumes: how many times it has already resumed.
    /// - Returns: nil once `maxResumes` resumes happened — the loop guard: warnings are ≥ 4 s apart
    ///   (`CueSpeechPolicy`), so a line cut that often is stale and Repeat recovers it. Otherwise
    ///   `max(newOffset, previousOffset)`: a resume point never moves backwards. An mp3 resumes
    ///   `clipLead` early and its progress is backed off `mp3MarginUTF16`, so a second warning just
    ///   after resuming reads as a point before the last resume; the earlier "must advance" rule
    ///   dropped the direction there on its first re-cut (Antigravity, Step 37).
    public static func nextResume(previousOffset: Int?, newOffset: Int, resumes: Int) -> Int? {
        guard resumes < maxResumes else { return nil }
        return max(newOffset, previousOffset ?? 0)
    }

    /// Pause before starting the next queued line.
    /// - Parameters:
    ///   - previousBand: raw band of the line that just ended; nil when nothing played before.
    ///   - nextBand: raw band of the line about to start.
    ///   - safetyBand: raw value of the top band (`SpeechPriority.safety.rawValue`, passed by the app
    ///     rather than copied here, so reordering the app enum cannot make a warning wait).
    /// - Returns: `crossBandGap` between different bands, 0 for the same band, for nothing before,
    ///   and for a safety line (it never waits).
    public static func gapSeconds(previousBand: Int?, nextBand: Int, safetyBand: Int) -> TimeInterval {
        guard let previousBand, previousBand != nextBand, nextBand < safetyBand else { return 0 }
        return crossBandGap
    }
}
