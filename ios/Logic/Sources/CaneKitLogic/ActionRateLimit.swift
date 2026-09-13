//
//  ActionRateLimit.swift
//  CaneKitLogic
//
//  Stops a button that talks to the network from being spammed. "Send test event" and "Save family
//  emails" both POST to the Grok Bot webhook, and the bot starts a *run* per call — a walker (or a
//  curious demo audience) holding a finger on the button would burn its quota in seconds and, with
//  `send_test`, email the family once per tap.
//
//  Why a shared limiter and not `.disabled(inFlight)`: disabling only covers the round trip, which
//  is often under a second. The limit that matters is per *action over time*, and it has to hold
//  even when the request fails instantly (offline: a tap then returns in milliseconds).
//
//  Owner: `AppModel` holds one and keys it by action name.
//
//  Key invariants:
//    · Pure: `now` is the caller's seconds, so tests need no clock and the UI can show a countdown.
//    · `allow` records the attempt only when it says yes — a refused tap must not push the next
//      allowed one further away, or holding the button would lock the action out forever.
//  Tests: ActionRateLimitTests.swift.
//

import Foundation

/// Minimum spacing between repeats of a named action.
public struct ActionRateLimit {

    /// Seconds between two runs of the same action. 10 s is the figure the owner asked for: long
    /// enough that spamming is pointless, short enough that a genuine retry after a failure does
    /// not feel broken.
    public static let defaultInterval: TimeInterval = 10

    public var interval: TimeInterval
    private var lastRun: [String: TimeInterval] = [:]

    public init(interval: TimeInterval = defaultInterval) {
        self.interval = interval
    }

    /// True when `action` may run now, recording it as run. False means "too soon".
    public mutating func allow(_ action: String, now: TimeInterval) -> Bool {
        if let last = lastRun[action], now - last < interval { return false }
        lastRun[action] = now
        return true
    }

    /// Whole seconds until `action` is allowed again, or 0 when it is allowed now. For the UI's
    /// "wait 7 seconds" line — a button that silently does nothing reads as a bug.
    public func secondsRemaining(_ action: String, now: TimeInterval) -> Int {
        guard let last = lastRun[action] else { return 0 }
        let left = interval - (now - last)
        return left <= 0 ? 0 : Int(left.rounded(.up))
    }

    /// Forgets every recorded run. Used by tests; the app never needs it.
    public mutating func reset() { lastRun = [:] }
}
