//
//  CourseSmoother.swift
//  CaneKitLogic
//
//  Direction of travel measured over distance, not per fix. A per-fix GPS course swings by tens
//  of degrees when the position jitters a few metres (under trees, next to buildings), and the
//  off-course detector turns that swing into false "Veer left/right" cues. This measures the
//  bearing from where the walker was ≥ `baseline` metres ago to where they are now, averaging a
//  few fixes at each end, so 5 m of jitter becomes a few degrees of error.
//
//  Used for veer decisions only (NavigationEngine). The beacon keeps the fast raw heading: its job
//  is to respond to turns immediately, and a 15 m baseline lags a turn by ~12 s at walking pace.
//  Tuned by simulation (±6 m white jitter, 20 seeds): 15 m / 5 fixes → median error 5.8°, worst 28°,
//  never 3 consecutive fixes over the 25° veer threshold (12 m / 3 fixes triggered false veers in
//  half the runs). Tests: CourseSmootherTests.swift.
//

import Foundation

public struct CourseSmoother: Sendable, Equatable {
    /// Metres of travel between the two ends of the measurement.
    public var baseline: Double = 15
    /// Fixes averaged at each end.
    public var endFixes: Int = 5
    /// Fixes older than this are forgotten (s).
    public var maxAge: TimeInterval = 30
    /// Poor fixes are not used at all (m).
    public var maxAccuracy: Double = 20

    private var trail: [GeoFix] = []

    public init() {}

    public mutating func reset() { trail.removeAll() }

    /// Feed every fix. Returns the smoothed course (degrees true) or nil while there is not yet
    /// `baseline` metres of good track.
    public mutating func update(_ fix: GeoFix) -> Double? {
        guard fix.accuracy >= 0, fix.accuracy <= maxAccuracy else { return nil }
        trail.append(fix)
        trail.removeAll { fix.timestamp - $0.timestamp > maxAge }
        guard trail.count >= endFixes * 2 else { return nil }

        let recent = Self.mean(trail.suffix(endFixes))
        // Walk back to the newest group of fixes that is at least `baseline` from "now".
        var i = trail.count - endFixes - 1
        while i >= 0 {
            if GeoMath.distanceMeters(trail[i].coordinate, recent) >= baseline {
                let lo = max(0, i - endFixes + 1)
                let old = Self.mean(trail[lo...i])
                return GeoMath.bearingDegrees(from: old, to: recent)
            }
            i -= 1
        }
        return nil
    }

    static func mean<C: Collection>(_ fixes: C) -> Coordinate where C.Element == GeoFix {
        let n = Double(fixes.count)
        return Coordinate(latitude: fixes.map(\.coordinate.latitude).reduce(0, +) / n,
                          longitude: fixes.map(\.coordinate.longitude).reduce(0, +) / n)
    }
}
