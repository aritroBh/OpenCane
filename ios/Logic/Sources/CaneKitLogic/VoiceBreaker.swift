//
//  VoiceBreaker.swift
//  CaneKitLogic
//
//  The natural voice's circuit breaker: after a live fetch fails or misses its deadline, no line
//  races the network again until a *background* fetch has proven the network is back.
//
//  Why it is session-sticky (Step 54, owner decision 2026-09-13 "one voice"): the old breaker was
//  a timestamp — 60 s after a failure the next uncached line raced the network again, failed
//  again after 2.5 s in silence, and flipped to the system voice again. Over a long outage that is
//  a wrong-voice line, late, every minute. Now a trip opens the breaker and only proof closes it:
//  `SpeechQueue.prefetch` keeps running in the background (the lines that missed are in its
//  backlog), and when a batch that actually requested something returns with no failure the
//  breaker closes. While open, a probe is due every `probeInterval` so a venue's Wi-Fi coming back
//  is noticed within a minute; the probe is the same prefetch, so a dead network costs one small
//  request a minute and never a line's 2.5 s.
//
//  Owner: `SpeechQueue` (app) holds one value and logs every state change as
//  `voice_breaker {open, reason}`. Cache hits are unaffected by the breaker (a file on disk needs
//  no fetch — see `VoiceEngineChoice.decide`).
//  Isolation: a plain `Sendable` value; single owner, `mutating` updates.
//  Tests: VoiceEngineChoiceTests.swift (`breaker…` tests).
//

import Foundation

/// Open = the natural voice is treated as unreachable; closed = fetches may race again.
public struct VoiceBreaker: Sendable, Equatable {

    /// Seconds between background probes while open ([H]). Pinned by
    /// `breakerProbeIntervalAndReasonsArePinned`.
    public static let probeInterval: TimeInterval = 60

    /// Why the breaker changed state — the `reason` field of the `voice_breaker` log record.
    /// ⚠ Raw values are a log contract; never rename.
    public enum Reason: String, Sendable, Equatable {
        /// A live fetch missed `VoiceEngineChoice.raceDeadline`.
        case raceTimeout = "race_timeout"
        /// A live fetch failed (HTTP error, transport error).
        case raceFailed = "race_failed"
        /// A background prefetch that requested at least one line finished with no failure.
        case prefetchSucceeded = "prefetch_succeeded"
    }

    /// True while the natural voice is treated as unreachable.
    public private(set) var isOpen = false
    /// When the breaker opened or was last probed (reference-date seconds); nil while closed.
    public private(set) var lastProbeAt: TimeInterval?

    /// Closed.
    public init() {}

    /// A live race failed or timed out. Opens the breaker.
    /// - Parameters:
    ///   - reason: `raceTimeout` or `raceFailed` (a `prefetchSucceeded` here is ignored).
    ///   - now: reference-date seconds; starts the probe clock.
    /// - Returns: true when this call changed the state (the caller logs `voice_breaker`).
    @discardableResult
    public mutating func trip(_ reason: Reason, now: TimeInterval) -> Bool {
        guard reason != .prefetchSucceeded else { return false }
        guard !isOpen else { return false }
        isOpen = true
        lastProbeAt = now
        return true
    }

    /// A background prefetch batch finished with no failure. Closes the breaker only if the batch
    /// actually requested something: a batch with nothing left to fetch proves nothing.
    /// - Parameter requested: how many lines the batch sent to the network.
    /// - Returns: true when this call changed the state.
    @discardableResult
    public mutating func prefetchSucceeded(requested: Int) -> Bool {
        guard isOpen, requested > 0 else { return false }
        isOpen = false
        lastProbeAt = nil
        return true
    }

    /// Whether a background probe is due: open, and `probeInterval` since the trip or the last
    /// probe. Never while closed.
    /// - Parameter now: reference-date seconds.
    public func probeDue(now: TimeInterval) -> Bool {
        guard isOpen, let last = lastProbeAt else { return false }
        return now - last >= Self.probeInterval
    }

    /// A probe was started; restarts the probe clock. No-op while closed.
    /// - Parameter now: reference-date seconds.
    public mutating func probed(now: TimeInterval) {
        guard isOpen else { return }
        lastProbeAt = now
    }
}
