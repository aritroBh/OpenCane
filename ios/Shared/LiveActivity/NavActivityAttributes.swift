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

        public init(
            instruction: String,
            distanceM: Int,
            kind: String,
            obstacleStatus: LiveActivityObstacleGlance = .clear,
            obstacleDistanceM: Double = 0.0,
            headClearanceM: Double = 0.0,
            statusDetail: String = ""
        ) {
            self.instruction = instruction
            self.distanceM = distanceM
            self.kind = kind
            self.obstacleStatus = obstacleStatus
            self.obstacleDistanceM = obstacleDistanceM
            self.headClearanceM = headClearanceM
            self.statusDetail = String(statusDetail.prefix(120))
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
        }

        private enum CodingKeys: String, CodingKey {
            case instruction, distanceM, kind, obstacleStatus, obstacleDistanceM, headClearanceM, statusDetail
        }
    }

    /// Static for the activity's lifetime: the route name ("ISR Townsend Hall to CIF" for the
    /// bundled route, "To <place>" for a MapKit route — `RouteSource`).
    public var routeName: String

    public init(routeName: String) {
        self.routeName = routeName
    }
}
