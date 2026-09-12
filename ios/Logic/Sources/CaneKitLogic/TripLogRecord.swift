//
//  TripLogRecord.swift
//  CaneKitLogic
//
//  The JSON object behind every line of the trip log: `t`, `kind`, then the event's fields.
//  Moved out of the app's `TripLogger.event` so the rule "a field can never replace the record's
//  own `t` or `kind`" is testable. The phone log of 2026-09-11 showed why: AppModel logged cue and
//  hazard events with a field named "kind", which replaced the record kind ("hazard" → "sign"),
//  so tooling looking for `kind == "hazard"` found nothing.
//
//  Owner: called by `TripLogger.event(_:_:)` (app, main actor) for every record.
//
//  Key invariants:
//    · `t` and `kind` always come from the caller's arguments; a colliding field is kept as
//      `field_<name>` rather than dropped (the value may still matter when reading a log).
//    · Pure: no clock, no I/O, no JSON encoding (TripLogger validates and encodes).
//  Tests: TripLogRecordTests.swift.
//

import Foundation

/// Builds one trip-log record. Pinned by `fieldsNeverOverwriteTheRecordTimeOrKind`,
/// `ordinaryFieldsPassThrough`.
public enum TripLogRecord {
    /// Keys owned by the record itself: seconds since the logger started, and the record type.
    public static let reservedKeys: Set<String> = ["t", "kind"]

    /// `["t": t, "kind": kind]` plus every field; a field named `t` or `kind` is stored as
    /// `field_t` / `field_kind` instead of replacing the record's own value.
    /// Called by `TripLogger.event(_:_:)`.
    public static func make(t: Double, kind: String, fields: [String: Any]) -> [String: Any] {
        var record: [String: Any] = ["t": t, "kind": kind]
        for (key, value) in fields {
            record[reservedKeys.contains(key) ? "field_\(key)" : key] = value
        }
        return record
    }
}
