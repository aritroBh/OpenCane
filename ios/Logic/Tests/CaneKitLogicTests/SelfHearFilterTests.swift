//
//  SelfHearFilterTests.swift
//  CaneKitLogicTests
//
//  Pins `SelfHearFilter` (Step 55): the recogniser must never hand the app its own voice back as
//  the walker's question.
//
//  Why: the first cane-mounted walk logged `conv_error query: "Head height"` — "Head height." is
//  `.safety`, it breaks through the voice hold while the walker is dictating, the microphone has
//  no echo control (hard rule 7: no `.voiceChat`, no HFP), and the recogniser transcribed the
//  phone's own warning as a question. Two defences exist: the tap drops buffers while the app
//  speaks (+ `tailSeconds`), and this filter drops a final transcript that is one of the app's own
//  recent lines. The match is *whole line or whole clause*, never "line contains transcript": the
//  voice menu line contains the word "route", and "route" is the one word the shell must hear.
//
//  Source pinned: `SelfHearFilter.swift` (`window`, `tailSeconds`, `minTranscriptCharacters`,
//  `normalize`, `clauses`, `record(line:at:)`, `shouldDrop(transcript:now:)`). Owner:
//  `VoiceInputEngine` (app), fed by `AppModel`'s `speech.onDispatch` hook while listening.
//

import Foundation
import Testing

@testable import CaneKitLogic

/// 3 s window, 0.3 s tail, 3-character floor — all [H], tuned from `voice_self_hear` records.
@Test func selfHearNumbersArePinned() {
    #expect(SelfHearFilter.window == 3)
    #expect(SelfHearFilter.tailSeconds == 0.3)
    #expect(SelfHearFilter.minTranscriptCharacters == 3)
}

/// The field-log case: "Head height." dispatched 1 s ago, transcript "Head height" → dropped, and
/// the matched line is returned so the log can name it.
@Test func exactLineWithinThreeSecondsIsDropped() {
    var f = SelfHearFilter()
    f.record(line: "Head height.", at: 10)
    #expect(f.shouldDrop(transcript: "Head height", now: 11) == "Head height.")
}

/// Case, punctuation and run-on whitespace are the recogniser's, not the walker's.
@Test func punctuationAndCaseDoNotMatter() {
    var f = SelfHearFilter()
    f.record(line: "Two meters ahead, drop-off.", at: 0)
    #expect(f.shouldDrop(transcript: "two   METERS ahead drop off", now: 1) != nil)
    #expect(SelfHearFilter.normalize("  Head height.  ") == "head height")
    #expect(SelfHearFilter.normalize("Veer left! Please?") == "veer left please")
    // Digits survive: the IVR aliases are "1"…"8" and a distance is a number.
    #expect(SelfHearFilter.normalize("Options: 1 route, 2 where am I.") == "options 1 route 2 where am i")
}

/// The recogniser often catches only the tail of a line: a whole clause of a recent line is the
/// app's voice too. Clauses split where `SpeechResume.clauseEnders` split a resumed line.
@Test func aClauseOfARecentLineIsDropped() {
    var f = SelfHearFilter()
    f.record(line: "Two meters ahead, drop-off.", at: 0)
    #expect(f.shouldDrop(transcript: "drop-off", now: 1) == "Two meters ahead, drop-off.")
    #expect(f.shouldDrop(transcript: "Two meters ahead", now: 1) != nil)
    #expect(SelfHearFilter.clauses(of: "Route started. Townsend Hall to CIF. First: walk 50 meters.")
            == ["route started", "townsend hall to cif", "first", "walk 50 meters"])
    // A decimal point is not followed by whitespace, so "2.5" never splits into two clauses; inside
    // the clause `normalize` turns the point into a space, on both sides of every comparison.
    #expect(SelfHearFilter.clauses(of: "2.5 meters ahead, table") == ["2 5 meters ahead", "table"])
}

/// The walker's own words are kept: nothing recorded, or a recorded line that merely shares words
/// with the transcript. "Line contains transcript" would drop "route" after the menu line.
@Test func theWalkersOwnWordsAreKept() {
    var empty = SelfHearFilter()
    #expect(empty.shouldDrop(transcript: "where am I", now: 5) == nil)
    var f = SelfHearFilter()
    f.record(line: "Head height.", at: 10)
    #expect(f.shouldDrop(transcript: "take me to Grainger", now: 11) == nil)
    #expect(f.shouldDrop(transcript: "I heard you say head height", now: 11) == nil)
    #expect(f.shouldDrop(transcript: "is that head height", now: 11) == nil)
    var menu = SelfHearFilter()
    menu.record(line: "Say route, where am I, describe, status, repeat, quiet, help, or emergency.", at: 0)
    #expect(menu.shouldDrop(transcript: "route", now: 1) == nil)          // a word, not a clause
    #expect(menu.shouldDrop(transcript: "Townsend Hall", now: 1) == nil)  // part of no clause
    #expect(empty.history.isEmpty)
}

/// A line older than the window is the past: 3.1 s after "Head height." the same words are the
/// walker's. Pruning is by the window; the boundary itself (exactly 3 s) still matches.
@Test func oldLinesAgeOut() {
    var f = SelfHearFilter()
    f.record(line: "Head height.", at: 10)
    #expect(f.shouldDrop(transcript: "head height", now: 13) != nil)
    #expect(f.shouldDrop(transcript: "head height", now: 13.1) == nil)
    // Recording a new line prunes the stale ones.
    f.record(line: "Left.", at: 20)
    #expect(f.history.map(\.line) == ["Left."])
}

/// Under `minTranscriptCharacters` nothing is ever dropped: "a", "1" and "no" are too short to be
/// an echo worth guessing about, and the IVR digits must always get through.
@Test func shortFragmentsNeverMatch() {
    var f = SelfHearFilter()
    f.record(line: "1.", at: 0)
    f.record(line: "No.", at: 0)
    #expect(f.shouldDrop(transcript: "1", now: 1) == nil)
    #expect(f.shouldDrop(transcript: "no", now: 1) == nil)
    #expect(f.shouldDrop(transcript: "a", now: 1) == nil)
    // Three characters is the floor and matches.
    f.record(line: "Yes.", at: 0)
    #expect(f.shouldDrop(transcript: "yes", now: 1) == "Yes.")
}

/// Recording is explicit and the app records only while it is listening: a line dispatched before
/// the microphone opened (the launch menu, an answer) is never in the history, so answering the
/// menu with one of its own words ("status") is never dropped. The filter itself has no clock and
/// no dispatch hook; `reset()` empties it for the next press.
@Test func recordingIsExplicitAndResetEmptiesTheHistory() {
    var f = SelfHearFilter()
    #expect(f.shouldDrop(transcript: "status", now: 1) == nil)
    f.record(line: "status", at: 0)
    #expect(f.shouldDrop(transcript: "status", now: 1) != nil)
    f.reset()
    #expect(f.history.isEmpty)
    #expect(f.shouldDrop(transcript: "status", now: 1) == nil)
    // Blank lines are never recorded.
    f.record(line: "   ", at: 0)
    #expect(f.history.isEmpty)
}
