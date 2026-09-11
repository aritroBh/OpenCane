//
//  Waypoint.swift
//  CaneKitLogic
//
//  Route file schema (ios/CaneKit/Resources/route_isr_cif.json) and the MapKit-steps → waypoints
//  converter (works on a plain struct so the package stays MapKit-free).
//

import Foundation

public struct Waypoint: Sendable, Equatable, Codable, Identifiable {
    public var id: Int
    public var lat: Double
    public var lon: Double
    public var radiusM: Double
    /// Spoken once when the geofence is entered.
    public var say: String
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

    enum CodingKeys: String, CodingKey {
        case id, lat, lon, say, crossing, curved, name
        case radiusM = "radius_m"
        case bearingNextDeg = "bearing_next_deg"
    }

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

    public var coordinate: Coordinate { Coordinate(latitude: lat, longitude: lon) }

    /// Spoken place name: `name` when set, else the first sentence of the spoken line.
    public var placeName: String {
        if let name, !name.isEmpty { return name }
        let first = say.split(separator: ".", maxSplits: 1).first.map(String.init) ?? say
        return first.trimmingCharacters(in: .whitespaces)
    }
}

public struct Route: Sendable, Equatable, Codable {
    public var name: String
    public var waypoints: [Waypoint]
    public init(name: String, waypoints: [Waypoint]) {
        self.name = name
        self.waypoints = waypoints
    }

    public static func load(from data: Data) throws -> Route {
        try JSONDecoder().decode(Route.self, from: data)
    }

    /// Sanity check for hand-edited files: every recorded `bearing_next_deg` must be within
    /// `tolerance` degrees of the geometric bearing to the next waypoint.
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
    public var points: [Coordinate]
    public var instructions: String
    public init(points: [Coordinate], instructions: String) {
        self.points = points
        self.instructions = instructions
    }
}

public enum RouteBuilder {
    /// Converts MapKit steps into the same waypoint list the recorded route uses:
    /// a waypoint at the end of each step, spoken with the *next* step's instruction,
    /// `crossing` when that instruction mentions crossing, radius 15 m (20 m for arrival).
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
