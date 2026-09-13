//
//  ConversationBudgetTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins ConversationBudget.swift — the latency budget of a cloud conversation turn and
//  the latest-wins rule (Step 57).
//
//  Why these are the tests: the first mounted walk had cloud turns of 6–17 s with no budget, a
//  second question dropped ("Still working on your last question." ×N) and nothing said in between.
//  A blind walker needs to hear *something* within 1.5 s, an answer or a timeout by 4 s, and the
//  last question asked to be the one answered. Every number here is [H] until a walk log tunes it.
//
//  Source pinned: `ios/Logic/Sources/CaneKitLogic/ConversationBudget.swift` (`fillerAfter` 1.5,
//  `budget` 4.0, `fillerLine`, `timeoutLine`, `begin(now:)`, `tick(now:)`, `finished(id:)`,
//  `inFlightID`, `fillerSpoken`, `elapsedMs(now:)`). Caller: `ConversationCoordinator.handleQuery`
//  (app), which starts a turn only for the cloud path, ticks every 0.25 s, cancels the in-flight
//  task on a new query and drops a completion whose `finished(id:)` is false.
//

import Testing
@testable import CaneKitLogic

@Suite("Conversation budget — latest wins")
struct ConversationBudgetTests {

    /// The two numbers and the two lines. 1.5 s is the longest silence that still reads as
    /// "heard you"; 4 s is where a walker stops waiting and asks again.
    @Test func numbersArePinned() {
        #expect(ConversationBudget.fillerAfter == 1.5)
        #expect(ConversationBudget.budget == 4.0)
        #expect(ConversationBudget.fillerAfter < ConversationBudget.budget)
        #expect(ConversationBudget.fillerLine == "One moment.")
        #expect(ConversationBudget.timeoutLine.hasSuffix("."))
    }

    /// The filler is spoken exactly once, at 1.5 s, and not again on later ticks.
    @Test func fillerFiresOnceAtOneAndAHalfSeconds() {
        var b = ConversationBudget()
        _ = b.begin(now: 10)
        var e = b.tick(now: 11.4)
        #expect(e == .none)
        e = b.tick(now: 11.5)
        #expect(e == .speakFiller)
        e = b.tick(now: 11.75)
        #expect(e == .none)
        e = b.tick(now: 13.0)
        #expect(e == .none)
        #expect(b.fillerSpoken)
    }

    /// At 4 s the turn times out: one `.timeout`, the turn is no longer in flight, a late result is
    /// refused, and later ticks are quiet.
    @Test func timeoutAtFourSeconds() {
        var b = ConversationBudget()
        let id = b.begin(now: 0)
        _ = b.tick(now: 1.5)
        var e = b.tick(now: 3.99)
        #expect(e == .none)
        e = b.tick(now: 4.0)
        #expect(e == .timeout)
        #expect(b.inFlightID == nil)
        let late = b.finished(id: id)
        #expect(late == false)
        e = b.tick(now: 4.25)
        #expect(e == .none)
    }

    /// A new query while one is in flight supersedes it: new id, the old id is refused, the
    /// filler clock restarts for the new turn.
    @Test func aNewQuerySupersedesTheOldOne() {
        var b = ConversationBudget()
        let first = b.begin(now: 0)
        _ = b.tick(now: 1.5)                       // filler spoken for the first turn
        let second = b.begin(now: 2.0)
        #expect(second != first)
        #expect(b.inFlightID == second)
        #expect(!b.fillerSpoken)                   // the new turn has not said "One moment." yet
        var e = b.tick(now: 3.4)
        #expect(e == .none)
        e = b.tick(now: 3.5)
        #expect(e == .speakFiller)
        let stale = b.finished(id: first)
        #expect(stale == false)
        let fresh = b.finished(id: second)
        #expect(fresh == true)
        #expect(b.inFlightID == nil)
    }

    /// A completion for a superseded turn must never speak: `finished` says drop it and leaves the
    /// live turn untouched.
    @Test func aLateResultForASupersededTurnIsIgnored() {
        var b = ConversationBudget()
        let first = b.begin(now: 0)
        let second = b.begin(now: 1)
        let stale = b.finished(id: first)
        #expect(stale == false)
        #expect(b.inFlightID == second)
        let e = b.tick(now: 2.5)
        #expect(e == .speakFiller)
    }

    /// A fast-path answer never begins a turn, so a stray tick with nothing in flight is silent
    /// and a `finished` for an unknown id is refused.
    @Test func fastPathTurnsNeverStartTheClock() {
        var b = ConversationBudget()
        #expect(b.inFlightID == nil)
        let e = b.tick(now: 100)
        #expect(e == .none)
        let unknown = b.finished(id: 42)
        #expect(unknown == false)
        #expect(!b.fillerSpoken)
    }

    /// An answer that arrives before 1.5 s: no filler, the turn ends, ticks afterwards are quiet,
    /// and the elapsed time is what the log records.
    @Test func finishedBeforeFillerSpeaksNoFiller() {
        var b = ConversationBudget()
        let id = b.begin(now: 0)
        var e = b.tick(now: 0.25)
        #expect(e == .none)
        #expect(b.elapsedMs(now: 0.9) == 900)
        let ok = b.finished(id: id)
        #expect(ok == true)
        #expect(!b.fillerSpoken)
        e = b.tick(now: 1.5)
        #expect(e == .none)
        e = b.tick(now: 4.0)
        #expect(e == .none)
    }

    /// A new query that takes the fast path (a "stop" during a slow cloud answer) cancels the
    /// in-flight turn without starting a clock: its late result is refused and no filler follows.
    @Test func cancelRefusesTheLiveTurn() {
        var b = ConversationBudget()
        let id = b.begin(now: 0)
        b.cancel()
        #expect(b.inFlightID == nil)
        let e = b.tick(now: 2)
        #expect(e == .none)
        let late = b.finished(id: id)
        #expect(late == false)
    }
}
