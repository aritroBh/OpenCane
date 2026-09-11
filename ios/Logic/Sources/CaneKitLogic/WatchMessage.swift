//
//  WatchMessage.swift
//  CaneKitLogic
//
//  The phone ↔ watch contract over WatchConnectivity. JSON-encoded under the message key "m".
//

import Foundation

public enum NavCue: String, Sendable, Codable, CaseIterable {
    case turnLeft, turnRight, crossing, arrived, obstacle
}

public enum PhoneToWatch: Sendable, Codable, Equatable {
    /// Turn / crossing / arrival cue for the wrist.
    case nav(NavCue)
    /// Mirrored obstacle cue (fallback when the phone haptic engine is unhealthy).
    case obstacle(CueKind)
    /// Current instruction + distance for the watch face.
    case status(instruction: String, distanceM: Int)
}

public enum WatchToPhone: String, Sendable, Codable, CaseIterable {
    /// `repeatLast` re-speaks the current instruction (a cut-off crossing line is otherwise lost).
    case nextWaypoint, describe, recenter, repeatLast
}

public enum WatchEnvelope {
    public static let key = "m"

    public static func encode(_ m: PhoneToWatch) throws -> [String: Any] {
        [key: try JSONEncoder().encode(m)]
    }

    public static func encode(_ m: WatchToPhone) throws -> [String: Any] {
        [key: try JSONEncoder().encode(m)]
    }

    /// nil when the payload is missing or from a newer app version we don't understand.
    public static func decodePhoneToWatch(_ dict: [String: Any]) -> PhoneToWatch? {
        guard let data = dict[key] as? Data else { return nil }
        return try? JSONDecoder().decode(PhoneToWatch.self, from: data)
    }

    public static func decodeWatchToPhone(_ dict: [String: Any]) -> WatchToPhone? {
        guard let data = dict[key] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchToPhone.self, from: data)
    }
}
