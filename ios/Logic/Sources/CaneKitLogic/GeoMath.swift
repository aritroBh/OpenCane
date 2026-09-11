//
//  GeoMath.swift
//  CaneKitLogic
//
//  Great-circle distance / bearing, angle wrapping, off-course detection and waypoint geofences.
//  Foundation only; the app adapts CLLocation → GeoFix.
//

import Foundation

public struct Coordinate: Sendable, Equatable, Codable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// One GPS fix, already stripped of CoreLocation types.
public struct GeoFix: Sendable, Equatable {
    public var coordinate: Coordinate
    /// Horizontal accuracy in metres (negative = invalid).
    public var accuracy: Double
    /// Ground speed in m/s (negative = invalid).
    public var speed: Double
    public var timestamp: TimeInterval
    public init(coordinate: Coordinate, accuracy: Double, speed: Double, timestamp: TimeInterval) {
        self.coordinate = coordinate
        self.accuracy = accuracy
        self.speed = speed
        self.timestamp = timestamp
    }
}

public enum GeoMath {
    static let earthRadius = 6_371_000.0

    public static func distanceMeters(_ a: Coordinate, _ b: Coordinate) -> Double {
        let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180
        let dφ = (b.latitude - a.latitude) * .pi / 180
        let dλ = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial bearing from `a` to `b`, degrees clockwise from true north in [0, 360).
    public static func bearingDegrees(from a: Coordinate, to b: Coordinate) -> Double {
        let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180
        let dλ = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(dλ)
        return wrap360(atan2(y, x) * 180 / .pi)
    }

    /// Wrap to [0, 360).
    public static func wrap360(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }

    /// Wrap to (-180, 180]. Positive = target is clockwise (to the right) of heading.
    public static func wrap180(_ deg: Double) -> Double {
        var d = wrap360(deg)
        if d > 180 { d -= 360 }
        return d
    }

    /// Signed error from `heading` to `target` in (-180, 180].
    public static func bearingError(target: Double, heading: Double) -> Double {
        wrap180(target - heading)
    }
}

public enum Turn: String, Sendable, Codable, Equatable {
    case left, right
}

/// Off-bearing > `threshold` continuously for `hold` seconds → one veer cue, then `cooldown`.
public final class OffCourseDetector {
    public var threshold: Double = 25
    public var hold: TimeInterval = 3
    public var cooldown: TimeInterval = 10

    private var offSince: TimeInterval?
    private var lastCue: TimeInterval = -.infinity

    public init() {}

    public func reset() {
        offSince = nil
        lastCue = -.infinity
    }

    /// - Parameter error: signed bearing error (target − heading), degrees.
    /// - Returns: the direction to veer, once per episode.
    public func update(error: Double, now: TimeInterval) -> Turn? {
        guard abs(error) > threshold else {
            offSince = nil
            return nil
        }
        if offSince == nil { offSince = now }
        guard now - offSince! >= hold, now - lastCue >= cooldown else { return nil }
        lastCue = now
        offSince = now          // require another full hold before the next cue
        return error > 0 ? .right : .left
    }
}

public enum NavEvent: Sendable, Equatable {
    case reached(index: Int, waypoint: Waypoint, isLast: Bool)
}

/// Walks a waypoint list: enter-once geofences with GPS quality gating.
/// Arrival (last waypoint) is exempt from the accuracy/speed gates so it can always fire.
public final class GeofenceTracker {
    public private(set) var waypoints: [Waypoint]
    public private(set) var index: Int = 0
    /// Ignore fixes worse than this (metres) for intermediate waypoints.
    public var maxAccuracy: Double = 15
    /// Ignore fixes slower than this (m/s) for intermediate waypoints (standing still near a fence).
    public var minSpeed: Double = 0.5

    public init(waypoints: [Waypoint]) {
        self.waypoints = waypoints
    }

    public var current: Waypoint? { index < waypoints.count ? waypoints[index] : nil }
    public var isFinished: Bool { index >= waypoints.count }

    /// Manual "next" (watch crown / Action button). Returns the waypoint skipped past.
    @discardableResult
    public func advance() -> Waypoint? {
        guard let wp = current else { return nil }
        index += 1
        return wp
    }

    public func update(_ fix: GeoFix) -> NavEvent? {
        guard let wp = current else { return nil }
        let isLast = index == waypoints.count - 1
        if !isLast {
            // Invalid (negative) accuracy or speed never satisfies the gate: CoreLocation reports
            // speed -1 exactly when it cannot compute one, typically while standing still.
            if fix.accuracy < 0 || fix.accuracy > maxAccuracy { return nil }
            if fix.speed < 0 || fix.speed <= minSpeed { return nil }
        }
        let d = GeoMath.distanceMeters(fix.coordinate, wp.coordinate)
        guard d <= wp.radiusM else { return nil }
        let i = index
        index += 1
        return .reached(index: i, waypoint: wp, isLast: isLast)
    }

    /// Bearing the user should walk right now: live bearing to the current waypoint when the fix is
    /// good, otherwise the previous waypoint's recorded `bearing_next_deg`.
    public func targetBearing(from fix: GeoFix, maxLiveAccuracy: Double = 20) -> Double? {
        guard let wp = current else { return nil }
        if fix.accuracy >= 0 && fix.accuracy <= maxLiveAccuracy {
            return GeoMath.bearingDegrees(from: fix.coordinate, to: wp.coordinate)
        }
        if index > 0 { return waypoints[index - 1].bearingNextDeg }
        return GeoMath.bearingDegrees(from: fix.coordinate, to: wp.coordinate)
    }
}
