import Testing
@testable import CaneKitLogic

private let isr = Coordinate(latitude: 40.1095, longitude: -88.2214)
private let cif = Coordinate(latitude: 40.1125, longitude: -88.2283)

@Test func isrToCifIsAboutSevenHundredMetres() {
    let d = GeoMath.distanceMeters(isr, cif)
    #expect(d > 600 && d < 750)
}

@Test func cardinalBearings() {
    let o = Coordinate(latitude: 40, longitude: -88)
    #expect(abs(GeoMath.bearingDegrees(from: o, to: Coordinate(latitude: 40.001, longitude: -88)) - 0) < 0.5)
    #expect(abs(GeoMath.bearingDegrees(from: o, to: Coordinate(latitude: 40, longitude: -87.999)) - 90) < 0.5)
    #expect(abs(GeoMath.bearingDegrees(from: o, to: Coordinate(latitude: 39.999, longitude: -88)) - 180) < 0.5)
    #expect(abs(GeoMath.bearingDegrees(from: o, to: Coordinate(latitude: 40, longitude: -88.001)) - 270) < 0.5)
}

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

@Test func offCourseNeedsThreeSecondsThenCoolsDown() {
    let d = OffCourseDetector()
    #expect(d.update(error: 30, now: 0) == nil)
    #expect(d.update(error: 30, now: 1) == nil)
    #expect(d.update(error: 30, now: 2.9) == nil)
    #expect(d.update(error: 30, now: 3) == .right)
    #expect(d.update(error: 30, now: 6) == nil)      // hold satisfied but inside cooldown
    #expect(d.update(error: 30, now: 12.9) == nil)
    #expect(d.update(error: 30, now: 13) == .right)
}

@Test func offCourseResetsWhenBackOnBearing() {
    let d = OffCourseDetector()
    #expect(d.update(error: -40, now: 0) == nil)
    #expect(d.update(error: 5, now: 2) == nil)
    #expect(d.update(error: -40, now: 2.5) == nil)
    #expect(d.update(error: -40, now: 5.4) == nil)
    #expect(d.update(error: -40, now: 5.5) == .left)
}

private func fix(_ c: Coordinate, accuracy: Double = 5, speed: Double = 1.2, t: Double = 0) -> GeoFix {
    GeoFix(coordinate: c, accuracy: accuracy, speed: speed, timestamp: t)
}

private let wps = [
    Waypoint(id: 1, lat: 40.1096, lon: -88.2244, radiusM: 15, say: "Goodwin. Crossing.", crossing: true, bearingNextDeg: 0),
    Waypoint(id: 2, lat: 40.1125, lon: -88.2283, radiusM: 20, say: "CIF east entrance.", crossing: false, bearingNextDeg: nil),
]

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

@Test func arrivalStreakResetsOnAMiss() {
    let t = GeofenceTracker(waypoints: wps)
    t.advance()
    let near2 = Coordinate(latitude: 40.1126, longitude: -88.2283)
    #expect(t.update(fix(near2, accuracy: 8)) == nil)
    #expect(t.update(fix(isr, accuracy: 8)) == nil)                   // a far fix breaks the streak
    #expect(t.update(fix(near2, accuracy: 8)) == nil)
    #expect(t.update(fix(near2, accuracy: 8)) == .reached(index: 1, waypoint: wps[1], isLast: true))
}

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

@Test func missedFenceIsSkippedWhenTheNextOneIsEntered() {
    let t = GeofenceTracker(waypoints: line)
    // Walk straight past waypoint 1 under bad GPS (all fixes gated out), then enter fence 2.
    #expect(t.update(fix(Coordinate(latitude: 40.1100, longitude: -88.2240), accuracy: 30)) == nil)
    #expect(t.update(fix(Coordinate(latitude: 40.1104, longitude: -88.2240), accuracy: 30)) == nil)
    let e = t.update(fix(Coordinate(latitude: 40.11085, longitude: -88.2240)))
    #expect(e == .reached(index: 1, waypoint: line[1], isLast: false, skipped: [line[0]]))
    #expect(t.current == line[2])
}

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

@Test func oneBadFixShortOfTheDoorDoesNotArrive() {
    // Mirrors WP8 → CIF: standing ~45 m short with 30 m fixes that land inside the 20 m fence.
    let t = GeofenceTracker(waypoints: line)
    t.advance(); t.advance()
    let blob = Coordinate(latitude: 40.11265, longitude: -88.2240)             // ~6 m from the door
    #expect(t.update(fix(blob, accuracy: 30, speed: 0)) == nil)                 // 6 + 15 > 20
    #expect(!t.isFinished)
}

@Test func passedByIgnoresStationaryFixesAtACurb() {
    let t = GeofenceTracker(waypoints: line)
    let east = -88.22379                                                        // ≈ 18 m east of the line
    _ = t.update(fix(Coordinate(latitude: 40.1100, longitude: east)))
    for (i, lat) in [40.1101, 40.1102, 40.1103, 40.1104, 40.1105].enumerated() {
        #expect(t.update(fix(Coordinate(latitude: lat, longitude: east), speed: i.isMultiple(of: 2) ? 0 : -1)) == nil)
    }
    #expect(t.current == line[0])
}

@Test func passedByNeverAppliesToArrival() {
    let t = GeofenceTracker(waypoints: line)
    t.advance(); t.advance(); t.advance()                                        // current = arrival
    let east = -88.22370                                                        // ≈ 25 m east of the door
    for lat in stride(from: 40.1123, through: 40.1132, by: 0.0001) {
        #expect(t.update(fix(Coordinate(latitude: lat, longitude: east))) == nil)
    }
    #expect(!t.isFinished)
}

@Test func passedByStateResetsAfterAdvance() {
    let t = GeofenceTracker(waypoints: line)
    _ = t.update(fix(Coordinate(latitude: 40.1099, longitude: -88.22376)))       // ~22 m from line[0]
    t.advance()
    // One receding fix relative to line[1] must not inherit line[0]'s closest approach.
    #expect(t.update(fix(Coordinate(latitude: 40.1104, longitude: -88.22376))) == nil)
    #expect(t.current == line[1])
}

@Test func targetBearingUsesTheLegNearTheWaypoint() {
    let t = GeofenceTracker(waypoints: line)
    t.advance()                                                                  // current = line[1], leg = north
    // 20 m east of line[1] (outside its 15 m fence, inside 2× radius): live bearing would be ~west.
    let beside = Coordinate(latitude: 40.1109, longitude: -88.22377)
    #expect(t.targetBearing(from: fix(beside)) == 0)
    #expect(t.isNearCurrent(fix(beside)))
}

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

@Test func passedByNeedsANearApproach() {
    let t = GeofenceTracker(waypoints: line)
    // Walk north 60 m east of the line: never within 2× radius, so waypoint 1 is not "passed".
    for lat in stride(from: 40.1096, through: 40.1105, by: 0.0001) {
        #expect(t.update(fix(Coordinate(latitude: lat, longitude: -88.2233))) == nil)
    }
    #expect(t.current == line[0])
}

@Test func manualAdvanceSkipsWaypoint() {
    let t = GeofenceTracker(waypoints: wps)
    #expect(t.advance() == wps[0])
    #expect(t.current == wps[1])
}

@Test func targetBearingFallsBackToRecordedWhenFixIsPoor() {
    let t = GeofenceTracker(waypoints: wps)
    t.advance()
    let live = t.targetBearing(from: fix(isr, accuracy: 5))!
    #expect(live > 280 && live < 320)                                 // ISR → CIF is roughly WNW
    #expect(t.targetBearing(from: fix(isr, accuracy: 50)) == 0)       // wps[0].bearingNextDeg
}

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
