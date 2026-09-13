//
//  CloudSchemaTests.swift
//  CaneKitLogicTests
//
//  Pins the Supabase wire contract and the batching numbers.
//
//  The one that matters most is `tripEventRowsAlwaysCarryEveryKey`. PostgREST refuses a bulk
//  insert whose objects disagree on their key set — it answers 400 PGRST102 "All object keys must
//  match" and writes nothing. Measured against the live project on 2026-09-13: a batch of three
//  rows where only one carried `lat` was rejected in full; the same three rows with explicit
//  nulls inserted. So a whole walk's log can be lost to Codable's perfectly reasonable habit of
//  omitting nil optionals, and a test has to stand in the way of anyone "tidying" that up.
//
//  The column names are asserted as bytes for the same reason as GrokBotEventTests: a rename
//  fails at run time with an HTTP error nobody is watching during a demo.
//

import Foundation
import Testing
@testable import CaneKitLogic

/// The encoded object for any row, so a test can assert on the wire keys.
private func wire<T: Encodable>(_ row: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(row)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// The encoded array for a batch.
private func wireArray<T: Encodable>(_ rows: [T]) throws -> [[String: Any]] {
    let data = try JSONEncoder().encode(rows)
    return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
}

// MARK: - The uniform-key rule

/// ⚠ Every trip-event row carries every column, nil or not. See the file header: a missing key
/// costs the whole batch. A row with nothing optional set must still have all 8 keys.
@Test func tripEventRowsAlwaysCarryEveryKey() throws {
    let sparse = TripEventRow(walkerID: "w", tripID: nil, tSeconds: 1, kind: "session")
    let full = TripEventRow(walkerID: "w", tripID: "t", tSeconds: 2, kind: "gps",
                            payload: ["acc": .number(6.1)], lat: 40.1, lon: -88.2,
                            textSpoken: "Head north.")

    let expected: Set<String> = ["walker_id", "trip_id", "t_seconds", "kind", "payload",
                                 "lat", "lon", "text_spoken"]
    #expect(Set(try wire(sparse).keys) == expected)
    #expect(Set(try wire(full).keys) == expected)

    // And the batch PostgREST actually receives: every object, same keys.
    let batch = try wireArray([sparse, full])
    #expect(batch.count == 2)
    #expect(Set(batch[0].keys) == Set(batch[1].keys))
    // The nils are present as JSON null, not absent.
    #expect(batch[0]["trip_id"] is NSNull)
    #expect(batch[0]["lat"] is NSNull)
    #expect(batch[0]["text_spoken"] is NSNull)
}

/// Waypoints are bulk-inserted too, so the same rule holds: the last waypoint of a route has no
/// `bearing_next_deg` and must still carry the key.
@Test func waypointRowsAlwaysCarryEveryKey() throws {
    let middle = Waypoint(id: 1, lat: 40.1, lon: -88.2, radiusM: 15, say: "Head north.",
                          crossing: false, bearingNextDeg: 12, curved: false, name: "Goodwin Avenue")
    let last = Waypoint(id: 2, lat: 40.2, lon: -88.3, radiusM: 20, say: "CIF east entrance.",
                        crossing: false, bearingNextDeg: nil)

    let batch = try wireArray([RouteWaypointRow(routeID: "r", waypoint: middle),
                               RouteWaypointRow(routeID: "r", waypoint: last)])
    #expect(Set(batch[0].keys) == Set(batch[1].keys))
    #expect(batch[1]["bearing_next_deg"] is NSNull)
    #expect(batch[1]["place_name"] is NSNull)
}

/// A non-finite number would make the JSON invalid and lose the batch; `t` and the position are
/// sanitised the same way `TripLogger.num` sanitises the on-disk line.
@Test func nonFiniteNumbersNeverReachTheWire() throws {
    let row = TripEventRow(walkerID: "w", tripID: nil, tSeconds: .nan, kind: "lanes",
                           lat: .infinity, lon: -88.2)
    let json = try wire(row)
    #expect(json["t_seconds"] as? Double == 0)
    #expect(json["lat"] is NSNull)
    #expect(json["lon"] as? Double == -88.2)
}

// MARK: - Column names

/// The trip-event column names are the contract with migration `opencane_03`.
@Test func tripEventColumnsAreSnakeCase() throws {
    let json = try wire(TripEventRow(walkerID: "w", tripID: "t", tSeconds: 1.5, kind: "speech",
                                     payload: ["band": .string("nav")],
                                     textSpoken: "Head north on Goodwin Avenue."))
    #expect(json["walker_id"] as? String == "w")
    #expect(json["trip_id"] as? String == "t")
    #expect(json["t_seconds"] as? Double == 1.5)
    #expect(json["kind"] as? String == "speech")
    #expect(json["text_spoken"] as? String == "Head north on Goodwin Avenue.")
    #expect((json["payload"] as? [String: Any])?["band"] as? String == "nav")
}

/// A `gps` line's position and a `speech` line's text are lifted into their own columns, and the
/// payload still holds the whole line.
@Test func liftedColumnsComeOutOfTheLoggedFields() {
    let gps = TripEventRow.from(walkerID: "w", tripID: "t", tSeconds: 3, kind: "gps",
                                fields: ["lat": .number(40.11), "lon": .number(-88.22),
                                         "acc": .number(6)])
    #expect(gps.lat == 40.11)
    #expect(gps.lon == -88.22)
    #expect(gps.textSpoken == nil)
    #expect(gps.payload["acc"] == .number(6))
    #expect(gps.payload["lat"] == .number(40.11))   // kept in the payload as well

    let speech = TripEventRow.from(walkerID: "w", tripID: "t", tSeconds: 4, kind: "speech",
                                   fields: ["text": .string("Curb ahead."), "band": .string("warn")])
    #expect(speech.textSpoken == "Curb ahead.")
    #expect(speech.lat == nil)

    // `text` on a non-speech line is not a spoken line and must not be lifted.
    let hazard = TripEventRow.from(walkerID: "w", tripID: "t", tSeconds: 5, kind: "hazard",
                                   fields: ["text": .string("Sign: sidewalk closed.")])
    #expect(hazard.textSpoken == nil)
}

/// The hazard row is the `HazardRecord` the phone already writes, renamed for Postgres.
@Test func hazardRowMirrorsTheLocalRecord() throws {
    let record = HazardRecord(kind: "pothole", text: "Two meters ahead, pothole.",
                              latitude: 40.1133, longitude: -88.2243, accuracy: 5,
                              time: 1_789_000_000, photo: "hazard-1.jpg",
                              distanceM: 2, heightM: -0.12, direction: "center",
                              headingDeg: 12, speedMps: 1.3, routeName: "CIF east entrance",
                              instruction: "Continue north", source: "ground",
                              whatItSaw: "depth discontinuity 12 cm", severity: "warn")
    let json = try wire(HazardRow(record: record, walkerID: "w", tripID: "t",
                                  photoPath: "w/hazard-1.jpg"))

    #expect(json["spoken_text"] as? String == "Two meters ahead, pothole.")
    #expect(json["what_it_saw"] as? String == "depth discontinuity 12 cm")
    #expect(json["accuracy_m"] as? Double == 5)
    #expect(json["height_m"] as? Double == -0.12)
    #expect(json["heading_deg"] as? Double == 12)
    #expect(json["speed_mps"] as? Double == 1.3)
    #expect(json["route_name"] as? String == "CIF east entrance")
    #expect(json["photo_path"] as? String == "w/hazard-1.jpg")
    // ISO-8601 UTC, the format timestamptz takes.
    #expect((json["detected_at"] as? String)?.hasSuffix("Z") == true)
}

/// The phone's marker UUID is the row's primary key, so replaying a post after an outage updates
/// rather than duplicating it.
@Test func postRowKeepsThePhonesMarkerID() throws {
    let id = UUID(uuidString: "1E2D3C4B-5A69-4788-9A0B-1C2D3E4F5061")!
    let marker = WalkMarker(id: id, name: "Townsend Door",
                            coordinate: Coordinate(latitude: 40.1129, longitude: -88.2245),
                            timestamp: 1_789_000_000)
    let json = try wire(PostRow(marker: marker, walkerID: "w", tripID: "t"))
    #expect(json["id"] as? String == "1e2d3c4b-5a69-4788-9a0b-1c2d3e4f5061")
    #expect(json["name"] as? String == "Townsend Door")
    #expect(json["lat"] as? Double == 40.1129)
}

// MARK: - Family alerts

/// ⚠ A `family_contacts` registration is not an alert, and the family's addresses must never be
/// copied into the alert feed. The row builder refuses it.
@Test func familyContactRegistrationIsNeverAnAlertRow() {
    let registration = FamilyContacts.registration(emails: ["mom@example.com"], sendTest: true)
    #expect(FamilyAlertRow(event: registration, walkerID: "w", tripID: nil, now: Date()) == nil)
}

/// The model-written sentence gets its own column and is removed from `extra`, so it is stored
/// once and a demo can select it without digging through JSON.
@Test func aiContextIsPromotedOutOfExtra() throws {
    var event = OpenCaneEvent(type: .fall, severity: .critical,
                              timestamp: "2026-09-13T01:05:00Z", lat: 40.1134, lng: -88.2242,
                              note: "Cane went over.", caneID: "opencane-01", batteryPct: 12)
    event.extra = ["ai_context": .string("Stopped 40 m from CIF with 12% battery."),
                   "cue_level": .string("standard")]

    let row = try #require(FamilyAlertRow(event: event, walkerID: "w", tripID: "t", now: Date(),
                                          deliveryStatus: "posted", webhookStatusCode: 200))
    #expect(row.aiContext == "Stopped 40 m from CIF with 12% battery.")
    #expect(row.extra["ai_context"] == nil)
    #expect(row.extra["cue_level"] == .string("standard"))

    let json = try wire(row)
    #expect(json["event_type"] as? String == "fall")
    #expect(json["occurred_at"] as? String == "2026-09-13T01:05:00Z")   // the event's own time wins
    #expect(json["delivery_status"] as? String == "posted")
    #expect(json["webhook_status_code"] as? Int == 200)
    #expect(json["battery_pct"] as? Int == 12)
    #expect(json["posted_at"] != nil)
}

/// A pending alert has not been posted, so it carries no `posted_at`.
@Test func pendingAlertsHaveNoPostedTime() throws {
    let event = OpenCaneEvent(type: .sos, severity: .critical)
    let row = try #require(FamilyAlertRow(event: event, walkerID: "w", tripID: nil,
                                          now: Date(timeIntervalSince1970: 1_789_000_000)))
    #expect(row.deliveryStatus == "pending")
    #expect(row.postedAt == nil)
    // No timestamp on the event: the row is stamped with the send time instead of being null.
    #expect(row.occurredAt.hasSuffix("Z"))
}

/// The nested `{lat, lng}` form is accepted as well as the flat pair — the bot contract allows
/// either and a replayed event must not lose its position.
@Test func nestedLocationIsAcceptedAsAPosition() throws {
    var event = OpenCaneEvent(type: .location, severity: .info)
    event.location = OpenCaneGeo(lat: 40.1, lng: -88.2)
    let row = try #require(FamilyAlertRow(event: event, walkerID: "w", tripID: nil, now: Date()))
    #expect(row.lat == 40.1)
    #expect(row.lng == -88.2)
}

// MARK: - Settings, mobility

/// Every settings column is the `UserDefaults` key, snake_cased. The list is the contract with
/// migration `opencane_02`.
@Test func settingsColumnsCoverEveryPersistedKey() throws {
    let row = DeviceSettingsRow(
        portraitMode: true, mirrorLeftRight: false, cueLevel: "detailed", cuePlace: "outdoors",
        obstacleNamesEnabled: false, hapticsSilenced: false, beaconEnabled: true,
        fallbackToWatch: false, groundHazardsEnabled: false, signsEnabled: true,
        hazardWatchEnabled: false, namePeopleEnabled: true, highFrameRateCamera: false,
        familyAlertsEnabled: false, familyAlertsAIContext: true, fallDetectionEnabled: true,
        familyContactsRegistered: false, loggingEnabled: true)
    let json = try wire(row)

    let expected: Set<String> = [
        "portrait_mode", "mirror_left_right", "cue_level", "cue_place", "obstacle_names_enabled",
        "haptics_silenced", "beacon_enabled", "fallback_to_watch", "ground_hazards_enabled",
        "signs_enabled", "hazard_watch_enabled", "name_people_enabled", "high_frame_rate_camera",
        "family_alerts_enabled", "family_alerts_ai_context", "fall_detection_enabled",
        "family_contacts_registered", "logging_enabled", "extra_settings",
    ]
    #expect(Set(json.keys) == expected)
}

/// A day key is the walker's local day, not UTC's: a walk that ends at 7 pm in Urbana belongs to
/// that day even though UTC has already rolled over.
@Test func mobilityDayKeyUsesTheWalkersOwnDay() {
    let urbana = TimeZone(identifier: "America/Chicago")!
    let utc = TimeZone(identifier: "UTC")!

    // A walk that ends at 20:30 in Urbana is that day's walk, even though UTC has rolled over.
    let evening = Date(timeIntervalSince1970: 1_789_263_000)       // 2026-09-13T01:30:00Z
    #expect(MobilityDayRow.dayKey(evening, zone: urbana) == "2026-09-12")
    #expect(MobilityDayRow.dayKey(evening, zone: utc) == "2026-09-13")

    // Same instant, two zones, two days — the point of taking the zone at all.
    let newYear = Date(timeIntervalSince1970: 1_767_227_400)       // 2026-01-01T00:30:00Z
    #expect(MobilityDayRow.dayKey(newYear, zone: utc) == "2026-01-01")
    #expect(MobilityDayRow.dayKey(newYear, zone: urbana) == "2025-12-31")

    #expect(MobilityDayRow.dayKey(Date(timeIntervalSince1970: 0), zone: utc) == "1970-01-01")
}

// MARK: - Batching policy

/// A batch is at most `maxBatchSize` rows, taken oldest first so a walk replays in order.
@Test func batchesTakeTheOldestRowsFirst() {
    let policy = CloudBatchPolicy()
    let queued = (0..<450).map {
        TripEventRow(walkerID: "w", tripID: "t", tSeconds: Double($0), kind: "lanes")
    }
    let (send, keep) = policy.split(queued)
    #expect(send.count == policy.maxBatchSize)
    #expect(keep.count == 450 - policy.maxBatchSize)
    #expect(send.first?.tSeconds == 0)
    #expect(send.last?.tSeconds == Double(policy.maxBatchSize - 1))
    #expect(keep.first?.tSeconds == Double(policy.maxBatchSize))

    // A short queue goes in one batch with nothing held back.
    let (all, none) = policy.split(Array(queued.prefix(10)))
    #expect(all.count == 10)
    #expect(none.isEmpty)
}

/// ⚠ Over the ceiling the OLDEST rows are dropped. In an outage the recent minute is what a
/// family or a debugger needs, and the count is returned so the drop can be logged rather than
/// leaving a silent hole in the cloud copy of a walk.
@Test func theQueueCeilingDropsTheOldestRows() {
    var policy = CloudBatchPolicy()
    policy.maxQueuedRows = 100
    let queued = (0..<130).map {
        TripEventRow(walkerID: "w", tripID: "t", tSeconds: Double($0), kind: "lanes")
    }
    let (kept, dropped) = policy.trim(queued)
    #expect(dropped == 30)
    #expect(kept.count == 100)
    #expect(kept.first?.tSeconds == 30)          // the newest 100 survived
    #expect(kept.last?.tSeconds == 129)

    let (untouched, none) = policy.trim(Array(queued.prefix(100)))
    #expect(none == 0)
    #expect(untouched.count == 100)
}

/// Backoff doubles from 2 s and stops at 30 s, so a long outage still retries twice a minute.
@Test func backoffDoublesAndThenStops() {
    let policy = CloudBatchPolicy()
    #expect(policy.backoff(attempt: 1) == 0)     // the first try is immediate
    #expect(policy.backoff(attempt: 2) == 2)
    #expect(policy.backoff(attempt: 3) == 4)
    #expect(policy.backoff(attempt: 4) == 8)
    #expect(policy.backoff(attempt: 5) == 16)
    #expect(policy.backoff(attempt: 6) == 30)    // capped
    #expect(policy.backoff(attempt: 99) == 30)
    // A nonsense counter must not trap mid-walk.
    #expect(policy.backoff(attempt: 0) == 0)
    #expect(policy.backoff(attempt: -3) == 0)
}

/// The photo cap matches the on-phone cap, so the two copies of a walk hold the same photo set.
@Test func thePhotoCapMatchesTheLocalHazardLog() {
    #expect(CloudBatchPolicy().maxPhotoUploads == 200)
}

/// ⚠ The trip mark is an index into the live queue, so a flush must shift it. Found by audit on
/// 2026-09-13: `tick()` removed rows from the front without moving the mark, so when the trip id
/// landed the stamping loop started at the wrong offset and the walk's first lines kept a null
/// `trip_id` — the walk looked shorter than it was, silently.
@Test func theTripMarkFollowsTheQueueAcrossAFlush() {
    let policy = CloudBatchPolicy()
    // 50 lines logged before Start, then the walk's lines.
    #expect(policy.shiftMark(50, flushed: 0) == 50)
    // A flush takes 20 rows off the front: the walk now begins 20 slots earlier.
    #expect(policy.shiftMark(50, flushed: 20) == 30)
    // A flush that swallows the pre-trip rows entirely: everything left is the walk's.
    #expect(policy.shiftMark(50, flushed: 50) == 0)
    #expect(policy.shiftMark(50, flushed: 200) == 0)   // clamped, never negative
    #expect(policy.shiftMark(0, flushed: 10) == 0)
}
