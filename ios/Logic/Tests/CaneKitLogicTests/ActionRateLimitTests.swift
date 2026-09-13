//
//  ActionRateLimitTests.swift
//  CaneKitLogicTests
//
//  Pins the spam guard on the buttons that POST to the Grok Bot webhook. Each tap starts a bot
//  run, and "Save family emails" can email the whole family, so a held finger must not become a
//  hundred requests.
//

import Foundation
import Testing
@testable import CaneKitLogic

/// The first run is allowed; a second inside the interval is not; after it, yes again.
@Test func repeatsAreSpacedByTheInterval() {
    var limit = ActionRateLimit()
    let interval = limit.interval

    let first = limit.allow("test", now: 0)
    let tooSoon = limit.allow("test", now: interval - 0.1)
    let due = limit.allow("test", now: interval)

    #expect(first)
    #expect(!tooSoon)
    #expect(due)
}

/// The owner asked for "one every ten seconds max".
@Test func defaultIntervalIsTenSeconds() {
    #expect(ActionRateLimit.defaultInterval == 10)
}

/// ⚠ A refused attempt must NOT push the next allowed one further away — otherwise holding the
/// button down would lock the action out forever.
@Test func refusedAttemptsDoNotExtendTheWait() {
    var limit = ActionRateLimit()
    _ = limit.allow("test", now: 0)
    var anyAllowedEarly = false
    for t in stride(from: 0.5, to: 10.0, by: 0.5) where limit.allow("test", now: t) {
        anyAllowedEarly = true                       // spam
    }
    let onTime = limit.allow("test", now: 10)
    #expect(!anyAllowedEarly)
    #expect(onTime)                                  // still allowed exactly on time
}

/// Actions are independent: saving contacts does not block the test send.
@Test func actionsAreIndependent() {
    var limit = ActionRateLimit()
    let a = limit.allow("test", now: 0)
    let b = limit.allow("contacts", now: 0)
    #expect(a)
    #expect(b)
}

/// The UI needs a number to show, so a refused tap can say why instead of looking broken.
@Test func secondsRemainingCountsDown() {
    var limit = ActionRateLimit()
    #expect(limit.secondsRemaining("test", now: 0) == 0)     // never run: available
    _ = limit.allow("test", now: 0)
    #expect(limit.secondsRemaining("test", now: 0) == 10)
    #expect(limit.secondsRemaining("test", now: 6.2) == 4)   // rounded up
    #expect(limit.secondsRemaining("test", now: 10) == 0)
    #expect(limit.secondsRemaining("test", now: 99) == 0)
}
