//
//  WatchMessageTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins WatchMessage.swift — the phone ↔ watch wire format under key "m": every
//  message round-trips, and anything unknown (older / newer app) decodes to nil, never throws.
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
