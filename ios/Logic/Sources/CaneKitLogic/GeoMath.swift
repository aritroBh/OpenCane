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
    /// The fence of `waypoint` (at `index`) was entered. `skipped` lists any earlier waypoints the
    /// tracker had to jump over to get there (their fences were missed, e.g. under bad GPS).
    /// `passedBy` is true when the waypoint was never entered but the user clearly walked past it.
    case reached(index: Int, waypoint: Waypoint, isLast: Bool, skipped: [Waypoint] = [], passedBy: Bool = false)
}

/// Walks a waypoint list: enter-once geofences with GPS quality gating.
///
/// Robustness rules (a single missed fence must never strand the route):
///   · **Skip-ahead** — every gated fix is tested against the current waypoint *and* the next
///     `lookahead` ones; entering a later fence advances past the missed ones (reported in
///     `skipped`).
///   · **Passed-by** — if the user came within `passedByFactor × radius` of the current waypoint
///     and the distance has then grown by a full radius over `passedByFixes` consecutive fixes,
///     the waypoint counts as reached (`passedBy: true`). Never applied to the last waypoint.
///   · **Arrival** (last waypoint) is exempt from the speed gate (people stop at the door) but
///     must be *plausibly* inside the fence — `distance + accuracy / 2 ≤ radius` — on
///     `arrivalHits` consecutive fixes, so one 30 m blob 45 m short of the door cannot end the
///     route (arrival stops the beacon and the Live Activity; there is no way back).
public final class GeofenceTracker {
    public private(set) var waypoints: [Waypoint]
    public private(set) var index: Int = 0
    /// Ignore fixes worse than this (metres) for intermediate waypoints.
    public var maxAccuracy: Double = 20
    /// Ignore fixes slower than this (m/s) for intermediate waypoints (standing still near a fence).
    public var minSpeed: Double = 0.5
    /// Arrival needs a valid fix no worse than this (metres); a 50 m blob must not end the route.
    public var maxArrivalAccuracy: Double = 30
    /// Consecutive plausible in-fence fixes needed for arrival.
    public var arrivalHits: Int = 2
    private var arrivalStreak = 0
    /// How many waypoints beyond the current one a fix may claim.
    public var lookahead: Int = 2
    /// "Near" for passed-by detection = this many radii from the waypoint.
    public var passedByFactor: Double = 2
    /// Consecutive receding fixes needed before a near-miss counts as passed.
    public var passedByFixes: Int = 3

    /// Closest gated approach to the current waypoint (metres) since it became current.
    private var minDistance: Double = .infinity
    private var lastDistance: Double?
    private var recedingFixes = 0

    public init(waypoints: [Waypoint]) {
        self.waypoints = waypoints
    }

    public var current: Waypoint? { index < waypoints.count ? waypoints[index] : nil }
    public var isFinished: Bool { index >= waypoints.count }

    /// Manual "next" (watch crown / Action button). Returns the waypoint skipped past.
    @discardableResult
    public func advance() -> Waypoint? {
        guard let wp = current else { return nil }
        moveTo(index + 1)
        return wp
    }

    private func moveTo(_ newIndex: Int) {
        index = newIndex
        minDistance = .infinity
        lastDistance = nil
        recedingFixes = 0
        arrivalStreak = 0
    }

    private func gatePasses(_ fix: GeoFix, forLast isLast: Bool) -> Bool {
        // Invalid (negative) accuracy or speed never satisfies the gate: CoreLocation reports
        // speed -1 exactly when it cannot compute one, typically while standing still.
        if isLast { return fix.accuracy >= 0 && fix.accuracy <= maxArrivalAccuracy }
        if fix.accuracy < 0 || fix.accuracy > maxAccuracy { return false }
        if fix.speed < 0 || fix.speed <= minSpeed { return false }
        return true
    }

    public func update(_ fix: GeoFix) -> NavEvent? {
        guard current != nil else { return nil }
        let lastIndex = waypoints.count - 1

        // 1. Fence entry: current waypoint first, then the look-ahead ones (nearest index wins).
        let upper = min(lastIndex, index + lookahead)
        var arrivalCandidate = false
        var arrivalEvaluated = false
        for i in index...upper {
            let wp = waypoints[i]
            let isLast = i == lastIndex
            guard gatePasses(fix, forLast: isLast) else { continue }
            if isLast { arrivalEvaluated = true }
            let d = GeoMath.distanceMeters(fix.coordinate, wp.coordinate)
            if isLast {
                // Plausibly inside, on consecutive fixes (see the type comment).
                guard d + fix.accuracy / 2 <= wp.radiusM else { continue }
                arrivalCandidate = true
                arrivalStreak += 1
                guard arrivalStreak >= arrivalHits else { continue }
            } else if d > wp.radiusM {
                continue
            }
            let skipped = Array(waypoints[index..<i])
            moveTo(i + 1)
            return .reached(index: i, waypoint: wp, isLast: isLast, skipped: skipped)
        }
        // Reset only on a fix that was good enough to judge: a 40 m blob between two good in-fence
        // fixes at the door must not starve arrival.
        if arrivalEvaluated && !arrivalCandidate { arrivalStreak = 0 }

        // 2. Passed-by: only intermediate waypoints, only on gated fixes.
        let isLast = index == lastIndex
        guard !isLast, gatePasses(fix, forLast: false), let wp = current else { return nil }
        let d = GeoMath.distanceMeters(fix.coordinate, wp.coordinate)
        minDistance = min(minDistance, d)
        // "Receding" tolerates 1 m of GPS jitter so one wobbly fix does not restart the count.
        if let last = lastDistance, d > last - 1 { recedingFixes += 1 } else { recedingFixes = 0 }
        lastDistance = d
        if minDistance <= wp.radiusM * passedByFactor,
           d >= minDistance + wp.radiusM,
           recedingFixes >= passedByFixes {
            let i = index
            moveTo(i + 1)
            return .reached(index: i, waypoint: wp, isLast: false, skipped: [], passedBy: true)
        }
        return nil
    }

    /// Bearing the user should walk right now: live bearing to the current waypoint when the fix is
    /// good, otherwise the previous waypoint's recorded `bearing_next_deg`. Inside the passed-by
    /// arming zone (`passedByFactor × radius`) the recorded leg bearing wins too: next to a
    /// waypoint the live bearing swings wildly with a few metres of offset, and after a missed
    /// fence it would point *back* at the waypoint behind the user.
    public func targetBearing(from fix: GeoFix, maxLiveAccuracy: Double = 20) -> Double? {
        guard let wp = current else { return nil }
        let leg = index > 0 ? waypoints[index - 1].bearingNextDeg : nil
        let d = GeoMath.distanceMeters(fix.coordinate, wp.coordinate)
        if let leg, d <= wp.radiusM * passedByFactor { return leg }
        if fix.accuracy >= 0 && fix.accuracy <= maxLiveAccuracy {
            return GeoMath.bearingDegrees(from: fix.coordinate, to: wp.coordinate)
        }
        return leg ?? GeoMath.bearingDegrees(from: fix.coordinate, to: wp.coordinate)
    }

    /// True when the fix is inside the zone where passed-by may fire (veer cues are muted there).
    public func isNearCurrent(_ fix: GeoFix) -> Bool {
        guard let wp = current, index < waypoints.count - 1 else { return false }
        return GeoMath.distanceMeters(fix.coordinate, wp.coordinate) <= wp.radiusM * passedByFactor
    }
}
