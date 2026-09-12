//
//  UtteranceEndTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins UtteranceEnd.swift — when push-to-talk listening ends on its own. A blind walker
//  cannot see a "Listening…" label, so the engine must decide for them: submit once they have
//  stopped talking, give up when nothing was said, never cut a sentence that is still arriving.
//
//  Key invariants under test:
//    · Nothing is submitted before any words arrive (the walker may be thinking).
//    · A non-empty transcript that has not changed for `silenceAfterSpeech` (1.5 s) is submitted.
//    · Every partial-result change restarts the silence clock, so a slow talker is not cut off.
//    · The hard cap (`maxListen`, 10 s) still ends listening — with or without words — and a
//      run with words at the cap is a submit, not a timeout.
//    · Whitespace-only transcripts count as no words.
//

import Testing
@testable import CaneKitLogic

/// The two numbers the engine's behaviour is built on. 1.5 s is long enough for a breath between
/// clauses ("how is my… battery") and short enough that an answer feels immediate; 10 s is the
/// pre-existing push-to-talk cap, kept so a stuck recogniser can never hold the microphone (and
/// the muted beacon) indefinitely.
/// ⚠ Do not shorten `silenceAfterSpeech` without a device test that counts cut-off sentences.
@Test func endOfUtteranceNumbersArePinned() {
    #expect(UtteranceEndDetector.silenceAfterSpeech == 1.5)
    #expect(UtteranceEndDetector.maxListen == 10)
    #expect(UtteranceEndDetector.checkInterval == 0.25)
    #expect(UtteranceEndDetector.checkInterval < UtteranceEndDetector.silenceAfterSpeech)
}

/// Silence before the first word is thinking time, not the end of an utterance.
@Test func noWordsMeansKeepListeningUntilTheCap() {
    var d = UtteranceEndDetector(startedAt: 100)
    #expect(d.update(transcript: "", now: 100.5) == .listening)
    #expect(d.update(transcript: "   ", now: 105) == .listening)
    #expect(d.update(transcript: "", now: 109.9) == .listening)
    #expect(d.update(transcript: "", now: 110) == .timeout)
}

/// Words, then 1.5 s of an unchanged transcript → submit; a hair before that → still listening.
@Test func steadyTranscriptForOneAndAHalfSecondsSubmits() {
    var d = UtteranceEndDetector(startedAt: 0)
    #expect(d.update(transcript: "how is", now: 0.8) == .listening)
    #expect(d.update(transcript: "how is my battery", now: 1.4) == .listening)
    #expect(d.update(transcript: "how is my battery", now: 2.8) == .listening)   // 1.4 s quiet
    #expect(d.update(transcript: "how is my battery", now: 2.9) == .endOfUtterance)
}

/// A partial result that changes restarts the clock: a slow talker is not cut mid-sentence.
@Test func everyChangeRestartsTheSilenceClock() {
    var d = UtteranceEndDetector(startedAt: 0)
    #expect(d.update(transcript: "take me", now: 1.0) == .listening)
    #expect(d.update(transcript: "take me to", now: 2.4) == .listening)          // 1.4 s later, changed
    #expect(d.update(transcript: "take me to", now: 3.8) == .listening)          // 1.4 s quiet
    #expect(d.update(transcript: "take me to Grainger", now: 3.9) == .listening) // changed again
    #expect(d.update(transcript: "take me to Grainger", now: 5.3) == .listening)
    #expect(d.update(transcript: "take me to Grainger", now: 5.4) == .endOfUtterance)
}

/// The recogniser may re-punctuate or re-case the same words; only a change in the trimmed text
/// counts, so trailing whitespace does not keep the microphone open.
@Test func trailingWhitespaceIsNotAChange() {
    var d = UtteranceEndDetector(startedAt: 0)
    #expect(d.update(transcript: "stop", now: 1) == .listening)
    #expect(d.update(transcript: "stop ", now: 2) == .listening)
    #expect(d.update(transcript: " stop", now: 2.5) == .endOfUtterance)
}

/// The cap wins over an utterance still changing: with words on the clock it is a submit (the
/// walker's words are not thrown away), without words it is a timeout.
@Test func theHardCapEndsAChangingTranscriptAsASubmit() {
    var d = UtteranceEndDetector(startedAt: 0)
    for i in 1...9 {
        #expect(d.update(transcript: String(repeating: "word ", count: i), now: Double(i)) == .listening)
    }
    #expect(d.update(transcript: "word word word word word word word word word word", now: 10)
            == .endOfUtterance)
}

/// The submit verdict is not repeated once given: the engine stops on the first one and a stale
/// tick after that must not produce a second submission.
@Test func verdictIsStableAfterTheEnd() {
    var d = UtteranceEndDetector(startedAt: 0)
    _ = d.update(transcript: "hello", now: 1)
    #expect(d.update(transcript: "hello", now: 2.5) == .endOfUtterance)
    #expect(d.update(transcript: "hello", now: 3) == .endOfUtterance)
}
