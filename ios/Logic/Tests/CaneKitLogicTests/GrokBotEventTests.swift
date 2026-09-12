//
//  GrokBotEventTests.swift
//  CaneKitLogicTests
//
//  Pins the Grok Bot wire contract. These key names are not an implementation detail: the
//  routine "OpenCane cane events" parses them, and a rename here fails silently at run time
//  (HTTP 200, bot cannot read the fields, no SMS). So the names are asserted as bytes.
//

import Foundation
import Testing
@testable import CaneKitLogic

/// Decoded JSON object for an event, so a test can assert on the wire keys.
private func wire(_ event: OpenCaneEvent) throws -> [String: Any] {
    let data = try event.jsonBody()
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Every key the bot reads is snake_case and spelled exactly as the contract says.
@Test func wireKeysMatchTheContract() throws {
    let event = OpenCaneEvent(
        type: .fall, severity: .critical, timestamp: "2026-09-12T20:30:00Z",
        lat: 40.1106, lng: -88.2284, accuracyM: 5, heading: 270, speedMps: 1.3,
        note: "Possible fall detected", label: "demo", user: "Tejas", caneID: "opencane-01",
        batteryPct: 42,
        obstacle: OpenCaneObstacle(kind: "pole", distanceM: 0.9, direction: "center"))
    let json = try wire(event)

    #expect(json["type"] as? String == "fall")
    #expect(json["severity"] as? String == "critical")
    #expect(json["timestamp"] as? String == "2026-09-12T20:30:00Z")
    #expect(json["lat"] as? Double == 40.1106)
    #expect(json["lng"] as? Double == -88.2284)
    #expect(json["accuracy_m"] as? Double == 5)
    #expect(json["speed_mps"] as? Double == 1.3)
    #expect(json["cane_id"] as? String == "opencane-01")
    #expect(json["battery_pct"] as? Int == 42)
    #expect(json["user"] as? String == "Tejas")

    let obstacle = try #require(json["obstacle"] as? [String: Any])
    #expect(obstacle["kind"] as? String == "pole")
    #expect(obstacle["distance_m"] as? Double == 0.9)     // ⚠ not "distanceM"
    #expect(obstacle["direction"] as? String == "center")
}

/// A nil field is absent, never JSON null: the bot reads "absent" as unknown, and an absent
/// `severity` specifically means "infer it".
@Test func nilFieldsAreOmittedNotNull() throws {
    let json = try wire(OpenCaneEvent(type: .location, lat: 1, lng: 2))
    #expect(json.keys.sorted() == ["lat", "lng", "type"])
    #expect(json["severity"] == nil)

    let bare = try #require(String(data: OpenCaneEvent(type: .status).jsonBody(), encoding: .utf8))
    #expect(bare == #"{"type":"status"}"#)      // no nulls, no empty strings
}

/// The timestamp is ISO-8601 UTC at second resolution, exactly like the curl sample in the README.
@Test func timestampIsISO8601UTC() {
    let date = Date(timeIntervalSince1970: 1_789_245_000)      // 2026-09-12T20:30:00Z
    #expect(OpenCaneEvent.iso8601(date) == "2026-09-12T20:30:00Z")
}

/// `stamped(at:)` fills a missing timestamp and never overwrites one the caller already knew.
@Test func stampingOnlyFillsAMissingTimestamp() {
    let date = Date(timeIntervalSince1970: 1_789_245_000)
    #expect(OpenCaneEvent(type: .sos).stamped(at: date).timestamp == "2026-09-12T20:30:00Z")

    let known = OpenCaneEvent(type: .sos, timestamp: "2020-01-01T00:00:00Z")
    #expect(known.stamped(at: date).timestamp == "2020-01-01T00:00:00Z")
}

/// `type` is open: a string the app has never heard of decodes rather than throwing, so a new
/// detector cannot break an old build's round-trip.
@Test func unknownEventTypeRoundTrips() throws {
    let data = try #require(#"{"type":"geofence_exit","severity":"warn"}"#.data(using: .utf8))
    let event = try JSONDecoder().decode(OpenCaneEvent.self, from: data)
    #expect(event.type == OpenCaneEventType(rawValue: "geofence_exit"))
    #expect(event.severity == .warn)
    #expect(try wire(event)["type"] as? String == "geofence_exit")   // and re-encodes unchanged
}

/// The `extra` bag carries arbitrary JSON, including nesting, and survives a round-trip.
@Test func extraCarriesArbitraryJSON() throws {
    let event = OpenCaneEvent(type: .status, extra: ["route": "ISR to CIF", "leg": 3, "indoors": false])
    let json = try wire(event)
    let extra = try #require(json["extra"] as? [String: Any])
    #expect(extra["route"] as? String == "ISR to CIF")
    #expect(extra["leg"] as? Double == 3)
    #expect(extra["indoors"] as? Bool == false)

    let decoded = try JSONDecoder().decode(OpenCaneEvent.self, from: event.jsonBody())
    #expect(decoded == event)
}

/// The nested `location` form decodes (the contract allows it) even though OpenCane sends the
/// flat pair.
@Test func nestedLocationFormDecodes() throws {
    let data = try #require(#"{"type":"location","location":{"lat":40.1,"lng":-88.2}}"#.data(using: .utf8))
    let event = try JSONDecoder().decode(OpenCaneEvent.self, from: data)
    #expect(event.location == OpenCaneGeo(lat: 40.1, lng: -88.2))
    #expect(event.lat == nil)
}
