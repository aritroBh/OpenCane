//
//  TripLogRecordTests.swift
//  CaneKitLogicTests
//
//  Pins TripLogRecord (the object behind every trip-log line). The bug from the phone log
//  (2026-09-11): AppModel passed a field named "kind" with cue and hazard events, TripLogger let
//  it replace the record's own kind, so `{"kind":"hazard"}` came out as `{"kind":"sign"}` and
//  e2e.py never saw a hazard record.
//
//  Source pinned: `ios/Logic/Sources/CaneKitLogic/TripLogRecord.swift` (`make(t:kind:fields:)`,
//  `reservedKeys`). Caller: `TripLogger.event` (app), for every JSONL trip-log line. Readers that
//  depend on `t` / `kind` being the record's own: `ios/scripts/e2e.py`, `ios/scripts/cue_audit.py`,
//  and whoever reads a walk's log. A caller field named `t` or `kind` survives as `field_t` /
//  `field_kind`, never silently overwriting.
//

import Testing
@testable import CaneKitLogic

/// A field can never replace the record's `t` or `kind`; its value is kept under `field_<name>`.
@Test func fieldsNeverOverwriteTheRecordTimeOrKind() {
    let r = TripLogRecord.make(t: 12.5, kind: "hazard", fields: ["kind": "sign", "t": 99.0, "text": "Sign: detour."])
    #expect(r["kind"] as? String == "hazard")
    #expect(r["t"] as? Double == 12.5)
    #expect(r["field_kind"] as? String == "sign")
    #expect(r["field_t"] as? Double == 99.0)
    #expect(r["text"] as? String == "Sign: detour.")
    #expect(r.count == 5)
}

/// Ordinary fields pass through untouched; no fields gives just `t` and `kind`.
@Test func ordinaryFieldsPassThrough() {
    let r = TripLogRecord.make(t: 1, kind: "cue", fields: ["cue": "left", "ar_t": 3.25])
    #expect(r["kind"] as? String == "cue" && r["cue"] as? String == "left" && r["ar_t"] as? Double == 3.25)
    #expect(TripLogRecord.make(t: 0, kind: "arrived", fields: [:]).count == 2)
    #expect(TripLogRecord.reservedKeys == ["t", "kind"])
}
