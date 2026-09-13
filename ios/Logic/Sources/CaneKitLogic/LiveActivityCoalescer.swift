//
//  LiveActivityCoalescer.swift
//  CaneKitLogic
//
//  Pure decision logic for ActivityKit live activity update coalescing.
//  ActivityKit aggressively rate-limits frequent updates and drops bursts.
//  This coalescer enforces:
//    1. Immediate emission on safety-critical hazard transitions (clear <-> warning/head/dropOff).
//    2. Dynamic non-linear distance bands (2m near turns <30m, 5m at <100m, 10m at range).
//    3. Immediate emission on navigation instruction or turn kind changes.
//    4. Rate-limit time floor (minIntervalSec) for routine updates.
//    5. Suppression of statusDetail string jitter.
//    6. Immediate emission on an island phase or sensing change (Step 64: a locked screen must say
//       "Obstacles paused" at once; listening / indoor steps are what the walker is doing now).
//
//  Owner: module `navigation-trip`. Callers: `LiveActivityController` (app).
//  Isolation: Sendable struct, nonisolated.
//  Tests: `LiveActivityCoalescerTests.swift`.
//

import Foundation

/// Real-time obstacle clearance glance level for Live Activities and Dynamic Island.
public enum LiveActivityObstacleStatus: String, Codable, Hashable, Sendable {
    case clear
    case warning
    case head
    case dropOff
}

/// A complete, normalized snapshot of navigation and safety state for the Live Activity.
public struct LiveActivitySnapshot: Equatable, Sendable, Codable {
    public var instruction: String
    public var distanceM: Int
    public var kind: String
    public var obstacleStatus: LiveActivityObstacleStatus
    public var obstacleDistanceM: Double
    public var headClearanceM: Double
    public var statusDetail: String
    /// Island phase raw value (`IslandPhase`), Step 64. Default "walking".
    public var phase: String
    /// Sensing raw value (`IslandSensing`), Step 64. Default "none" — never assume live.
    public var sensing: String

    public init(
        instruction: String,
        distanceM: Int,
        kind: String,
        obstacleStatus: LiveActivityObstacleStatus = .clear,
        obstacleDistanceM: Double = 0.0,
        headClearanceM: Double = 0.0,
        statusDetail: String = "",
        phase: String = IslandPhase.walking.rawValue,
        sensing: String = IslandSensing.none.rawValue
    ) {
        self.phase = phase
        self.sensing = sensing
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
        self.obstacleStatus = try container.decodeIfPresent(LiveActivityObstacleStatus.self, forKey: .obstacleStatus) ?? .clear
        self.obstacleDistanceM = try container.decodeIfPresent(Double.self, forKey: .obstacleDistanceM) ?? 0.0
        self.headClearanceM = try container.decodeIfPresent(Double.self, forKey: .headClearanceM) ?? 0.0
        let rawDetail = try container.decodeIfPresent(String.self, forKey: .statusDetail) ?? ""
        self.statusDetail = String(rawDetail.prefix(120))
        self.phase = try container.decodeIfPresent(String.self, forKey: .phase) ?? IslandPhase.walking.rawValue
        self.sensing = try container.decodeIfPresent(String.self, forKey: .sensing) ?? IslandSensing.none.rawValue
    }

    private enum CodingKeys: String, CodingKey {
        case instruction, distanceM, kind, obstacleStatus, obstacleDistanceM, headClearanceM, statusDetail, phase, sensing
    }
}

/// Pure state machine governing when an ActivityKit update should be dispatched.
public struct LiveActivityCoalescer: Sendable {
    public private(set) var lastEmitted: LiveActivitySnapshot?
    public private(set) var lastEmittedAt: Double = 0

    /// Minimum seconds between non-emergency ActivityKit updates to prevent throttling.
    public var minIntervalSec: Double
    /// Minimum seconds between emergency hazard transitions to prevent sensor flap bursts.
    public var minEmergencyIntervalSec: Double

    /// Seconds after the last update at which the widget should stop showing a live-looking
    /// distance (`ActivityContent.staleDate`; the widget reads `context.isStale` and dims the
    /// number, says "No update"). 300 s: a walker can stand at a crossing for two minutes and
    /// CoreLocation sends no fix while still, so anything shorter would go stale on every curb;
    /// an app killed mid-route (the one case this exists for — ActivityKit keeps the island up
    /// for hours after the process is gone) is dim within five minutes. Step 47. Pinned by
    /// `staleAfterOutlivesACrossingWait`.
    public static let staleAfter: TimeInterval = 300

    public init(minIntervalSec: Double = 0.8, minEmergencyIntervalSec: Double = 0.2) {
        self.minIntervalSec = minIntervalSec
        self.minEmergencyIntervalSec = minEmergencyIntervalSec
    }

    /// Evaluates whether a new snapshot should be dispatched to ActivityKit.
    /// Returns true and updates recorded state if the update should be sent.
    public mutating func shouldEmit(snapshot: LiveActivitySnapshot, now: Double) -> Bool {
        guard let last = lastEmitted else {
            lastEmitted = snapshot
            lastEmittedAt = now
            return true
        }

        // 0. Island phase or sensing change fires immediately (Step 64). Pinned by
        //    `sensingChangeBypassesFloor`, `phaseChangeBypassesFloor`.
        if snapshot.phase != last.phase || snapshot.sensing != last.sensing {
            lastEmitted = snapshot
            lastEmittedAt = now
            return true
        }

        // 1. Critical safety transition fires immediately, guarded by an emergency debounce
        //    against rapid sensor flapping / oscillation.
        let isSafetyTransition = (snapshot.obstacleStatus != last.obstacleStatus && snapshot.obstacleStatus != .clear)
            || (last.obstacleStatus != .clear && snapshot.obstacleStatus == .clear)
        if isSafetyTransition {
            if now - lastEmittedAt >= minEmergencyIntervalSec {
                lastEmitted = snapshot
                lastEmittedAt = now
                return true
            }
            return false
        }

        // 2. Rate-limiting time floor for routine updates
        if now - lastEmittedAt < minIntervalSec {
            return false
        }

        // 3. Instruction or turn glyph kind change always fires
        if snapshot.instruction != last.instruction || snapshot.kind != last.kind {
            lastEmitted = snapshot
            lastEmittedAt = now
            return true
        }

        // 4. Non-linear distance band gating:
        //    < 30m: 2m change
        //    < 100m: 5m change
        //    >= 100m: 10m change
        let distDelta = abs(snapshot.distanceM - last.distanceM)
        let distanceThreshold: Int
        if snapshot.distanceM < 30 {
            distanceThreshold = 2
        } else if snapshot.distanceM < 100 {
            distanceThreshold = 5
        } else {
            distanceThreshold = 10
        }

        if distDelta >= distanceThreshold {
            lastEmitted = snapshot
            lastEmittedAt = now
            return true
        }

        // 5. Obstacle distance change while in caution/warning (>= 0.3m delta)
        if snapshot.obstacleStatus != .clear && abs(snapshot.obstacleDistanceM - last.obstacleDistanceM) >= 0.3 {
            lastEmitted = snapshot
            lastEmittedAt = now
            return true
        }

        return false
    }

    public mutating func reset() {
        lastEmitted = nil
        lastEmittedAt = 0
    }
}
