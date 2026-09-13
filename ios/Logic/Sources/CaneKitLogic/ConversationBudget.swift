//
//  ConversationBudget.swift
//  CaneKitLogic
//
//  The latency budget of one cloud conversation turn, and the latest-wins rule (Step 57).
//
//  Why this exists: on the first cane-mounted walk (2026-09-13) cloud turns took 6–17 s with no
//  bound, a second question during one was dropped, and the walker heard "Still working on your
//  last question." several times. A blind walker cannot see a spinner: silence past a second or
//  two reads as "it did not hear me", so they ask again — and the app must then answer the *new*
//  question, not the old one. This type decides, from a clock the caller passes, when to say
//  "One moment.", when to give up, and which completion is still the live one.
//
//  Key invariants:
//    · Only the cloud path begins a turn. Fast-path and scene answers never start the clock
//      (`fastPathTurnsNeverStartTheClock`).
//    · The filler is spoken once per turn, at `fillerAfter` (`fillerFiresOnceAtOneAndAHalfSeconds`).
//    · At `budget` the turn times out exactly once; afterwards the turn is not in flight and a late
//      completion is refused (`timeoutAtFourSeconds`).
//    · `begin` while a turn is in flight supersedes it: the old id is refused forever
//      (`aNewQuerySupersedesTheOldOne`, `aLateResultForASupersededTurnIsIgnored`).
//    · Deterministic: `now` is the caller's clock; ids are a counter, never reused in one instance.
//
//  Owner / caller: `ConversationCoordinator.handleQuery` (app, main actor) — one instance per
//  coordinator; `begin` before the cloud task, a 0.25 s ticker calling `tick`, `finished(id:)`
//  gating the spoken answer; the coordinator cancels the superseded `Task` itself and writes
//  `budget_ms` / `filler_spoken` / `superseded` / `timed_out` to `conv_turn`.
//  Isolation: nonisolated `Sendable` value held in one main-actor `var`.
//  Tests: ConversationBudgetTests.swift (8).
//

import Foundation

/// Filler-and-timeout clock for one cloud turn; latest query wins.
public struct ConversationBudget: Sendable, Equatable {

    /// Seconds of silence before "One moment." is spoken. [H] 1.5 s: the longest pause that still
    /// reads as "heard you" (the same number as `UtteranceEndDetector.silenceAfterSpeech`, for
    /// the same reason — a breath, not a wait).
    public static let fillerAfter: Double = 1.5

    /// Seconds after which the cloud turn is abandoned and `timeoutLine` spoken. [H] 4 s: past it
    /// the walker on the first walk had already asked again.
    public static let budget: Double = 4.0

    /// Spoken once at `fillerAfter`. Prefetched (`SpokenPhrases.shellLines`), so it is natural voice.
    public static let fillerLine = "One moment."

    /// Spoken at `budget`. Prefetched. It tells the walker what to do, not what went wrong.
    public static let timeoutLine = "That is taking too long. Ask again in a moment."

    /// What the ticker should do now.
    public enum Event: Sendable, Equatable {
        /// Nothing.
        case none
        /// Speak `fillerLine` (once per turn).
        case speakFiller
        /// Cancel the cloud task, speak `timeoutLine`, log `conv_error {timeout: true}`.
        case timeout
    }

    /// The id of the live turn, nil when nothing is in flight.
    public private(set) var inFlightID: Int?
    /// Whether the live turn has already spoken the filler (`conv_turn.filler_spoken`).
    public private(set) var fillerSpoken = false
    /// When the live turn began (the caller's clock).
    private var startedAt: Double = 0
    /// Monotonic id source; never reused within one instance.
    private var nextID = 0

    public init() {}

    /// Start a turn. A turn already in flight is superseded: its id is refused from now on.
    /// - Parameter now: the caller's clock.
    /// - Returns: the new turn's id; pass it to `finished(id:)`.
    public mutating func begin(now: Double) -> Int {
        nextID += 1
        inFlightID = nextID
        startedAt = now
        fillerSpoken = false
        return nextID
    }

    /// Advance the clock. Call every 0.25 s while a turn is in flight (a tick with none is `.none`).
    /// The timeout wins over the filler when both are due on one tick (a stalled main actor).
    /// - Parameter now: the caller's clock.
    /// - Returns: what to do now.
    public mutating func tick(now: Double) -> Event {
        guard inFlightID != nil else { return .none }
        let elapsed = now - startedAt
        if elapsed >= Self.budget {
            inFlightID = nil
            return .timeout
        }
        if !fillerSpoken, elapsed >= Self.fillerAfter {
            fillerSpoken = true
            return .speakFiller
        }
        return .none
    }

    /// A completion arrived for turn `id`. True only for the live turn, which then ends; false for
    /// a superseded, timed-out or unknown id — drop that result, say nothing.
    /// - Parameter id: the id `begin` returned for that turn.
    /// - Returns: whether the result may be spoken.
    public mutating func finished(id: Int) -> Bool {
        guard inFlightID == id else { return false }
        inFlightID = nil
        return true
    }

    /// Drop the live turn without starting a new one: a query that took the fast path while a cloud
    /// turn was in flight (latest wins). Its late result is refused and no filler or timeout follows.
    /// Pinned by `cancelRefusesTheLiveTurn`.
    public mutating func cancel() {
        inFlightID = nil
    }

    /// Milliseconds since the live (or most recent) turn began, for `conv_turn.budget_ms`.
    /// - Parameter now: the caller's clock.
    public func elapsedMs(now: Double) -> Int {
        Int(((now - startedAt) * 1000).rounded())
    }
}
