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
    #expect(t.update(fix(near2, accuracy: 40, speed: 0)) == .reached(index: 1, waypoint: wps[1], isLast: true))
    #expect(t.isFinished)
    #expect(t.update(fix(near2)) == nil)
}

@Test func invalidSpeedOrAccuracyDoesNotPassIntermediateGate() {
    let t = GeofenceTracker(waypoints: wps)
    let near1 = Coordinate(latitude: 40.10965, longitude: -88.2244)
    #expect(t.update(fix(near1, accuracy: -1)) == nil)          // accuracy unknown
    #expect(t.update(fix(near1, speed: -1)) == nil)             // speed unknown (CoreLocation -1)
    #expect(t.update(fix(near1, speed: 0.5)) == nil)            // spec says strictly > 0.5
    #expect(t.update(fix(near1, speed: 0.51)) == .reached(index: 0, waypoint: wps[0], isLast: false))
    // Arrival stays exempt from both gates.
    let near2 = Coordinate(latitude: 40.1126, longitude: -88.2283)
    #expect(t.update(fix(near2, accuracy: -1, speed: -1)) == .reached(index: 1, waypoint: wps[1], isLast: true))
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
