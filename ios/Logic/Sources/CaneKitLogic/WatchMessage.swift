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
//    · Version skew: the watch sends commands with a reply handler and the phone answers
//      `["ok": decodeWatchToPhone(message) != nil]`; `ok == false` makes the watch say "Update the
//      phone app" with a `.retry` haptic (never `.failure`, which is reserved for head height).
//
//  Callers: `PhoneWatchLink` (phone: `encode` in `send(nav:)` / `send(obstacle:now:)` /
//  `send(status:distanceM:)`, `decodeWatchToPhone` in its session relay) and `WatchModel` (watch:
//  `encode(WatchToPhone)` in `send(_:)`, `decodePhoneToWatch` for messages and the application
//  context). Isolation: nonisolated value types; the dictionaries are built and read on one actor.
//  Tests: WatchMessageTests.swift (`phoneToWatchRoundTrips`, `watchToPhoneRoundTrips`,
//  `unknownPayloadsDecodeToNil`).
//

import Foundation

/// Navigation events that get a distinct wrist haptic on the watch.
///
/// Cases (raw value = case name, part of the wire format):
///   · `turnLeft` / `turnRight` — a turn waypoint (`NavigationEngine.onNavCue`); watch
///     `.directionUp` / `.directionDown`; the phone plays one / two long buzzes (`HapticPlayer.playNav`).
///   · `crossing` — a street-crossing waypoint; watch `.notification`, phone three long buzzes.
///   · `arrived` — the arrival fence; watch `.success`, phone long-short-long.
///   · `obstacle` — a generic obstacle tap; watch `.failure`. No phone path sends it today (obstacles
///     are mirrored as `PhoneToWatch.obstacle(CueKind)`); kept because removing a case breaks the
///     wire contract with an installed watch app.
/// Also sent raw by the Watch card's test buttons (`AppModel.watchTest`).
public enum NavCue: String, Sendable, Codable, CaseIterable {
    case turnLeft, turnRight, crossing, arrived, obstacle
}

/// Messages the phone sends to the watch. Pinned by `phoneToWatchRoundTrips`.
public enum PhoneToWatch: Sendable, Codable, Equatable {
    /// Turn / crossing / arrival cue for the wrist.
    case nav(NavCue)
    /// Mirrored obstacle cue: sent by `AppModel` when the phone cannot buzz (haptic engine unhealthy
    /// or the walker silenced it) or `AppModel.fallbackToWatch` is on, for lane cues and (as
    /// `.center`) ground hazards; `PhoneWatchLink` throttles it to one per kind per second. `.clear`
    /// plays nothing on the watch.
    case obstacle(CueKind)
    /// Current instruction + distance for the watch face. `distanceM` in whole metres, −1 = unknown.
    /// Sent as application context (survives the watch app being closed); `PhoneWatchLink` drops a
    /// status with the same text and a distance change under 5 m.
    case status(instruction: String, distanceM: Int)
}

/// Commands the watch sends to the phone (one per watch button / crown gesture).
/// Pinned by `watchToPhoneRoundTrips`.
public enum WatchToPhone: String, Sendable, Codable, CaseIterable {
    /// Handled by `AppModel.handleWatchCommand` (logged `watch {command}`):
    ///   · `nextWaypoint` — Next button or the crown gesture (`CrownAccumulator`) → `nextWaypoint()`.
    ///   · `describe` — Describe → `describeScene()` ("Where am I").
    ///   · `recenter` — Recenter → `recenter()` (re-zeroes AirPods and face head yaw).
    ///   · `repeatLast` — Repeat → `repeatInstruction()`: the last line actually spoken plus
    ///     "Next, <place>, in N meters." (a cut-off crossing line is otherwise lost).
    case nextWaypoint, describe, recenter, repeatLast
}

/// Wraps / unwraps messages in the `[String: Any]` dictionaries WatchConnectivity carries:
/// `["m": <JSON Data>]`.
public enum WatchEnvelope {
    /// Dictionary key under which the JSON payload travels. ⚠ Wire format: both installed apps
    /// must agree on it.
    public static let key = "m"

    /// Phone → watch.
    /// - Parameter m: the message.
    /// - Returns: `["m": JSON Data]` for `sendMessage` / application context.
    /// - Throws: only if `JSONEncoder` fails (never in practice).
    public static func encode(_ m: PhoneToWatch) throws -> [String: Any] {
        [key: try JSONEncoder().encode(m)]
    }

    /// Watch → phone.
    /// - Parameter m: the command.
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
