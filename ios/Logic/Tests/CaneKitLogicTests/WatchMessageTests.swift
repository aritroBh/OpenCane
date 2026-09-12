//
//  WatchMessageTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins WatchMessage.swift — the phone ↔ watch wire format under key "m": every
//  message round-trips, and anything unknown (older / newer app) decodes to nil, never throws.
//
//  Callers of the pinned code: `PhoneWatchLink` (phone) and `WatchModel` (watch) encode / decode
//  every WatchConnectivity message through `WatchEnvelope`. The phone and watch are separately
//  installed binaries, so case names and raw values are a wire format: adding a case is safe,
//  renaming or removing one is not. Breaks these catch: a message that does not survive the trip,
//  and a version-skewed payload crashing either side instead of being ignored.
//

import Foundation
import Testing
@testable import CaneKitLogic

/// Every phone → watch message (nav tap, obstacle mirror, status line) survives WatchConnectivity.
@Test func phoneToWatchRoundTrips() throws {
    let cases: [PhoneToWatch] = [
        .nav(.turnLeft), .nav(.arrived), .obstacle(.head), .obstacle(.clear),
        .status(instruction: "Goodwin Avenue. Crossing.", distanceM: 42),
    ]
    for m in cases {
        let dict = try WatchEnvelope.encode(m)
        #expect(dict[WatchEnvelope.key] is Data)
        #expect(WatchEnvelope.decodePhoneToWatch(dict) == m)
    }
}

/// Every watch button command (Next, Describe, Recenter, Repeat) survives WatchConnectivity.
@Test func watchToPhoneRoundTrips() throws {
    for m in WatchToPhone.allCases {
        let dict = try WatchEnvelope.encode(m)
        #expect(WatchEnvelope.decodeWatchToPhone(dict) == m)
    }
}

/// A phone and watch on different app versions ignore unknown messages instead of crashing.
@Test func unknownPayloadsDecodeToNil() {
    #expect(WatchEnvelope.decodePhoneToWatch([:]) == nil)
    #expect(WatchEnvelope.decodePhoneToWatch(["m": "not data"]) == nil)
    #expect(WatchEnvelope.decodePhoneToWatch(["m": Data("{\"teleport\":{}}".utf8)]) == nil)
    #expect(WatchEnvelope.decodeWatchToPhone(["m": Data("\"warp\"".utf8)]) == nil)
}
