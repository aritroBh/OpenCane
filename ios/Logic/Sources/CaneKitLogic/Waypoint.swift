//
//  Waypoint.swift
//  CaneKitLogic
//
//  Route file schema (ios/CaneKit/Resources/route_isr_cif.json) and the MapKit-steps → waypoints
//  converter (works on a plain struct so the package stays MapKit-free).
//
//  Purpose: one waypoint model shared by the hand-recorded demo route (ISR Townsend Hall → CIF)
//  and routes built from MapKit walking directions, so `GeofenceTracker`, `TurnSettle` and the
//  speech lines never care where a route came from. `RouteSource` (app) loads / builds these.
//
//  Key invariants:
//    · `CodingKeys` are the on-disk JSON schema (snake_case `radius_m`, `bearing_next_deg`);
//      renaming them breaks the shipped route file.
//    · `bearing_next_deg` and `curved` and `name` are optional in JSON; everything else is
//      required. The last waypoint has no `bearing_next_deg`.
//    · Units: `lat` / `lon` degrees, `radiusM` metres, bearings degrees clockwise from true north.
//    · Built routes use 15 m fences (20 m for arrival); the recorded route uses 12 m on turns.
//  Tests: RouteTests.swift (`mapKitStepsBecomeWaypoints`, `routeFileDecodesSnakeCaseSchema`,
//  `shippedRouteFileIsConsistent`, `bearingConsistencyCheckCatchesTypos`).
//

import Foundation

/// One geofenced point on a route: where it is, how big its fence is, what to say on entry and
/// which way the next leg goes. Pinned by `routeFileDecodesSnakeCaseSchema`, `shippedRouteFileIsConsistent`.
public struct Waypoint: Sendable, Equatable, Codable, Identifiable {
    /// 1-based position in the route (the shipped file uses `1...n` in order).
    public var id: Int
    /// Latitude, degrees.
    public var lat: Double
    /// Longitude, degrees.
    public var lon: Double
    /// Fence radius in metres (JSON `radius_m`). Entry fires up to this far before the corner.
    public var radiusM: Double
    /// Spoken once when the geofence is entered.
    public var say: String
    /// True when the user must cross a street here: the beacon is silent while settling and the
    /// line should say "Crossing".
    public var crossing: Bool
    /// Bearing to walk after this waypoint, degrees true. nil on the last waypoint.
    public var bearingNextDeg: Double?
    /// The leg *after* this waypoint is not a straight line (e.g. "covered walk south, then the
    /// path west"): the chord bearing would be wrong, so no veer cues and the beacon stays quiet
    /// on that leg — the spoken line guides. Optional in JSON (`"curved": true`), default false.
    public var curved: Bool
    /// Short spoken name ("Goodwin Avenue") for "Passed …" / "Next, … in N meters". Optional in
    /// JSON (`"name"`); falls back to the first sentence of `say`.
    public var name: String?

    /// The route-file JSON keys (on-disk schema; see the file header).
    enum CodingKeys: String, CodingKey {
        case id, lat, lon, say, crossing, curved, name
        case radiusM = "radius_m"
        case bearingNextDeg = "bearing_next_deg"
    }

    /// Memberwise initialiser used by `RouteBuilder` and the tests.
    /// - Parameters:
    ///   - radiusM: fence radius, metres.
    ///   - bearingNextDeg: next leg's bearing, degrees true; nil for the last waypoint.
    ///   - curved: next leg is not straight (mutes veer cues and the beacon on it).
    ///   - name: short spoken place name; nil → first sentence of `say`.
    public init(id: Int, lat: Double, lon: Double, radiusM: Double, say: String, crossing: Bool,
                bearingNextDeg: Double?, curved: Bool = false, name: String? = nil) {
        self.id = id
        self.lat = lat
        self.lon = lon
        self.radiusM = radiusM
        self.say = say
        self.crossing = crossing
        self.bearingNextDeg = bearingNextDeg
        self.curved = curved
        self.name = name
    }

    /// Decodes the route-file schema; `bearing_next_deg`, `curved` (→ false) and `name` may be
    /// absent. Encoding is synthesized. Pinned by `routeFileDecodesSnakeCaseSchema`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
        radiusM = try c.decode(Double.self, forKey: .radiusM)
        say = try c.decode(String.self, forKey: .say)
        crossing = try c.decode(Bool.self, forKey: .crossing)
        bearingNextDeg = try c.decodeIfPresent(Double.self, forKey: .bearingNextDeg)
        curved = try c.decodeIfPresent(Bool.self, forKey: .curved) ?? false
        name = try c.decodeIfPresent(String.self, forKey: .name)
    }

    /// `lat` / `lon` as a `Coordinate` for `GeoMath`.
    public var coordinate: Coordinate { Coordinate(latitude: lat, longitude: lon) }

    /// Spoken place name: `name` when set, else the first sentence of the spoken line.
    /// Pinned by `shippedRouteFileIsConsistent` (`waypoints[2].placeName == "Goodwin Avenue"`).
    public var placeName: String {
        if let name, !name.isEmpty { return name }
        let first = say.split(separator: ".", maxSplits: 1).first.map(String.init) ?? say
        return first.trimmingCharacters(in: .whitespaces)
    }
}

/// A named, ordered waypoint list — the top-level object of the route JSON file.
public struct Route: Sendable, Equatable, Codable {
    /// Human-readable route name ("ISR to CIF").
    public var name: String
    /// Waypoints in walking order; the last one is the arrival fence.
    public var waypoints: [Waypoint]
    /// Creates a route from a name and waypoints in walking order.
    public init(name: String, waypoints: [Waypoint]) {
        self.name = name
        self.waypoints = waypoints
    }

    /// Decodes a route JSON file.
    /// - Parameter data: the file contents.
    /// - Throws: `DecodingError` when a required key is missing or mistyped.
    /// Pinned by `routeFileDecodesSnakeCaseSchema`, `shippedRouteFileIsConsistent`.
    public static func load(from data: Data) throws -> Route {
        try JSONDecoder().decode(Route.self, from: data)
    }

    /// Sanity check for hand-edited files: every recorded `bearing_next_deg` must be within
    /// `tolerance` degrees of the geometric bearing to the next waypoint.
    /// - Parameter tolerance: allowed disagreement, degrees (default 15°).
    /// - Returns: one entry per offending waypoint (id, recorded °, geometric °); empty = consistent.
    /// Pinned by `bearingConsistencyCheckCatchesTypos`, `shippedRouteFileIsConsistent`.
    public func bearingInconsistencies(tolerance: Double = 15) -> [(id: Int, recorded: Double, geometric: Double)] {
        var out: [(Int, Double, Double)] = []
        for (i, wp) in waypoints.enumerated() where i + 1 < waypoints.count {
            guard let rec = wp.bearingNextDeg else { continue }
            let geo = GeoMath.bearingDegrees(from: wp.coordinate, to: waypoints[i + 1].coordinate)
            if abs(GeoMath.wrap180(rec - geo)) > tolerance { out.append((wp.id, rec, geo)) }
        }
        return out
    }
}

/// One MapKit walking step, reduced to what the converter needs.
public struct RouteStepInput: Sendable, Equatable {
    /// The step's polyline points in order (may be empty for MapKit's first "start" step).
    public var points: [Coordinate]
    /// MapKit's instruction text for this step ("Turn left onto Springfield Ave").
    public var instructions: String
    /// Creates a step from its polyline points and instruction text.
    public init(points: [Coordinate], instructions: String) {
        self.points = points
        self.instructions = instructions
    }
}

/// Converts MapKit walking directions into route waypoints (any destination, not just the demo).
public enum RouteBuilder {
    /// Converts MapKit steps into the same waypoint list the recorded route uses:
    /// a waypoint at the end of each step, spoken with the *next* step's instruction,
    /// `crossing` when that instruction mentions crossing, radius 15 m (20 m for arrival).
    /// - Parameters:
    ///   - steps: MapKit steps in order; steps with no points are dropped.
    ///   - destinationName: used in the last line, "Arrived at <destinationName>."
    /// - Returns: waypoints with ids `1...n`; empty instructions become "Continue."; the last has
    ///   no bearing; `curved` is always false. Pinned by `mapKitStepsBecomeWaypoints`.
    public static func waypoints(from steps: [RouteStepInput], destinationName: String = "destination") -> [Waypoint] {
        let usable = steps.filter { !$0.points.isEmpty }
        var out: [Waypoint] = []
        for (i, step) in usable.enumerated() {
            let end = step.points[step.points.count - 1]
            let isLast = i == usable.count - 1
            let nextInstruction = isLast ? "Arrived at \(destinationName)." : usable[i + 1].instructions
            let say = nextInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
            let crossing = say.range(of: "cross", options: .caseInsensitive) != nil
            let bearing: Double? = isLast ? nil : GeoMath.bearingDegrees(from: end, to: usable[i + 1].points.last!)
            out.append(Waypoint(id: i + 1, lat: end.latitude, lon: end.longitude,
                                radiusM: isLast ? 20 : 15,
                                say: say.isEmpty ? "Continue." : say,
                                crossing: crossing, bearingNextDeg: bearing))
        }
        return out
    }
}
