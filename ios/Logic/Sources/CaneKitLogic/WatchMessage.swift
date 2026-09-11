//
//  WatchMessage.swift
//  CaneKitLogic
//
//  The phone ↔ watch contract over WatchConnectivity. JSON-encoded under the message key "m".
//
//  Purpose: the only types that cross between the phone app (`PhoneWatchLink`) and the watch
//  app (`WatchModel`): wrist-tap nav cues, mirrored obstacle cues, the instruction / distance
//  shown on the watch face, and the watch's four buttons (Next / Describe / Recenter / Repeat).
//
//  Key invariants:
//    · Case names and raw values ARE the wire format between two separately installed
//      binaries. Adding cases is safe (the old side decodes nil); renaming or removing is not.
//    · Decoding never throws: missing key, non-`Data` value or an unknown case → nil.
//    · `status.distanceM` is whole metres; −1 means unknown.
//  Tests: WatchMessageTests.swift (`phoneToWatchRoundTrips`, `watchToPhoneRoundTrips`,
//  `unknownPayloadsDecodeToNil`).
//

import Foundation

/// Navigation events that get a distinct wrist haptic on the watch.
public enum NavCue: String, Sendable, Codable, CaseIterable {
    case turnLeft, turnRight, crossing, arrived, obstacle
}

/// Messages the phone sends to the watch. Pinned by `phoneToWatchRoundTrips`.
public enum PhoneToWatch: Sendable, Codable, Equatable {
    /// Turn / crossing / arrival cue for the wrist.
    case nav(NavCue)
    /// Mirrored obstacle cue (fallback when the phone haptic engine is unhealthy).
    case obstacle(CueKind)
    /// Current instruction + distance for the watch face. `distanceM` in whole metres, −1 = unknown.
    case status(instruction: String, distanceM: Int)
}

/// Commands the watch sends to the phone (one per watch button / crown gesture).
/// Pinned by `watchToPhoneRoundTrips`.
public enum WatchToPhone: String, Sendable, Codable, CaseIterable {
    /// `repeatLast` re-speaks the current instruction (a cut-off crossing line is otherwise lost).
    case nextWaypoint, describe, recenter, repeatLast
}

/// Wraps / unwraps messages in the `[String: Any]` dictionaries WatchConnectivity carries:
/// `["m": <JSON Data>]`.
public enum WatchEnvelope {
    /// Dictionary key under which the JSON payload travels.
    public static let key = "m"

    /// - Returns: `["m": JSON Data]` for `sendMessage` / application context.
    /// - Throws: only if `JSONEncoder` fails (never in practice).
    public static func encode(_ m: PhoneToWatch) throws -> [String: Any] {
        [key: try JSONEncoder().encode(m)]
    }

    /// - Returns: `["m": JSON Data]` for `sendMessage`.
    /// - Throws: only if `JSONEncoder` fails (never in practice).
    public static func encode(_ m: WatchToPhone) throws -> [String: Any] {
        [key: try JSONEncoder().encode(m)]
    }

    /// nil when the payload is missing or from a newer app version we don't understand.
    /// Pinned by `unknownPayloadsDecodeToNil`.
    public static func decodePhoneToWatch(_ dict: [String: Any]) -> PhoneToWatch? {
        guard let data = dict[key] as? Data else { return nil }
        return try? JSONDecoder().decode(PhoneToWatch.self, from: data)
    }

    /// nil when the payload is missing or from a newer watch app we don't understand (the phone
    /// then replies `ok: false`, and the watch says "Update the phone app").
    /// Pinned by `unknownPayloadsDecodeToNil`.
    public static func decodeWatchToPhone(_ dict: [String: Any]) -> WatchToPhone? {
        guard let data = dict[key] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchToPhone.self, from: data)
    }
}
