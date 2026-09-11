import Foundation
import Testing
@testable import CaneKitLogic

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

@Test func watchToPhoneRoundTrips() throws {
    for m in WatchToPhone.allCases {
        let dict = try WatchEnvelope.encode(m)
        #expect(WatchEnvelope.decodeWatchToPhone(dict) == m)
    }
}

@Test func unknownPayloadsDecodeToNil() {
    #expect(WatchEnvelope.decodePhoneToWatch([:]) == nil)
    #expect(WatchEnvelope.decodePhoneToWatch(["m": "not data"]) == nil)
    #expect(WatchEnvelope.decodePhoneToWatch(["m": Data("{\"teleport\":{}}".utf8)]) == nil)
    #expect(WatchEnvelope.decodeWatchToPhone(["m": Data("\"warp\"".utf8)]) == nil)
}
