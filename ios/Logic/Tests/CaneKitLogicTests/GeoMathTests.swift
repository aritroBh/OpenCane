//
//  GeoMathTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins GeoMath.swift — haversine distance / bearing, angle wrapping, the veer-cue
//  `OffCourseDetector`, and every `GeofenceTracker` robustness rule (GPS gating, arrival
//  plausibility + streak, skip-ahead, look-ahead arrival, passed-by, leg-bearing near a
//  waypoint). Each case mirrors something that happens on the ISR → CIF walk.
//
//  Key invariants / fixtures:
//    · `isr` / `cif` are the real demo endpoints; `wps` = 2-waypoint ISR → CIF (15 m, 20 m).
//    · `line` = 4 waypoints ~100 m apart due north (1e-3° lat ≈ 111 m), radii 15/15/15/20 m.
//    · `fix(_:accuracy:speed:t:)` defaults to a good walking fix: 5 m accuracy, 1.2 m/s.
//    · Distances metres, speeds m/s, bearings degrees true, times seconds.
//

import Testing
@testable import CaneKitLogic

private let isr = Coordinate(latitude: 40.1095, longitude: -88.2214)
private let cif = Coordinate(latitude: 40.1125, longitude: -88.2283)

/// Haversine gives the real ISR → CIF crow-flies distance (600–750 m), so metre cues are sane.
@Test func isrToCifIsAboutSevenHundredMetres() {
    let d = GeoMath.distanceMeters(isr, cif)
    #expect(d > 600 && d < 750)
}

/// Bearings are clockwise from true north: due N/E/S/W come out 0/90/180/270° (beacon points the right way).
@Test func cardinalBearings() {
    let o = Coordinate(latitude: 40, longitude: -88)
    #expect(abs(GeoMath.bearingDegrees(from: o, to: Coordinate(latitude: 40.001, longitude: -88)) - 0) < 0.5)
    #expect(abs(GeoMath.bearingDegrees(from: o, to: Coordinate(latitude: 40, longitude: -87.999)) - 90) < 0.5)
    #expect(abs(GeoMath.bearingDegrees(from: o, to: Coordinate(latitude: 39.999, longitude: -88)) - 180) < 0.5)
    #expect(abs(GeoMath.bearingDegrees(from: o, to: Coordinate(latitude: 40, longitude: -88.001)) - 270) < 0.5)
}

/// Angle wrapping and the error sign across north (350° → 10° is +20°, i.e. veer right).
@Test func wrapping() {
    #expect(GeoMath.wrap360(-10) == 350)
    #expect(GeoMath.wrap360(370) == 10)
    #expect(GeoMath.wrap180(190) == -170)
    #expect(GeoMath.wrap180(-190) == 170)
    #expect(GeoMath.wrap180(180) == 180)
    #expect(GeoMath.wrap180(360) == 0)
    #expect(GeoMath.bearingError(target: 10, heading: 350) == 20)
    #expect(GeoMath.bearingError(target: 350, heading: 10) == -20)
}

/// A sustained 30° drift says "Veer right" after 3 s, then stays quiet for the 10 s cooldown and
/// speaks again the moment it ends (13 s).
/// The drift is fed at the real ~1 Hz fix cadence: `maxEvidenceGap` means moments further apart
/// than 2 s are a GPS gap, not a sustained drift, and restart the hold (pinned separately by
/// `onlyHolesLongerThanTwoSecondsForgetTheHold`).
@Test func offCourseNeedsThreeSecondsThenCoolsDown() {
    let d = OffCourseDetector()
    #expect(d.update(error: 30, now: 0) == nil)
    #expect(d.update(error: 30, now: 1) == nil)
    #expect(d.update(error: 30, now: 2.9) == nil)
    #expect(d.update(error: 30, now: 3) == .right)
    // The drift goes on at ~1 Hz, so the hold is satisfied from 6 s and only the 10 s cooldown
    // keeps it quiet. (A sparse feed would instead restart the hold — see `maxEvidenceGap`.)
    var spoke: [Double] = []
    for t in stride(from: 4.0, through: 13.0, by: 1) where d.update(error: 30, now: t) != nil {
        spoke.append(t)
    }
    #expect(spoke == [13])                           // silent until the cooldown ends, then once
}

/// Swinging back on bearing mid-drift restarts the 3 s hold, so a brief wobble never nags.
/// Fed at the real ~1 Hz cadence (see `maxEvidenceGap`); the boundary asserted is the hold, not
/// the sampling.
@Test func offCourseResetsWhenBackOnBearing() {
    let d = OffCourseDetector()
    #expect(d.update(error: -40, now: 0) == nil)
    #expect(d.update(error: 5, now: 2) == nil)       // back on bearing: the drift is forgotten
    #expect(d.update(error: -40, now: 2.5) == nil)   // a new episode starts here
    #expect(d.update(error: -40, now: 3.5) == nil)
    #expect(d.update(error: -40, now: 4.5) == nil)
    #expect(d.update(error: -40, now: 5.4) == nil)   // 2.9 s of it: not yet
    #expect(d.update(error: -40, now: 5.5) == .left)
}

private func fix(_ c: Coordinate, accuracy: Double = 5, speed: Double = 1.2, t: Double = 0) -> GeoFix {
    GeoFix(coordinate: c, accuracy: accuracy, speed: speed, timestamp: t)
}

private let wps = [
    Waypoint(id: 1, lat: 40.1096, lon: -88.2244, radiusM: 15, say: "Goodwin. Crossing.", crossing: true, bearingNextDeg: 0),
    Waypoint(id: 2, lat: 40.1125, lon: -88.2283, radiusM: 20, say: "CIF east entrance.", crossing: false, bearingNextDeg: nil),
]

/// Bad-GPS or standing fixes never fire a turn fence; arrival at the CIF door is speed-exempt but needs two plausible fixes.
@Test func geofenceGatesOnAccuracyAndSpeedExceptArrival() {
    let t = GeofenceTracker(waypoints: wps)
    let near1 = Coordinate(latitude: 40.10965, longitude: -88.2244)   // ~5 m from wp 1
    #expect(t.update(fix(isr)) == nil)                                // far away
    #expect(t.update(fix(near1, accuracy: 30)) == nil)                // bad fix
    #expect(t.update(fix(near1, speed: 0.2)) == nil)                  // standing still
    #expect(t.update(fix(near1)) == .reached(index: 0, waypoint: wps[0], isLast: false))
    #expect(t.index == 1)
    let near2 = Coordinate(latitude: 40.1126, longitude: -88.2283)    // ~11 m from CIF
    // Arrival: speed-exempt (people stop at the door), but a 40 m blob is not a plausible fix,
    // 11 m + 30/2 > 20 m is not plausibly inside, and it takes two plausible fixes in a row.
    #expect(t.update(fix(near2, accuracy: 40, speed: 0)) == nil)
    #expect(t.update(fix(near2, accuracy: 30, speed: 0)) == nil)
    #expect(t.update(fix(near2, accuracy: 12, speed: 0)) == nil)
    #expect(t.update(fix(near2, accuracy: 12, speed: 0)) == .reached(index: 1, waypoint: wps[1], isLast: true))
    #expect(t.isFinished)
    #expect(t.update(fix(near2)) == nil)
}

/// A jumpy fix far from the door between two in-fence fixes restarts the arrival count.
@Test func arrivalStreakResetsOnAMiss() {
    let t = GeofenceTracker(waypoints: wps)
    t.advance()
    let near2 = Coordinate(latitude: 40.1126, longitude: -88.2283)
    #expect(t.update(fix(near2, accuracy: 8)) == nil)
    #expect(t.update(fix(isr, accuracy: 8)) == nil)                   // a far fix breaks the streak
    #expect(t.update(fix(near2, accuracy: 8)) == nil)
    #expect(t.update(fix(near2, accuracy: 8)) == .reached(index: 1, waypoint: wps[1], isLast: true))
}

/// CoreLocation's −1 speed / accuracy (standing still, no solution) never fires a turn fence.
@Test func invalidSpeedOrAccuracyDoesNotPassIntermediateGate() {
    let t = GeofenceTracker(waypoints: wps)
    let near1 = Coordinate(latitude: 40.10965, longitude: -88.2244)
    #expect(t.update(fix(near1, accuracy: -1)) == nil)          // accuracy unknown
    #expect(t.update(fix(near1, speed: -1)) == nil)             // speed unknown (CoreLocation -1)
    #expect(t.update(fix(near1, speed: 0.5)) == nil)            // spec says strictly > 0.5
    #expect(t.update(fix(near1, speed: 0.51)) == .reached(index: 0, waypoint: wps[0], isLast: false))
    // Arrival stays exempt from the speed gate but needs a valid accuracy.
    let near2 = Coordinate(latitude: 40.1126, longitude: -88.2283)
    #expect(t.update(fix(near2, accuracy: -1, speed: -1)) == nil)
    #expect(t.update(fix(near2, accuracy: 12, speed: -1)) == nil)
    #expect(t.update(fix(near2, accuracy: 12, speed: -1)) == .reached(index: 1, waypoint: wps[1], isLast: true))
}

/// Three waypoints ~100 m apart on a north-south line (1e-3° lat ≈ 111 m).
private let line = [
    Waypoint(id: 1, lat: 40.1100, lon: -88.2240, radiusM: 15, say: "one", crossing: false, bearingNextDeg: 0),
    Waypoint(id: 2, lat: 40.1109, lon: -88.2240, radiusM: 15, say: "two", crossing: false, bearingNextDeg: 0),
    Waypoint(id: 3, lat: 40.1118, lon: -88.2240, radiusM: 15, say: "three", crossing: false, bearingNextDeg: 0),
    Waypoint(id: 4, lat: 40.1127, lon: -88.2240, radiusM: 20, say: "arrived", crossing: false, bearingNextDeg: nil),
]

/// Walking past a waypoint under trees with bad GPS: entering the next fence skips the missed one.
@Test func missedFenceIsSkippedWhenTheNextOneIsEntered() {
    let t = GeofenceTracker(waypoints: line)
    // Walk straight past waypoint 1 under bad GPS (all fixes gated out), then enter fence 2.
    #expect(t.update(fix(Coordinate(latitude: 40.1100, longitude: -88.2240), accuracy: 30)) == nil)
    #expect(t.update(fix(Coordinate(latitude: 40.1104, longitude: -88.2240), accuracy: 30)) == nil)
    let e = t.update(fix(Coordinate(latitude: 40.11085, longitude: -88.2240)))
    #expect(e == .reached(index: 1, waypoint: line[1], isLast: false, skipped: [line[0]]))
    #expect(t.current == line[2])
}

/// Standing at the CIF door with the last turn's fence never entered still arrives (look-ahead).
@Test func lookaheadReachesArrivalWhenThePreviousFenceWasMissed() {
    let t = GeofenceTracker(waypoints: line)
    t.advance(); t.advance()                                            // current = waypoint 3
    // Standing still at the door (speed 0) inside the arrival fence, waypoint 3 never entered.
    let door = Coordinate(latitude: 40.11272, longitude: -88.2240)
    #expect(t.update(fix(door, accuracy: 10, speed: 0)) == nil)                  // first plausible hit
    let e = t.update(fix(door, accuracy: 10, speed: 0))
    #expect(e == .reached(index: 3, waypoint: line[3], isLast: true, skipped: [line[2]]))
    #expect(t.isFinished)
}

/// One 30 m GPS blob short of the door must not end the route (arrival is irreversible).
@Test func oneBadFixShortOfTheDoorDoesNotArrive() {
    // Mirrors WP8 → CIF: standing ~45 m short with 30 m fixes that land inside the 20 m fence.
    let t = GeofenceTracker(waypoints: line)
    t.advance(); t.advance()
    let blob = Coordinate(latitude: 40.11265, longitude: -88.2240)             // ~6 m from the door
    #expect(t.update(fix(blob, accuracy: 30, speed: 0)) == nil)                 // 6 + 15 > 20
    #expect(!t.isFinished)
}

/// GPS wandering while the user waits at a curb never counts as walking past the waypoint.
@Test func passedByIgnoresStationaryFixesAtACurb() {
    let t = GeofenceTracker(waypoints: line)
    let east = -88.22379                                                        // ≈ 18 m east of the line
    _ = t.update(fix(Coordinate(latitude: 40.1100, longitude: east)))
    for (i, lat) in [40.1101, 40.1102, 40.1103, 40.1104, 40.1105].enumerated() {
        #expect(t.update(fix(Coordinate(latitude: lat, longitude: east), speed: i.isMultiple(of: 2) ? 0 : -1)) == nil)
    }
    #expect(t.current == line[0])
}

/// Walking past the destination at 25 m never ends the route; only entering the arrival fence does.
@Test func passedByNeverAppliesToArrival() {
    let t = GeofenceTracker(waypoints: line)
    t.advance(); t.advance(); t.advance()                                        // current = arrival
    let east = -88.22370                                                        // ≈ 25 m east of the door
    for lat in stride(from: 40.1123, through: 40.1132, by: 0.0001) {
        #expect(t.update(fix(Coordinate(latitude: lat, longitude: east))) == nil)
    }
    #expect(!t.isFinished)
}

/// After a manual Next, the old waypoint's closest approach cannot trigger a false passed-by.
@Test func passedByStateResetsAfterAdvance() {
    let t = GeofenceTracker(waypoints: line)
    _ = t.update(fix(Coordinate(latitude: 40.1099, longitude: -88.22376)))       // ~22 m from line[0]
    t.advance()
    // One receding fix relative to line[1] must not inherit line[0]'s closest approach.
    #expect(t.update(fix(Coordinate(latitude: 40.1104, longitude: -88.22376))) == nil)
    #expect(t.current == line[1])
}

/// 20 m beside a waypoint the beacon keeps the recorded leg bearing instead of swinging sideways.
@Test func targetBearingUsesTheLegNearTheWaypoint() {
    let t = GeofenceTracker(waypoints: line)
    t.advance()                                                                  // current = line[1], leg = north
    // 20 m east of line[1] (outside its 15 m fence, inside 2× radius): live bearing would be ~west.
    let beside = Coordinate(latitude: 40.1109, longitude: -88.22377)
    #expect(t.targetBearing(from: fix(beside)) == 0)
    #expect(t.isNearCurrent(fix(beside)))
}

/// Passing a corner 22 m off (outside the fence) still advances the route as passed-by.
@Test func walkingPastAWaypointCountsAsReached() {
    let t = GeofenceTracker(waypoints: line)
    // Pass waypoint 1 at ~22 m to the east (outside its 15 m fence, inside 2× radius), heading north.
    let east = -88.22374                                               // ≈ 22 m east of the line
    var now = 0.0
    var events: [NavEvent?] = []
    for lat in stride(from: 40.1096, through: 40.1105, by: 0.0001) {   // 11 m steps, ~1 s each
        events.append(t.update(fix(Coordinate(latitude: lat, longitude: east), t: now)))
        now += 1
    }
    let passed = events.compactMap { $0 }.first
    #expect(passed == .reached(index: 0, waypoint: line[0], isLast: false, skipped: [], passedBy: true))
    #expect(t.current == line[1])
}

/// Walking a parallel path 60 m away never counts as passing the waypoint.
@Test func passedByNeedsANearApproach() {
    let t = GeofenceTracker(waypoints: line)
    // Walk north 60 m east of the line: never within 2× radius, so waypoint 1 is not "passed".
    for lat in stride(from: 40.1096, through: 40.1105, by: 0.0001) {
        #expect(t.update(fix(Coordinate(latitude: lat, longitude: -88.2233))) == nil)
    }
    #expect(t.current == line[0])
}

/// Watch crown / Action button Next skips the current waypoint and returns it.
@Test func manualAdvanceSkipsWaypoint() {
    let t = GeofenceTracker(waypoints: wps)
    #expect(t.advance() == wps[0])
    #expect(t.current == wps[1])
}

/// With a 50 m fix the beacon follows the recorded leg bearing, not a live bearing from garbage.
@Test func targetBearingFallsBackToRecordedWhenFixIsPoor() {
    let t = GeofenceTracker(waypoints: wps)
    t.advance()
    let live = t.targetBearing(from: fix(isr, accuracy: 5))!
    #expect(live > 280 && live < 320)                                 // ISR → CIF is roughly WNW
    #expect(t.targetBearing(from: fix(isr, accuracy: 50)) == 0)       // wps[0].bearingNextDeg
}

/// A 45 m blob between two good fixes at the door is ignored, so arrival still completes.
@Test func aGatedOutFixDoesNotBreakTheArrivalStreak() {
    let t = GeofenceTracker(waypoints: wps)
    t.advance()
    let near2 = Coordinate(latitude: 40.1126, longitude: -88.2283)
    let first = t.update(fix(near2, accuracy: 8))
    #expect(first == nil)
    let blob = t.update(fix(near2, accuracy: 45))                    // too poor to judge: ignored
    #expect(blob == nil)
    let second = t.update(fix(near2, accuracy: 8))
    #expect(second == .reached(index: 1, waypoint: wps[1], isLast: true))
}

/// A walker genuinely off course whose moments are only *intermittently* judgeable (a jittery
/// fix here and there is too poor / too slow / has no smoothed course yet) must still be warned:
/// a hole shorter than `maxEvidenceGap` is GPS noise inside otherwise continuous tracking, not a
/// reason to forget a hold. Before this rule every gated moment ended the episode, so the 3 s
/// hold could never accumulate under jitter and the veer warning never fired at all
/// (e2e `wrong_turn`: no "Veer right." after overshooting west at Goodwin).
@Test func gatedMomentsInsideGoodTrackingKeepTheHold() {
    let d = OffCourseDetector()
    #expect(d.update(error: 40, now: 0) == nil)       // episode starts
    d.gated(at: 1)                                    // one unjudgeable moment: jitter, not a gap
    #expect(d.update(error: 40, now: 2) == nil)
    d.gated(at: 3)
    #expect(d.update(error: 40, now: 4) == .right)    // 4 s off course with 1 s holes → warned
}

/// The opposite half of the same rule: a real GPS gap must NOT fire a veer on the first fix back
/// from pre-gap history (the bug commit a7a5fa6 fixed). Both shapes of gap count — gated moments
/// arriving with a stale fix, and no moments at all — and after either one a full 3 s hold of
/// fresh evidence is required.
@Test func aGpsGapForgetsTheHoldSoThereIsNoInstantVeer() {
    let gatedThrough = OffCourseDetector()
    #expect(gatedThrough.update(error: 40, now: 0) == nil)
    #expect(gatedThrough.update(error: 40, now: 2) == nil)
    for t in stride(from: 3.0, through: 32.0, by: 1) { gatedThrough.gated(at: t) }
    #expect(gatedThrough.update(error: 40, now: 33) == nil)   // first fix back: a new episode
    #expect(gatedThrough.update(error: 40, now: 35) == nil)
    #expect(gatedThrough.update(error: 40, now: 36) == .right) // only after a full fresh hold

    let silentThrough = OffCourseDetector()                    // no headings at all during the gap
    #expect(silentThrough.update(error: 40, now: 0) == nil)
    #expect(silentThrough.update(error: 40, now: 2) == nil)
    #expect(silentThrough.update(error: 40, now: 40) == nil)   // 38 s later: not 3 s of evidence
    #expect(silentThrough.update(error: 40, now: 41) == nil)
    #expect(silentThrough.update(error: 40, now: 42) == nil)
    #expect(silentThrough.update(error: 40, now: 43) == .right)
}

/// A stop in the middle of a drift restarts the 3 s hold — it is NOT bridged like a GPS hole.
///
/// Standing still is the one state in which a walker can turn to face anywhere without any
/// evidence recording it, and the course smoother's 15 m trail still describes the approach they
/// walked *before* stopping. So `NavigationEngine` routes a standing fix to `endEpisode()` and a
/// merely poor / stale / missing one to `gated(at:)`. Had the stop been bridged instead, the
/// pre-stop drift would finish the hold at 3 s — announcing "Veer right." to a walker who stopped,
/// corrected and set off again on the right bearing (adversarial review of this fix, finding 1).
/// The `now: 3` expectation below is the one that fails if a stop is ever bridged.
@Test func aStopMidDriftRestartsTheHold() {
    let d = OffCourseDetector()
    #expect(d.update(error: 40, now: 0) == nil)
    #expect(d.update(error: 40, now: 1) == nil)
    d.endEpisode()                                   // the walker stopped: a fact, not a hole
    #expect(d.update(error: 40, now: 2) == nil)
    #expect(d.update(error: 40, now: 3) == nil)      // bridged, this would have cued: 3 s since 0
    #expect(d.update(error: 40, now: 4) == nil)
    #expect(d.update(error: 40, now: 5) == .right)   // a full hold of evidence since the stop
}

/// Pins the number: a hole of exactly `maxEvidenceGap` (2 s — one missed beat of the ~1 Hz fix
/// stream) keeps the hold; anything longer forgets it. Because 2 s is below the 3 s `hold`, a cue
/// always rests on at least three judged moments, never on two with a hole between them.
@Test func onlyHolesLongerThanTwoSecondsForgetTheHold() {
    #expect(OffCourseDetector().maxEvidenceGap == 2)
    let survives = OffCourseDetector()
    #expect(survives.update(error: -40, now: 0) == nil)
    #expect(survives.update(error: -40, now: 2) == nil)        // 2 s hole: still one episode
    #expect(survives.update(error: -40, now: 3) == .left)      // hold met across it
    let forgets = OffCourseDetector()
    #expect(forgets.update(error: -40, now: 0) == nil)
    #expect(forgets.update(error: -40, now: 2.5) == nil)       // 2.5 s hole: history dropped
    #expect(forgets.update(error: -40, now: 4) == nil)         // only 1.5 s of fresh evidence
    #expect(forgets.update(error: -40, now: 5.5) == .left)     // a full hold after the hole
    let forgetsWhileGated = OffCourseDetector()                // the hole seen as gated moments
    #expect(forgetsWhileGated.update(error: -40, now: 0) == nil)
    forgetsWhileGated.gated(at: 1)
    forgetsWhileGated.gated(at: 2.5)                           // the hole is already too long
    #expect(forgetsWhileGated.update(error: -40, now: 3) == nil)
    #expect(forgetsWhileGated.update(error: -40, now: 4) == nil)
    #expect(forgetsWhileGated.update(error: -40, now: 5) == nil)
    #expect(forgetsWhileGated.update(error: -40, now: 6) == .left)
}

/// After a cue and `endEpisode()`, a new off-course stretch needs the full 3 s hold again even
/// once the cooldown has passed.
@Test func endEpisodeRequiresAFullHoldAgain() {
    let d = OffCourseDetector()
    for t in [0.0, 1, 2] { _ = d.update(error: 40, now: t) }   // ~1 Hz, as the app feeds it
    let first = d.update(error: 40, now: 3)
    #expect(first == .right)
    d.endEpisode()
    let tooSoon = d.update(error: 40, now: 15)      // cooldown over, but a new episode just began
    #expect(tooSoon == nil)
    _ = d.update(error: 40, now: 16)
    _ = d.update(error: 40, now: 17)
    let held = d.update(error: 40, now: 18)
    #expect(held == .right)
}
