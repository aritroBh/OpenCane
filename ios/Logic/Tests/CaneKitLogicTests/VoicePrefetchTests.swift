//
//  VoicePrefetchTests.swift
//  CaneKitLogicTests
//
//  Pins the two rules that decide whether the first cue of a walk is instant or late.
//

import Foundation
import Testing

@testable import CaneKitLogic

@Test func prefetchKeepsSpeakingOrderSoTheFirstCueIsReadyFirst() {
    let lines = ["Starting the route.", "Turn left onto Goodwin.", "Cross Green Street.",
                 "Turn right onto Springfield.", "Arrived at CIF."]
    let queued = VoicePrefetch.queue(lines) { _ in false }
    // Requested in speaking order: with only `maxConcurrent` in flight, request order is
    // completion order, and the walker hears line 1 before line 5.
    #expect(queued == lines)
}

@Test func prefetchDropsRepeatsAndAlreadyCachedLinesButKeepsTheRest() {
    let lines = ["Cross the street.", "Turn left.", "Cross the street.", "Arrived."]
    let queued = VoicePrefetch.queue(lines) { $0 == "Turn left." }
    #expect(queued == ["Cross the street.", "Arrived."])
}

@Test func prefetchIgnoresBlankLines() {
    #expect(VoicePrefetch.queue(["", "   ", "Turn left."]) { _ in false } == ["Turn left."])
    #expect(VoicePrefetch.queue([]) { _ in false }.isEmpty)
}

@Test func aBadKeyStopsThePrefetchInsteadOfRepeatingItselfTwentyTimes() {
    // Wrong / expired / unscoped key, and an unusable voice or model: every remaining line fails
    // the same way, so asking again is pure noise.
    #expect(VoicePrefetch.isFatal(status: 401))
    #expect(VoicePrefetch.isFatal(status: 403))
    #expect(VoicePrefetch.isFatal(status: 422))
    // Bad luck, not a bad key: the next line is still worth trying.
    #expect(!VoicePrefetch.isFatal(status: 429))
    #expect(!VoicePrefetch.isFatal(status: 500))
    #expect(!VoicePrefetch.isFatal(status: 503))
    #expect(!VoicePrefetch.isFatal(status: 200))
}

@Test func prefetchConcurrencyLeavesRoomForALiveRequest() {
    // The ElevenLabs free tier allows two concurrent requests. Prefetch must not use them all,
    // or a live cache miss — the line someone is waiting for — comes back 429.
    #expect(VoicePrefetch.maxConcurrent == 2)
    #expect(VoicePrefetch.maxConcurrent < 3)
}
