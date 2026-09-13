//
//  EarconTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins Earcon.swift — the calm-feedback catalog (seven short tones) and `EarconPolicy`,
//  the table that says, for every waiting / listening / busy event, whether the walker hears a
//  tone, words, both or nothing (Step 65).
//
//  Why these are the tests: owner, 2026-09-13 — "don't over-stimulate the blind person too much or
//  else they won't listen". The failure modes are (a) a tone long or loud enough to mask a route
//  line or the street (every tone ≤ 180 ms, ≤ −12 dBFS, measured on the synthesized samples, not on
//  the table), (b) a click at a tone's edges (the envelope must start and end at silence), (c) words
//  creeping back into the waiting states ("One moment.", "Still describing…", the warm-up
//  sentence), and (d) a window the walker did not open making a sound when it closes empty.
//
//  Source pinned: `ios/Logic/Sources/CaneKitLogic/Earcon.swift` (`Earcon`, `Earcon.Tone`,
//  `samples(gainOffsetDB:)`, `wavData(gainOffsetDB:)`, `EarconPolicy.feedback(for:)`,
//  `emptyPressCount(previous:heardWords:)`, `warmupTickDue(elapsed:ticksSoFar:)`, `gate`).
//  Callers: `EarconPlayer` / `SpeechQueue.playEarcon` (app), `VoiceInputEngine`,
//  `ConversationCoordinator`, `SceneDescriber`, `AppModel.queueRouteStart`.
//

import Foundation
import Testing
@testable import CaneKitLogic

@Suite("Earcons — calm feedback")
struct EarconTests {

    /// The two ceilings and the synthesis rate.
    @Test func ceilingsArePinned() {
        #expect(Earcon.maxDurationMs == 180)
        #expect(Earcon.maxGainDBFS == -12)
        #expect(Earcon.sampleRate == 44_100)
        #expect(Earcon.allCases.count == 7)
    }

    /// Every tone, as synthesized, is at most 180 ms long and peaks at or below −12 dBFS; the
    /// sample count matches the table's duration.
    @Test func everyEarconIsShortAndQuiet() {
        let ceiling = Float(pow(10, Earcon.maxGainDBFS / 20))
        for earcon in Earcon.allCases {
            #expect(earcon.durationMs <= Earcon.maxDurationMs, "\(earcon.rawValue) \(earcon.durationMs) ms")
            #expect(earcon.durationMs > 0)
            for tone in earcon.tones {
                #expect(tone.gainDBFS <= Earcon.maxGainDBFS, "\(earcon.rawValue)")
                #expect(tone.hz > 100 && tone.hz < 4_000, "\(earcon.rawValue)")
            }
            let s = earcon.samples()
            let expected = Int((earcon.durationMs / 1000 * Earcon.sampleRate).rounded())
            #expect(abs(s.count - expected) <= earcon.tones.count * 2, "\(earcon.rawValue) \(s.count) vs \(expected)")
            let peak = s.map { abs($0) }.max() ?? 0
            #expect(peak <= ceiling, "\(earcon.rawValue) peak \(peak)")
            #expect(peak > 0.005, "\(earcon.rawValue) is audible at all")
        }
    }

    /// No click: the first and last samples of every tone are (near) silence.
    @Test func envelopesStartAndEndSilent() {
        for earcon in Earcon.allCases {
            let s = earcon.samples()
            #expect(abs(s.first ?? 1) < 0.01, "\(earcon.rawValue) starts at \(s.first ?? 1)")
            #expect(abs(s.last ?? 1) < 0.01, "\(earcon.rawValue) ends at \(s.last ?? 1)")
        }
    }

    /// The shapes the names promise: listening rises, nothing falls, error is low, busy repeats one
    /// pitch, thinking is the quietest, heard and thinking are single short notes.
    @Test func shapesMatchTheirMeaning() {
        let listening = Earcon.listening.tones
        #expect(listening.count == 2 && listening[1].hz > listening[0].hz)
        let nothing = Earcon.nothing.tones
        #expect(nothing.count == 2 && nothing[1].hz < nothing[0].hz)
        #expect(Earcon.error.tones.count == 2 && Earcon.error.tones.allSatisfy { $0.hz < 300 })
        #expect(Earcon.busy.tones.count == 2 && Earcon.busy.tones[0].hz == Earcon.busy.tones[1].hz)
        #expect(Earcon.heard.tones.count == 1 && Earcon.heard.durationMs <= 60)
        #expect(Earcon.thinking.tones.count == 1 && Earcon.thinking.durationMs <= 30)
        let quietest = Earcon.allCases.min { $0.tones.map(\.gainDBFS).max()! < $1.tones.map(\.gainDBFS).max()! }
        #expect(quietest == .thinking)
    }

    /// A negative offset makes the follow-up cue quieter; a positive one is clamped (never louder
    /// than the table).
    @Test func gainOffsetOnlyEverLowers() {
        let full = Earcon.listening.samples().map { abs($0) }.max()!
        let soft = Earcon.listening.samples(gainOffsetDB: EarconPolicy.followUpGainOffsetDB).map { abs($0) }.max()!
        let loud = Earcon.listening.samples(gainOffsetDB: 12).map { abs($0) }.max()!
        #expect(soft < full * 0.5)
        #expect(loud == full)
    }

    /// The in-memory WAV is 16-bit mono PCM at 44.1 kHz with a correct RIFF header.
    @Test func wavDataIsAValidPCMFile() {
        let data = Earcon.heard.wavData()
        let samples = Earcon.heard.samples().count
        #expect(data.count == 44 + samples * 2)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: data[36..<40], as: UTF8.self) == "data")
        let u16 = { (o: Int) in UInt16(data[o]) | UInt16(data[o + 1]) << 8 }
        let u32 = { (o: Int) in UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }
        #expect(u16(20) == 1)            // PCM
        #expect(u16(22) == 1)            // mono
        #expect(u32(24) == 44_100)
        #expect(u16(34) == 16)
        #expect(u32(40) == UInt32(samples * 2))
        #expect(u32(4) == UInt32(data.count - 8))
    }

    // MARK: Policy

    /// Listening: a press, the launch listen and the emergency answer window get the full rising
    /// cue; the follow-up window gets it quieter. No words.
    @Test func listenOpensWithTheRisingCue() {
        for kind in [EarconPolicy.ListenKind.press, .launch, .question] {
            #expect(EarconPolicy.feedback(for: .listenOpened(kind))
                    == .init(earcon: .listening, gainOffsetDB: 0, line: nil))
        }
        let followUp = EarconPolicy.feedback(for: .listenOpened(.followUp))
        #expect(followUp.earcon == .listening && followUp.line == nil)
        #expect(followUp.gainOffsetDB == EarconPolicy.followUpGainOffsetDB)
        #expect(EarconPolicy.followUpGainOffsetDB < 0)
    }

    /// Mic closes with words → one tap; the app's own voice dropped by the self-hear filter → nothing.
    @Test func heardIsATapAndSelfHearIsSilent() {
        #expect(EarconPolicy.feedback(for: .listenHeardWords) == .init(earcon: .heard, gainOffsetDB: 0, line: nil))
        #expect(EarconPolicy.feedback(for: .listenSelfHeard) == .silent)
    }

    /// An empty press: the falling note; the words "I did not catch that." only on the second empty
    /// press in a row. A window the walker did not open closes in silence.
    @Test func emptyPressSaysWordsOnlyTheSecondTimeInARow() {
        #expect(EarconPolicy.emptyPressesBeforeWords == 2)
        let first = EarconPolicy.feedback(for: .listenEmpty(.press, emptyPressCount: 1))
        #expect(first == .init(earcon: .nothing, gainOffsetDB: 0, line: nil))
        let second = EarconPolicy.feedback(for: .listenEmpty(.press, emptyPressCount: 2))
        #expect(second == .init(earcon: .nothing, gainOffsetDB: 0, line: SpokenPhrases.notHeardLine))
        for kind in [EarconPolicy.ListenKind.launch, .followUp, .question] {
            #expect(EarconPolicy.feedback(for: .listenEmpty(kind, emptyPressCount: 2)) == .silent)
        }
    }

    /// The counter: words heard resets it; empty presses count 1, 2, then start again at 1, so a
    /// walker who keeps pressing hears the words every other time, never on every press.
    @Test func emptyPressCountCyclesAndResets() {
        var c = 0
        c = EarconPolicy.emptyPressCount(previous: c, heardWords: false); #expect(c == 1)
        c = EarconPolicy.emptyPressCount(previous: c, heardWords: false); #expect(c == 2)
        c = EarconPolicy.emptyPressCount(previous: c, heardWords: false); #expect(c == 1)
        c = EarconPolicy.emptyPressCount(previous: c, heardWords: true); #expect(c == 0)
        c = EarconPolicy.emptyPressCount(previous: c, heardWords: false); #expect(c == 1)
    }

    /// Waiting states are tones, not words; a timeout or a failed cloud turn is the low double tap
    /// and two words; a superseded turn is silent.
    @Test func waitingIsTonesNotWords() {
        #expect(EarconPolicy.feedback(for: .thinking) == .init(earcon: .thinking, gainOffsetDB: 0, line: nil))
        #expect(EarconPolicy.feedback(for: .describerBusy) == .init(earcon: .busy, gainOffsetDB: 0, line: nil))
        #expect(EarconPolicy.feedback(for: .routeWarming) == .init(earcon: .thinking, gainOffsetDB: 0, line: nil))
        #expect(EarconPolicy.feedback(for: .superseded) == .silent)
        let timeout = EarconPolicy.feedback(for: .timedOut)
        #expect(timeout == .init(earcon: .error, gainOffsetDB: 0, line: ConversationBudget.timeoutLine))
        #expect(EarconPolicy.feedback(for: .cloudFailed) == timeout)
        #expect(ConversationBudget.timeoutLine == "No answer.")
    }

    /// A gentle bell before a long answer only; a short one needs no announcement. Route ready:
    /// the bell and "Starting.".
    @Test func bellBeforeLongAnswersAndRouteStart() {
        #expect(EarconPolicy.longAnswerCharacters == 100)
        #expect(EarconPolicy.feedback(for: .answer(characters: 99)) == .silent)
        #expect(EarconPolicy.feedback(for: .answer(characters: 100)).earcon == .done)
        #expect(EarconPolicy.feedback(for: .answer(characters: 100)).line == nil)
        #expect(EarconPolicy.feedback(for: .routeReady) == .init(earcon: .done, gainOffsetDB: 0, line: "Starting."))
        #expect(EarconPolicy.routeReadyLine == "Starting.")
    }

    /// The warm-up tick: at 0, 2 and 4 s while depth warms up, never a fourth.
    @Test func warmupTicksEveryTwoSecondsAtMostThree() {
        #expect(EarconPolicy.warmupTickInterval == 2)
        #expect(EarconPolicy.warmupMaxTicks == 3)
        #expect(EarconPolicy.warmupTickDue(elapsed: 0, ticksSoFar: 0))
        #expect(!EarconPolicy.warmupTickDue(elapsed: 1.9, ticksSoFar: 1))
        #expect(EarconPolicy.warmupTickDue(elapsed: 2.0, ticksSoFar: 1))
        #expect(EarconPolicy.warmupTickDue(elapsed: 4.0, ticksSoFar: 2))
        #expect(!EarconPolicy.warmupTickDue(elapsed: 6.0, ticksSoFar: 3))
        #expect(!EarconPolicy.warmupTickDue(elapsed: 60, ticksSoFar: 3))
    }

    /// Muted automation never makes a sound; a `.safety` line playing is never covered by a tone.
    @Test func gateRefusesUnderMuteAndOverSafety() {
        #expect(EarconPolicy.gate(muted: false, safetySpeaking: false) == .play)
        #expect(EarconPolicy.gate(muted: true, safetySpeaking: false) == .skip(reason: "muted"))
        #expect(EarconPolicy.gate(muted: false, safetySpeaking: true) == .skip(reason: "safety_speaking"))
        #expect(EarconPolicy.gate(muted: true, safetySpeaking: true) == .skip(reason: "muted"))
    }
}
