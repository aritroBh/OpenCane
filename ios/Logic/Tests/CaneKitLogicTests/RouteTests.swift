import Foundation
import Testing
@testable import CaneKitLogic

private let a = Coordinate(latitude: 40.1095, longitude: -88.2214)
private let b = Coordinate(latitude: 40.1096, longitude: -88.2244)
private let c = Coordinate(latitude: 40.1107, longitude: -88.2244)
private let d = Coordinate(latitude: 40.1128, longitude: -88.2244)

@Test func mapKitStepsBecomeWaypoints() {
    let steps = [
        RouteStepInput(points: [], instructions: ""),                          // MapKit's empty first step
        RouteStepInput(points: [a, b], instructions: "Head west on Illinois St"),
        RouteStepInput(points: [b, c], instructions: "Cross Goodwin Ave and turn right"),
        RouteStepInput(points: [c, d], instructions: "Turn left onto Springfield Ave"),
    ]
    let w = RouteBuilder.waypoints(from: steps, destinationName: "CIF")
    #expect(w.count == 3)
    #expect(w.map(\.id) == [1, 2, 3])
    #expect(w[0].lat == b.latitude && w[0].lon == b.longitude)
    #expect(w[0].say == "Cross Goodwin Ave and turn right")
    #expect(w[0].crossing)
    #expect(w[0].radiusM == 15)
    #expect(abs(w[0].bearingNextDeg! - GeoMath.bearingDegrees(from: b, to: c)) < 0.01)
    #expect(w[1].say == "Turn left onto Springfield Ave")
    #expect(!w[1].crossing)
    #expect(w[2].say == "Arrived at CIF.")
    #expect(w[2].radiusM == 20)
    #expect(w[2].bearingNextDeg == nil)
}

@Test func routeFileDecodesSnakeCaseSchema() throws {
    let json = """
    { "name": "ISR to CIF", "waypoints": [
      { "id": 3, "lat": 40.1103, "lon": -88.2236, "radius_m": 15,
        "say": "Goodwin Avenue. Crossing. Listen for traffic.",
        "crossing": true, "bearing_next_deg": 355 },
      { "id": 4, "lat": 40.1125, "lon": -88.2283, "radius_m": 20, "say": "CIF.", "crossing": false }
    ] }
    """
    let r = try Route.load(from: Data(json.utf8))
    #expect(r.name == "ISR to CIF")
    #expect(r.waypoints.count == 2)
    #expect(r.waypoints[0].radiusM == 15)
    #expect(r.waypoints[0].bearingNextDeg == 355)
    #expect(r.waypoints[1].bearingNextDeg == nil)
    // Round trip keeps the snake_case keys.
    let back = try JSONEncoder().encode(r)
    let s = String(decoding: back, as: UTF8.self)
    #expect(s.contains("radius_m") && s.contains("bearing_next_deg"))
}

/// The real route file shipped in the app bundle must decode, walk ISR → CIF in order, and have
/// recorded bearings that agree with its own coordinates (catches hand-edit typos on Friday).
@Test func shippedRouteFileIsConsistent() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("../CaneKit/Resources/route_isr_cif.json").standardized
    let r = try Route.load(from: Data(contentsOf: url))
    #expect(r.waypoints.count >= 6 && r.waypoints.count <= 12)
    #expect(r.waypoints.map(\.id) == Array(1...r.waypoints.count))
    #expect(r.waypoints.last?.bearingNextDeg == nil)
    #expect(r.waypoints.last?.radiusM == 20)
    // Exact pins for the demo route (a hand edit must update these on purpose).
    #expect(r.waypoints.filter(\.crossing).map(\.id) == [4, 6, 7])
    #expect(r.waypoints.filter(\.curved).map(\.id) == [1])
    for wp in r.waypoints where [3, 6, 8].contains(wp.id) {
        #expect(wp.radiusM == 12, "turn waypoint \(wp.id) should have a 12 m fence")
    }
    for wp in r.waypoints.dropLast() {
        #expect(wp.radiusM >= 10 && wp.radiusM <= 20, "waypoint \(wp.id) fence out of range")
    }
    // Text and flag agree both ways.
    for wp in r.waypoints {
        if wp.crossing {
            #expect(wp.say.localizedCaseInsensitiveContains("crossing"), "waypoint \(wp.id) crossing without saying so")
        } else {
            let saysCross = wp.say.range(of: "cross", options: .caseInsensitive) != nil
            #expect(!saysCross || wp.say.localizedCaseInsensitiveContains("no crossing"),
                    "waypoint \(wp.id) mentions crossing but is not flagged")
        }
    }
    #expect(r.waypoints[2].placeName == "Goodwin Avenue")
    // Every waypoint has a short spoken name (used in "Passed …" and "Next, … in N meters").
    for wp in r.waypoints {
        #expect(wp.name != nil && wp.placeName.count <= 30, "waypoint \(wp.id) needs a short name")
    }
    #expect(r.bearingInconsistencies(tolerance: 15).isEmpty)
    // Consecutive waypoints are between 20 m and 300 m apart (no duplicates, no teleports).
    for (a, b) in zip(r.waypoints, r.waypoints.dropFirst()) {
        let d = GeoMath.distanceMeters(a.coordinate, b.coordinate)
        #expect(d > 20 && d < 300, "waypoint \(a.id)→\(b.id) is \(Int(d)) m apart")
    }
    let total = zip(r.waypoints, r.waypoints.dropFirst())
        .reduce(0.0) { $0 + GeoMath.distanceMeters($1.0.coordinate, $1.1.coordinate) }
    #expect(total > 700 && total < 1300)
}

@Test func bearingConsistencyCheckCatchesTypos() {
    let good = Route(name: "g", waypoints: [
        Waypoint(id: 1, lat: b.latitude, lon: b.longitude, radiusM: 15, say: "", crossing: false,
                 bearingNextDeg: GeoMath.bearingDegrees(from: b, to: c) + 5),
        Waypoint(id: 2, lat: c.latitude, lon: c.longitude, radiusM: 15, say: "", crossing: false, bearingNextDeg: nil),
    ])
    #expect(good.bearingInconsistencies().isEmpty)
    let bad = Route(name: "b", waypoints: [
        Waypoint(id: 1, lat: b.latitude, lon: b.longitude, radiusM: 15, say: "", crossing: false, bearingNextDeg: 180),
        Waypoint(id: 2, lat: c.latitude, lon: c.longitude, radiusM: 15, say: "", crossing: false, bearingNextDeg: nil),
    ])
    #expect(bad.bearingInconsistencies().map(\.id) == [1])
}
