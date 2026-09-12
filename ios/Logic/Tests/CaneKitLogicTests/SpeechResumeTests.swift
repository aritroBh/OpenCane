//
//  SpeechResumeTests.swift
//  CaneKitLogicTests
//
//  Tests for where a cut line picks up again and how long the pause between two different kinds of
//  line is (Step 37, "talk floor"). The breaks these catch: a direction cut by "Head height." that
//  restarts from its first word (trip log 2026-09-12T22-20-53Z: 5 of 58 lines were restarts, owner:
//  "it interrupts each other"), a resume that starts mid-word, a resume loop that never advances, and
//  a cut in the last clause that replays nothing useful.
//
//  Source pinned: `ios/Logic/Sources/CaneKitLogic/SpeechResume.swift` (`resumeOffset`, `remainder`,
//  `spokenUTF16`, `mp3HeardUTF16`, `clipTime`, `nextResume`, `gapSeconds`; constants `clipLead`
//  0.25 s, `maxResumes` 3, `crossBandGap` 0.35 s, `mp3MarginUTF16` 8 — all hypotheses to tune from
//  the `resume_from` / `speech_end` trip-log events). Caller: `SpeechQueue` (app), for both the
//  system voice (`willSpeakRangeOfSpeechString` progress, `stopSpeaking(at: .word)`) and the
//  ElevenLabs mp3 path (played fraction). All offsets are UTF-16 code units. Public API only.
//

import CaneKitLogic
import Foundation
import Testing

/// Resume-point and inter-band-gap rules, driven by the real route intro from the field log plus
/// small hand-built lines for abbreviations, decimals and multi-unit characters.
@Suite("Speech resume")
struct SpeechResumeTests {

    /// The route intro from the field log — three clauses after "First:".
    let intro = "Route started. ISR Townsend Hall to CIF. First: Leaving Townsend Hall, then the path west."

    /// UTF-16 offset of `needle` in `text` (the unit AVSpeechSynthesizer reports ranges in).
    func offset(of needle: String, in text: String) -> Int {
        let r = text.range(of: needle)!
        return text.utf16.distance(from: text.utf16.startIndex, to: r.lowerBound)
    }

    @Test("a cut mid-clause resumes at the start of that clause, not at the first word")
    func resumesAtTheCutClause() {
        let cutAt = offset(of: "path west", in: intro)
        let resume = SpeechResume.resumeOffset(text: intro, spokenUTF16: cutAt)
        #expect(resume == offset(of: "then the path west", in: intro))
        #expect(SpeechResume.remainder(of: intro, from: resume!) == "then the path west.")
    }

    @Test("a cut exactly at a clause start resumes there")
    func cutAtClauseStart() {
        let cutAt = offset(of: "First:", in: intro)
        #expect(SpeechResume.resumeOffset(text: intro, spokenUTF16: cutAt) == cutAt)
    }

    @Test("a cut in the first clause restarts from the top")
    func cutInFirstClauseRestarts() {
        #expect(SpeechResume.resumeOffset(text: intro, spokenUTF16: 3) == 0)
        #expect(SpeechResume.resumeOffset(text: "Veer left.", spokenUTF16: 5) == 0)
    }

    @Test("a cut after the last word leaves nothing to resume")
    func cutAtTheEndResumesNothing() {
        let count = intro.utf16.count
        #expect(SpeechResume.resumeOffset(text: intro, spokenUTF16: count) == nil)
        #expect(SpeechResume.resumeOffset(text: intro, spokenUTF16: count + 40) == nil)
    }

    @Test("progress before the start, or a non-finite mp3 fraction, restarts from the top")
    func badProgressRestarts() {
        #expect(SpeechResume.resumeOffset(text: intro, spokenUTF16: -5) == 0)
        #expect(SpeechResume.spokenUTF16(text: intro, playedFraction: .nan) == 0)
        #expect(SpeechResume.spokenUTF16(text: intro, playedFraction: -1) == 0)
        #expect(SpeechResume.spokenUTF16(text: intro, playedFraction: 2) == intro.utf16.count)
    }

    @Test("a natural-voice clip maps played time to text proportionally")
    func mp3ProgressIsProportional() {
        let half = SpeechResume.spokenUTF16(text: intro, playedFraction: 0.5)
        #expect(half == intro.utf16.count / 2)
    }

    @Test("an mp3 resume starts a quarter second early so the first word is never clipped")
    func mp3ResumeTimeLeadsTheClause() {
        let clause = offset(of: "then the path west", in: intro)
        let duration: TimeInterval = 9
        let expected = Double(clause) / Double(intro.utf16.count) * duration - 0.25
        #expect(abs(SpeechResume.clipTime(text: intro, resumeUTF16: clause, duration: duration) - expected) < 1e-9)
        #expect(SpeechResume.clipTime(text: intro, resumeUTF16: 0, duration: duration) == 0)
        #expect(SpeechResume.clipTime(text: intro, resumeUTF16: 2, duration: .nan) == 0)
    }

    @Test("clause breaks are . ! ? , ; : followed by a space; a decimal point is not a break")
    func clauseBreaks() {
        let text = "In 2.5 meters, turn left; then stop."
        let cutAt = offset(of: "turn left", in: text) + 2
        #expect(SpeechResume.resumeOffset(text: text, spokenUTF16: cutAt) == offset(of: "turn left", in: text))
        let inNumber = offset(of: "5 meters", in: text)
        #expect(SpeechResume.resumeOffset(text: text, spokenUTF16: inNumber) == 0)
    }

    /// Review agents, Step 37: "St." / "Dr." / "U.S." are not clause ends — splitting there resumes a
    /// street name without its verb ("Mary's Road, then continue north." instead of "Turn left onto …").
    @Test("a street abbreviation does not end a clause")
    func abbreviationsDoNotSplit() {
        let text = "Turn left onto St. Mary's Road, then continue north."
        #expect(SpeechResume.resumeOffset(text: text, spokenUTF16: offset(of: "Mary's", in: text)) == 0)
        let dr = "Follow Dr. Martin Luther King Jr. Drive to U.S. Route 45."
        #expect(SpeechResume.resumeOffset(text: dr, spokenUTF16: offset(of: "Route", in: dr)) == 0)
    }

    /// Review agents, Step 37: the system voice stops at a WORD boundary (`stopSpeaking(at: .word)`),
    /// so a cut during the line's last word finishes it — nothing is left to resume.
    @Test("a word-boundary cut during the last word leaves nothing to resume")
    func wordBoundaryCutOnTheLastWordFinishesTheLine() {
        let cut = offset(of: "west", in: intro)
        #expect(SpeechResume.resumeOffset(text: intro, spokenUTF16: cut, finishesWord: true) == nil)
        #expect(SpeechResume.resumeOffset(text: intro, spokenUTF16: cut, finishesWord: false)
                == offset(of: "then the path west", in: intro))
        let path = offset(of: "path", in: intro)
        #expect(SpeechResume.resumeOffset(text: intro, spokenUTF16: path, finishesWord: true)
                == offset(of: "then the path west", in: intro))
    }

    @Test("a line resumes at most three times, and its resume point never moves backwards")
    func resumesAreCappedAndNeverGoBackwards() {
        #expect(SpeechResume.nextResume(previousOffset: nil, newOffset: 0, resumes: 0) == 0)
        #expect(SpeechResume.nextResume(previousOffset: 0, newOffset: 15, resumes: 1) == 15)
        #expect(SpeechResume.nextResume(previousOffset: 15, newOffset: 40, resumes: 2) == 40)
        #expect(SpeechResume.nextResume(previousOffset: 15, newOffset: 40, resumes: 3) == nil)   // cap
    }

    /// Antigravity, Step 37: an mp3 resume starts `clipLead` early and its progress is backed off by
    /// `mp3MarginUTF16`, so a second warning within half a second of resuming reads as a point BEFORE
    /// the last resume. The old "must advance" rule dropped the direction on its first re-cut.
    @Test("a re-cut that reads as before the last resume point resumes from that point, not nowhere")
    func reCutJustAfterResumingKeepsTheLine() {
        #expect(SpeechResume.nextResume(previousOffset: 15, newOffset: 0, resumes: 1) == 15)
        #expect(SpeechResume.nextResume(previousOffset: 15, newOffset: 15, resumes: 1) == 15)
    }

    /// Antigravity, Step 37: a proportional mp3 estimate can land inside an emoji's surrogate pair or
    /// a combining accent; `String.Index(_:within:)` is nil there, so the remainder came out empty and
    /// the cut line was dropped as "finished".
    @Test("progress inside a multi-unit character snaps back to that character")
    func progressInsideACharacterSnapsBack() {
        let text = "Caf\u{0065}\u{0301} ahead, ⚠️ then turn left."
        for spoken in 0..<(text.utf16.count - 1) {   // the final "." alone is "finished"
            let resume = SpeechResume.resumeOffset(text: text, spokenUTF16: spoken)
            #expect(resume != nil, "offset \(spoken) must not read as finished")
            if let resume { #expect(!SpeechResume.remainder(of: text, from: resume).isEmpty) }
        }
        let insideEmoji = offset(of: "⚠️", in: text) + 1
        #expect(SpeechResume.remainder(of: text, from: insideEmoji).hasPrefix("⚠️"))
        // Offsets are UTF-16 units, not Characters: "é" here is two units, so the clause after it
        // starts one unit later than a Character count would say.
        let clause = offset(of: "⚠️", in: text)
        #expect(SpeechResume.resumeOffset(text: text, spokenUTF16: clause + 3) == clause)
        #expect(clause == text.distance(from: text.startIndex, to: text.range(of: "⚠️")!.lowerBound) + 1)
    }

    @Test("a different kind of line gets a short pause first; the same kind and a safety line do not")
    func gapBetweenKinds() {
        #expect(SpeechResume.gapSeconds(previousBand: 3, nextBand: 2, safetyBand: 3) == 0.35)
        #expect(SpeechResume.gapSeconds(previousBand: 1, nextBand: 2, safetyBand: 3) == 0.35)
        #expect(SpeechResume.gapSeconds(previousBand: 2, nextBand: 2, safetyBand: 3) == 0)
        #expect(SpeechResume.gapSeconds(previousBand: 2, nextBand: 3, safetyBand: 3) == 0)   // safety never waits
        #expect(SpeechResume.gapSeconds(previousBand: nil, nextBand: 1, safetyBand: 3) == 0)
        // The safety band is the caller's, not a copied literal (Muse, Step 37).
        #expect(SpeechResume.gapSeconds(previousBand: 2, nextBand: 3, safetyBand: 4) == 0.35)
    }

    /// Muse, Step 37: a natural voice does not spend time evenly on every character, so a cut during a
    /// pause maps to a point ahead of what the walker heard. Backing off half a second of speech
    /// before choosing the clause resumes the clause that was being heard, never the one after it.
    @Test("mp3 progress backs off half a second of speech so a resume never skips the clause being heard")
    func mp3ProgressBacksOff() {
        let text = "Leaving Townsend Hall, then the path west."
        let clause2 = offset(of: "then", in: text)
        // Estimate lands 3 characters into clause 2; heard audio may still be in clause 1.
        let estimate = SpeechResume.spokenUTF16(text: text, playedFraction: Double(clause2 + 3) / Double(text.utf16.count))
        let heard = SpeechResume.mp3HeardUTF16(estimate: estimate)
        #expect(heard == max(0, estimate - SpeechResume.mp3MarginUTF16))
        #expect(SpeechResume.resumeOffset(text: text, spokenUTF16: heard) == 0)
        #expect(SpeechResume.mp3HeardUTF16(estimate: 3) == 0)
    }
}
