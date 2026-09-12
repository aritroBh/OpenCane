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
//  Owner: `NavigationEngine.courseSmoother` (main actor). `update(fix:)` feeds it every fix; the
//  engine resets it at route start, at every waypoint, on every fix still inside the fence of the
//  corner just reached (the trail would otherwise measure a diagonal across the corner — review
//  round 5 harness: false "Veer right." after WP2/WP3/WP6), and after every veer cue (the trail
//  still holds the veer and would re-fire after the cooldown). The smoothed course replaces the
//  heading in the veer error only while `fix.speed > 0.7` m/s; with no smoothed course yet that
//  moment is reported to `OffCourseDetector.gated(at:)` as a hole, not a verdict.
//  e2e gates: `make e2e SCENARIO=gps_jitter` (≤ 3 veer cues; the per-fix course gave 28) and
//  `SCENARIO=wrong_turn` (still ≥ 1 "Veer right.").
//  Pure: Foundation-only, no clock of its own (fix timestamps only), Sendable value type.
//  Tests (3): `jitterOnAStraightWalkNeverLooksLikeAVeer`, `aRealTurnShowsUpAfterTheBaseline`,
//  `poorFixesAndShortTracksGiveNothing`.
//

import Foundation

/// Bearing of travel over the last ≥ `baseline` metres of good GPS track, for veer decisions only.
/// ⚠ Do not change `baseline`, `endFixes` or the accuracy gate without re-running
/// `CourseSmootherTests` and the two e2e scenarios named in the header.
public struct CourseSmoother: Sendable, Equatable {
    /// Metres of travel between the two ends of the measurement.
    public var baseline: Double = 15
    /// Fixes averaged at each end. Also the minimum trail: nothing is returned before
    /// `2 × endFixes` good fixes are held.
    public var endFixes: Int = 5
    /// Fixes older than this are forgotten (s), measured against the newest fix's timestamp.
    public var maxAge: TimeInterval = 30
    /// Poor fixes are not used at all (m): accuracy outside `0…maxAccuracy` (−1 = invalid) is
    /// rejected before it is stored. Same 20 m as `GeofenceTracker.maxAccuracy` and the veer gate.
    public var maxAccuracy: Double = 20

    /// Good fixes, oldest first, none more than `maxAge` older than the newest.
    private var trail: [GeoFix] = []

    /// Creates an empty smoother with the tuned defaults (15 m, 5 fixes, 30 s, 20 m).
    public init() {}

    /// Forgets the trail, so the next course needs `baseline` metres of new track. Called by
    /// `NavigationEngine` at route start, per waypoint, inside the corner fence and after a veer cue.
    public mutating func reset() { trail.removeAll() }

    /// Feed every fix. Returns the smoothed course (degrees true) or nil while there is not yet
    /// `baseline` metres of good track.
    /// - Parameter fix: any fix; a poor one returns nil and is not stored (the trail is kept).
    /// - Returns: degrees clockwise from true north in [0, 360): the bearing from the mean of the
    ///   (up to `endFixes`) fixes ending at the newest older fix that is ≥ `baseline` from "now",
    ///   to the mean of the last `endFixes` fixes ("now").
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

    /// Arithmetic mean of the fixes' latitude / longitude — fine at campus scale (no antimeridian
    /// handling). Internal; never called with an empty collection.
    static func mean<C: Collection>(_ fixes: C) -> Coordinate where C.Element == GeoFix {
        let n = Double(fixes.count)
        return Coordinate(latitude: fixes.map(\.coordinate.latitude).reduce(0, +) / n,
                          longitude: fixes.map(\.coordinate.longitude).reduce(0, +) / n)
    }
}
