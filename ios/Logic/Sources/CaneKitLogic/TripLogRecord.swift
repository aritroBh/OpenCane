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
//  Owner: called by `TripLogger.event(_:_:)` (app, main actor) for every record; `t` there is
//  seconds since the logger started (`Date().timeIntervalSince(t0)`), one JSONL line per record in
//  Documents/canekit-*.jsonl.
//
//  Key invariants:
//    · `t` and `kind` always come from the caller's arguments; a colliding field is kept as
//      `field_<name>` rather than dropped (the value may still matter when reading a log).
//    · Pure: no clock, no I/O, no JSON encoding (TripLogger validates and encodes).
//    · A `field_kind` / `field_t` key in a real log is an app bug (a caller used a reserved name):
//      `ios/scripts/e2e.py` fails the run on it and `ios/scripts/cue_audit.py` reports it as
//      `field_collisions`. That is why cue events name their field `cue` and hazards `type`.
//    · Isolation: nonisolated and stateless; `[String: Any]` is not `Sendable`, so callers build
//      and consume the dictionary on one actor (the logger's main actor).
//  Tests: TripLogRecordTests.swift (2).
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
    /// - Parameters:
    ///   - t: seconds since the logger started (the record's own time).
    ///   - kind: the record type ("gps", "speech", "cue", "hazard", …).
    ///   - fields: the event's fields; values must be JSON-encodable (TripLogger checks).
    /// - Returns: a new dictionary; `fields` is not modified.
    public static func make(t: Double, kind: String, fields: [String: Any]) -> [String: Any] {
        var record: [String: Any] = ["t": t, "kind": kind]
        for (key, value) in fields {
            record[reservedKeys.contains(key) ? "field_\(key)" : key] = value
        }
        return record
    }
}
