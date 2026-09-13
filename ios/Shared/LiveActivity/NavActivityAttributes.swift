//
//  NavActivityAttributes.swift
//  CaneKit (app + widget extension)
//
//  Live Activity payload: the next instruction, distance, and real-time obstacle glance
//  in the Dynamic Island / lock screen so the sighted teammate can glance at the phone on
//  the cane without unlocking it.
//
//  Owner: module `watch-widget-shared` (docs/CODE_REFERENCE.md). Compiled into two targets
//  (`ios/project.yml` lists `Shared/LiveActivity` as a source of both, not the watch):
//  the app (producer: `LiveActivityController`) and `CaneKitWidget` (consumer: `NavLiveActivity`).
//  Why `Shared/`: the widget extension does not link the app, and `CaneKitLogic` must stay
//  ActivityKit-free (Foundation only), so the one type both sides need lives here.
//
//  Threading / isolation: `nonisolated` value type — ActivityKit encodes/decodes it off the
//  main actor, so it must not inherit the app target's MainActor default isolation.
//
//  Key invariants:
//    · Wire contract between app and widget extension: uses decodeIfPresent with fallbacks so
//      new fields never crash a widget running against an older payload format.
//    · Every `kind` string the app sends must be handled by the widget's glyph switch.
//    · ⚠ Step 64 safety: `sensing` defaults to `.none` (an old payload, a decode of an unknown value,
//      or a stale activity) and the widget may draw "Path clear" / the green check ONLY when it is
//      `.live` and the activity is not stale (`NavIslandSensing.showsClear`, mirroring
//      `IslandPhasePolicy.showsClear` in CaneKitLogic, pinned by `showsClearOnlyWhenLive`).
//    · The phase / sensing / alert raw values are the same strings as CaneKitLogic's `IslandPhase`,
//      `IslandSensing`, `IslandAlertLevel` (the widget cannot link the package, so they are
//      mirrored here; `LiveActivityController` converts by raw value).
//

import ActivityKit
import Foundation

/// Real-time obstacle clearance glance level for Live Activities and Dynamic Island.
public enum LiveActivityObstacleGlance: String, Codable, Hashable, Sendable {
    case clear
    case warning
    case head
    case dropOff
}

/// What the Live Activity is about right now (mirror of CaneKitLogic `IslandPhase`, Step 64).
/// Decoded leniently: an unknown string is `.walking`.
public enum NavIslandPhase: String, Codable, Hashable, Sendable {
    case warming, walking, indoor, listening, thinking, arrived, stopped

    public init(from decoder: Decoder) throws {
        self = NavIslandPhase(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .walking
    }
}

/// Whether obstacle detection is running (mirror of CaneKitLogic `IslandSensing`, Step 64).
/// Decoded leniently: an unknown string is `.none` — never green.
public enum NavIslandSensing: String, Codable, Hashable, Sendable {
    case live, paused, none

    public init(from decoder: Decoder) throws {
        self = NavIslandSensing(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .none
    }

    /// The only condition under which the widget may say "Path clear" / draw the green check.
    /// ⚠ Mirror of `IslandPhasePolicy.showsClear` (CaneKitLogic, `showsClearOnlyWhenLive`).
    public func showsClear(isStale: Bool) -> Bool { self == .live && !isStale }
}

/// Obstacle urgency for the keyline tint and the alert (mirror of CaneKitLogic `IslandAlertLevel`).
/// Decoded leniently: an unknown string is `.none`.
public enum NavIslandAlert: String, Codable, Hashable, Sendable {
    case none, near, curb, stop, head

    public init(from decoder: Decoder) throws {
        self = NavIslandAlert(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .none
    }
}

/// The navigation Live Activity's attributes: the static route name plus the `ContentState`
/// that changes during the walk. `nonisolated`: ActivityKit encodes this off the main actor.
nonisolated public struct NavActivityAttributes: ActivityAttributes, Sendable {

    /// The dynamic part, pushed when coalesced rules are satisfied.
    public struct ContentState: Codable, Hashable, Sendable {
        /// The current waypoint's spoken line (`NavigationEngine.instruction`); on `end` the final
        /// line (`"Arrived: <say>"` on arrival, "Route ended" on Stop).
        public var instruction: String
        /// Whole metres to the next waypoint (`NavigationEngine.distanceToNext`, rounded); 0 when
        /// unknown and at the end.
        public var distanceM: Int
        /// "turnLeft" / "turnRight" / "crossing" / "arrived" / "straight" — picks the glyph.
        public var kind: String
        /// Real-time obstacle clearance: clear / warning / head / dropOff
        public var obstacleStatus: LiveActivityObstacleGlance
        /// Distance in metres to nearest obstacle (0 when clear)
        public var obstacleDistanceM: Double
        /// Head-height clearance in metres (0 when clear)
        public var headClearanceM: Double
        /// Optional status badge, e.g. "±3m GPS" (capped at 120 chars)
        public var statusDetail: String
        /// Route progress 0…1 (waypoints passed / waypoints total) for the island's progress bar
        /// (Step 47, the Google Maps reference). 0 when unknown; 1 on arrival.
        public var progress: Double
        /// Step 64: what the island is about (warming countdown, walking, indoor step, voice, final
        /// card). `decodeIfPresent` default `.walking`.
        public var phase: NavIslandPhase
        /// Step 64: obstacle detection live / paused (app in background) / none (unknown, no
        /// LiDAR, warming). `decodeIfPresent` default `.none`. ⚠ Never green unless `.live`.
        public var sensing: NavIslandSensing
        /// Step 64: current indoor step, 0-based (`IndoorProgress.index`); the widget shows +1.
        public var stepIndex: Int
        /// Step 64: indoor step count; 0 when not indoors.
        public var stepCount: Int
        /// Step 64: when the depth readiness wait ends (warming phase), for a
        /// `Text(timerInterval:)` countdown that needs no updates. nil otherwise.
        public var warmupEndsAt: Date?
        /// Step 64: obstacle urgency (keyline tint, alert escalation). Default `.none`.
        public var alertLevel: NavIslandAlert

        public init(
            instruction: String,
            distanceM: Int,
            kind: String,
            obstacleStatus: LiveActivityObstacleGlance = .clear,
            obstacleDistanceM: Double = 0.0,
            headClearanceM: Double = 0.0,
            statusDetail: String = "",
            progress: Double = 0,
            phase: NavIslandPhase = .walking,
            sensing: NavIslandSensing = .none,
            stepIndex: Int = 0,
            stepCount: Int = 0,
            warmupEndsAt: Date? = nil,
            alertLevel: NavIslandAlert = .none
        ) {
            self.phase = phase
            self.sensing = sensing
            self.stepIndex = max(0, stepIndex)
            self.stepCount = max(0, stepCount)
            self.warmupEndsAt = warmupEndsAt
            self.alertLevel = alertLevel
            self.instruction = instruction
            self.distanceM = distanceM
            self.kind = kind
            self.obstacleStatus = obstacleStatus
            self.obstacleDistanceM = obstacleDistanceM
            self.headClearanceM = headClearanceM
            self.statusDetail = String(statusDetail.prefix(120))
            self.progress = min(1, max(0, progress))
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.instruction = try container.decode(String.self, forKey: .instruction)
            self.distanceM = try container.decode(Int.self, forKey: .distanceM)
            self.kind = try container.decode(String.self, forKey: .kind)
            self.obstacleStatus = try container.decodeIfPresent(LiveActivityObstacleGlance.self, forKey: .obstacleStatus) ?? .clear
            self.obstacleDistanceM = try container.decodeIfPresent(Double.self, forKey: .obstacleDistanceM) ?? 0.0
            self.headClearanceM = try container.decodeIfPresent(Double.self, forKey: .headClearanceM) ?? 0.0
            let rawDetail = try container.decodeIfPresent(String.self, forKey: .statusDetail) ?? ""
            self.statusDetail = String(rawDetail.prefix(120))
            self.progress = min(1, max(0, try container.decodeIfPresent(Double.self, forKey: .progress) ?? 0))
            // Step 64 fields: every one optional on the wire; the defaults never claim "live".
            self.phase = (try? container.decodeIfPresent(NavIslandPhase.self, forKey: .phase)) ?? .walking
            self.sensing = (try? container.decodeIfPresent(NavIslandSensing.self, forKey: .sensing)) ?? .none
            self.stepIndex = max(0, (try? container.decodeIfPresent(Int.self, forKey: .stepIndex)) ?? 0)
            self.stepCount = max(0, (try? container.decodeIfPresent(Int.self, forKey: .stepCount)) ?? 0)
            self.warmupEndsAt = try? container.decodeIfPresent(Date.self, forKey: .warmupEndsAt)
            self.alertLevel = (try? container.decodeIfPresent(NavIslandAlert.self, forKey: .alertLevel)) ?? .none
        }

        private enum CodingKeys: String, CodingKey {
            case instruction, distanceM, kind, obstacleStatus, obstacleDistanceM, headClearanceM, statusDetail, progress
            case phase, sensing, stepIndex, stepCount, warmupEndsAt, alertLevel
        }
    }

    /// Static for the activity's lifetime: the route name ("ISR Townsend Hall to CIF" for the
    /// bundled route, "To <place>" for a MapKit route — `RouteSource`; the trip's name for an indoor
    /// walk, kept by its outdoor leg). At most `maxRouteNameCharacters`.
    public var routeName: String

    /// Longest `routeName`, characters (review round 9c: a spoken "to <anything>" destination must
    /// not bloat the ActivityKit payload; same cap as `statusDetail`).
    public static let maxRouteNameCharacters = 120

    /// - Parameter routeName: the route / trip name; cut to `maxRouteNameCharacters`.
    public init(routeName: String) {
        self.routeName = String(routeName.prefix(Self.maxRouteNameCharacters))
    }
}
