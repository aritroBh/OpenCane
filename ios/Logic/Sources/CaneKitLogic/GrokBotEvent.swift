//
//  GrokBotEvent.swift
//  CaneKitLogic
//
//  The JSON event object OpenCane POSTs to the Grok Bot routine "OpenCane cane events"
//  (folder opencane-cane-events) so a family member can be alerted. This file is the **contract**:
//  the bot parses these exact key names, so they are pinned by tests rather than left to
//  Codable's synthesis defaults.
//
//  Owner: `GrokBotClient` (app, transport) encodes `OpenCaneEvent` and POSTs it; `FamilyAlerts`
//  (app) builds the events from cane detections. Nothing here performs I/O.
//
//  Key invariants:
//    · Key names are the contract. `accuracy_m`, `speed_mps`, `cane_id`, `battery_pct` are
//      snake_case; `lng` is never `lon`/`longitude`. Changing one silently stops the bot parsing.
//    · A nil field is **omitted**, never sent as JSON null: the bot treats "absent" as "unknown"
//      and `severity` absent specifically means "you infer it".
//    · `type` is open (the TS contract is `... | (string & {})`), so an unknown string round-trips
//      rather than failing to decode.
//    · Pure: no clock and no network. `stamped(at:)` takes the date, so tests are deterministic.
//  Tests: GrokBotEventTests.swift.
//

import Foundation

/// How urgent an event is. The bot texts family for `warn` and `critical`; `info` stays
/// chat-only. Omitting it entirely asks the bot to infer (fall / sos ⇒ critical).
public enum OpenCaneSeverity: String, Codable, Sendable, Equatable {
    case info, warn, critical
}

/// The kind of event. Open on purpose — the contract is `"location" | ... | (string & {})`, so a
/// new detector can send a new type without a bot-side deploy. The known cases are constants
/// rather than enum cases so that decoding an unknown string cannot throw.
public struct OpenCaneEventType: RawRepresentable, Codable, Sendable, Equatable, Hashable,
                                 ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    /// Periodic GPS breadcrumb. Quiet: `info`, chat-only on the bot side.
    public static let location: Self = "location"
    /// Suspected fall. Always `critical`.
    public static let fall: Self = "fall"
    /// Obstacle the cane cannot find (waist-to-head, drop-off, hazard).
    public static let obstacle: Self = "obstacle"
    /// Phone battery low enough that guidance is at risk.
    public static let lowBattery: Self = "low_battery"
    /// Walker asked for help explicitly. Always `critical`.
    public static let sos: Self = "sos"
    /// Heartbeat / state change (route started, arrived). Quiet.
    public static let status: Self = "status"
    /// The vision model described a weapon or an attacker ahead. Critical; see `ThreatWatch`.
    public static let threat: Self = "threat"
    /// A walk began. Family are told so an unexpected trip is visible.
    public static let tripStart: Self = "trip_start"
    /// A walk ended, by arrival or by the walker stopping it.
    public static let tripEnd: Self = "trip_end"
    /// Registers the family email list with the bot. Carries `emails` (and optionally
    /// `send_test`) instead of a position; see `FamilyContacts`.
    public static let familyContacts: Self = "family_contacts"
}

/// Nested `{ lat, lng }` form of a position. The flat `lat` / `lng` fields are what OpenCane
/// sends; this exists because the contract accepts either and a decode must not fail on it.
public struct OpenCaneGeo: Codable, Sendable, Equatable {
    public var lat: Double
    public var lng: Double
    public init(lat: Double, lng: Double) {
        self.lat = lat
        self.lng = lng
    }
}

/// What was in the way. Every field is optional: the LiDAR path often knows a distance but not a
/// kind, and the vision path the reverse.
public struct OpenCaneObstacle: Codable, Sendable, Equatable {
    /// Free text from the classifier: "door", "wall", "pole", "curb", "person".
    public var kind: String?
    /// Metres from the walker when detected.
    public var distanceM: Double?
    /// "left", "center", "right", "head" — the lane the cue fired in.
    public var direction: String?

    /// ⚠ `distance_m`, not `distanceM`: the bot reads snake_case.
    private enum CodingKeys: String, CodingKey {
        case kind
        case distanceM = "distance_m"
        case direction
    }

    public init(kind: String? = nil, distanceM: Double? = nil, direction: String? = nil) {
        self.kind = kind
        self.distanceM = distanceM
        self.direction = direction
    }
}

/// One arbitrary JSON value, for the open-ended `extra` bag. Swift has no `unknown`, and
/// `[String: Any]` is neither `Codable` nor `Sendable`, so the contract's
/// `Record<string, unknown>` needs this.
public enum OpenCaneJSON: Codable, Sendable, Equatable, ExpressibleByStringLiteral,
                          ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                          ExpressibleByBooleanLiteral {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([OpenCaneJSON])
    case object([String: OpenCaneJSON])

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([OpenCaneJSON].self) { self = .array(v) }
        else if let v = try? c.decode([String: OpenCaneJSON].self) { self = .object(v) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

/// One event for the Grok Bot webhook. Only `type` is required; everything else is omitted when
/// nil so the bot can tell "unknown" from "zero".
public struct OpenCaneEvent: Codable, Sendable, Equatable {
    /// Required. See `OpenCaneEventType`.
    public var type: OpenCaneEventType
    /// Omit to let the bot infer (fall / sos ⇒ critical).
    public var severity: OpenCaneSeverity?
    /// ISO-8601 UTC ("2026-09-12T20:30:00Z"). `stamped(at:)` fills it when absent.
    public var timestamp: String?
    public var lat: Double?
    public var lng: Double?
    /// Nested alternative to `lat`/`lng`; OpenCane sends the flat pair and leaves this nil.
    public var location: OpenCaneGeo?
    /// Horizontal accuracy, metres.
    public var accuracyM: Double?
    /// Degrees from true north.
    public var heading: Double?
    /// Ground speed, metres per second.
    public var speedMps: Double?
    /// Human-readable detail. This is the line a family member effectively reads.
    public var note: String?
    /// Alias of `note` in the contract. OpenCane sends `note`; kept so a decode round-trips.
    public var message: String?
    public var label: String?
    /// Who is walking ("Tejas").
    public var user: String?
    /// Which cane ("opencane-01").
    public var caneID: String?
    /// 0–100. `clampedBatteryPct` is what the constructors use.
    public var batteryPct: Int?
    public var obstacle: OpenCaneObstacle?
    public var extra: [String: OpenCaneJSON]?
    /// `family_contacts` only: the addresses the bot should alert. Absent on every other event.
    public var emails: [String]?
    /// `family_contacts` only: ask the bot to email each address a confirmation. Absent means no.
    public var sendTest: Bool?

    /// ⚠ The wire names. These are the contract with the bot — see the file header.
    private enum CodingKeys: String, CodingKey {
        case type, severity, timestamp, lat, lng, location
        case accuracyM = "accuracy_m"
        case heading
        case speedMps = "speed_mps"
        case note, message, label, user
        case caneID = "cane_id"
        case batteryPct = "battery_pct"
        case obstacle, extra, emails
        case sendTest = "send_test"
    }

    public init(type: OpenCaneEventType,
                severity: OpenCaneSeverity? = nil,
                timestamp: String? = nil,
                lat: Double? = nil,
                lng: Double? = nil,
                location: OpenCaneGeo? = nil,
                accuracyM: Double? = nil,
                heading: Double? = nil,
                speedMps: Double? = nil,
                note: String? = nil,
                message: String? = nil,
                label: String? = nil,
                user: String? = nil,
                caneID: String? = nil,
                batteryPct: Int? = nil,
                obstacle: OpenCaneObstacle? = nil,
                extra: [String: OpenCaneJSON]? = nil,
                emails: [String]? = nil,
                sendTest: Bool? = nil) {
        self.type = type
        self.severity = severity
        self.timestamp = timestamp
        self.lat = lat
        self.lng = lng
        self.location = location
        self.accuracyM = accuracyM
        self.heading = heading
        self.speedMps = speedMps
        self.note = note
        self.message = message
        self.label = label
        self.user = user
        self.caneID = caneID
        self.batteryPct = batteryPct
        self.obstacle = obstacle
        self.extra = extra
        self.emails = emails
        self.sendTest = sendTest
    }

    /// ISO-8601 UTC text for `date`, e.g. "2026-09-12T20:30:00Z". Second resolution: the bot reads
    /// it as a human-facing time, and fractional seconds only make the SMS uglier.
    public static func iso8601(_ date: Date) -> String {
        date.formatted(.iso8601
            .year().month().day()
            .dateTimeSeparator(.standard)
            .time(includingFractionalSeconds: false)
            .timeZone(separator: .omitted))
    }

    /// A copy with `timestamp` set to `date` **only when it is missing** — a caller that already
    /// knows the detection time (the trip log's clock) keeps it.
    public func stamped(at date: Date) -> OpenCaneEvent {
        guard timestamp == nil else { return self }
        var copy = self
        copy.timestamp = Self.iso8601(date)
        return copy
    }

    /// The POST body: UTF-8 JSON, keys sorted so a test can compare bytes and a log line is
    /// readable. Nil fields are absent (Codable omits optionals), which is the contract.
    public func jsonBody() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
