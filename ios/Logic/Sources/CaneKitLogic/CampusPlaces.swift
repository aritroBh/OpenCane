//
//  CampusPlaces.swift
//  CaneKitLogic
//
//  Where "take me to …" goes. Three pure pieces the app's `RouteSource` uses before and after
//  MapKit:
//    · `CampusPlaces` — a small UIUC gazetteer (CIF, ISR / Townsend Hall, Grainger, Illini Union,
//      Siebel, Main Library, ARC) mapping spoken / typed aliases to an entrance coordinate. It is
//      checked before any MapKit search: MKLocalSearch's answer for "Grainger" on the phone was
//      a supply store, and "CIF" matched nothing useful.
//    · `DestinationPicker` — when the gazetteer has no match, choose the nearest reasonable
//      MKLocalSearch result (inside walking range, name matching the query preferred) instead of
//      MapKit's first one.
//    · `WalkingIntro` — the line spoken before the route starts ("Walking to Grainger
//      Engineering Library, 750 meters.") so a blind walker hears what was chosen and can say
//      Stop if it is wrong.
//
//  Owner: called by `RouteSource.mapKit(to:from:)` / `RouteSource.walking(to:from:)` and
//  `AppModel.beginRoute(_:announce:)` in the app; the app's `CampusDestination` AppEnum
//  (AppIntents.swift) uses the place ids as raw values.
//
//  Key invariants:
//    · Foundation only (no MapKit / CoreLocation): candidates arrive as `PlaceCandidate`.
//    · Matching is whole-alias only after `normalize` (case, accents, punctuation, "the", "and"
//      ignored). No fuzzy or partial matching: "Grainger Street" must go to MapKit.
//    · ⚠ CIF and ISR coordinates are the last / first waypoint of route_isr_cif.json
//      (`gazetteerEndpointsAreTheRouteFileEntrances`). The other entrances are OSM entrance nodes
//      queried 2026-09-11 and have NOT been walked: verify on site.
//    · ⚠ The ids are the raw values of the app's `CampusDestination` AppEnum
//      (`campusPlaceIdsArePinned`): rename both together.
//  Tests: CampusPlacesTests.swift.
//

import Foundation

/// One campus destination: a spoken name, the entrance to walk to and the names people use.
public struct CampusPlace: Sendable, Equatable, Identifiable {
    /// Stable key; also the raw value of the app's `CampusDestination` AppEnum (Siri phrases).
    public let id: String
    /// Spoken / shown name ("Grainger Engineering Library"); becomes the route name
    /// "To <name>" and the arrival line "Arrived at <name>."
    public let name: String
    /// The entrance a walking route should end at (WGS-84).
    public let coordinate: Coordinate
    /// Everything that should match this place, compared after `CampusPlaces.normalize`.
    public let aliases: [String]

    /// Creates a gazetteer entry; only `CampusPlaces.all` (and tests) build these.
    public init(id: String, name: String, coordinate: Coordinate, aliases: [String]) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.aliases = aliases
    }
}

/// The campus gazetteer, checked before any MapKit search (`RouteSource.mapKit(to:from:)`).
/// Pinned by `campusAliasesIgnoreCasePunctuationAndThe`, `everyCampusPlaceAnswersToItsAliases`,
/// `unknownOrPartialNamesFallThroughToMapKit`, `gazetteerEndpointsAreTheRouteFileEntrances`,
/// `everyCampusPlaceIsOnCampusAndAliasesAreUnique`, `campusPlaceIdsArePinned`.
public enum CampusPlaces {

    /// Every known place, in the order the app's AppEnum lists them.
    /// Sources: CIF / ISR = route_isr_cif.json waypoints 9 / 1; the rest are OpenStreetMap
    /// entrance nodes (Overpass, queried 2026-09-11), verify on site before relying on them.
    public static let all: [CampusPlace] = [
        CampusPlace(id: "cif", name: "the CIF east entrance",
                    // route_isr_cif.json WP9 (the demo route's arrival point).
                    coordinate: Coordinate(latitude: 40.11242, longitude: -88.22788),
                    aliases: ["CIF", "Campus Instructional Facility", "CIF east entrance",
                              "Campus Instructional Facility east entrance"]),
        CampusPlace(id: "isr", name: "the Townsend Hall doors",
                    // route_isr_cif.json WP1 (OSM entrance node 5418851678, ISR south vestibule).
                    coordinate: Coordinate(latitude: 40.10949, longitude: -88.22135),
                    aliases: ["ISR", "Townsend", "Townsend Hall", "ISR Townsend Hall",
                              "Illinois Street Residence Hall", "Illinois Street Residence Halls"]),
        CampusPlace(id: "grainger", name: "Grainger Engineering Library",
                    // OSM entrance node 5296014632, Springfield Avenue side. Verify on site.
                    coordinate: Coordinate(latitude: 40.1125612, longitude: -88.2272830),
                    aliases: ["Grainger", "Grainger Library", "Grainger Engineering Library",
                              "Grainger Engineering Library Information Center"]),
        CampusPlace(id: "illiniUnion", name: "the Illini Union",
                    // OSM entrance node 5399191831 (entrance=main), Green Street side. Verify on site.
                    coordinate: Coordinate(latitude: 40.1098522, longitude: -88.2272312),
                    aliases: ["Illini Union", "Union", "Student Union", "Illini Student Union"]),
        CampusPlace(id: "siebel", name: "the Siebel Center",
                    // OSM entrance node 5427072676 (entrance=main), Goodwin Avenue side. Verify on site.
                    coordinate: Coordinate(latitude: 40.1141046, longitude: -88.2243039),
                    aliases: ["Siebel", "Siebel Center", "Siebel Center for Computer Science",
                              "Thomas Siebel Center", "Thomas M Siebel Center for Computer Science"]),
        CampusPlace(id: "mainLibrary", name: "the Main Library",
                    // OSM entrance node 12981484012, Gregory Drive side. Verify on site.
                    coordinate: Coordinate(latitude: 40.1043031, longitude: -88.2287797),
                    aliases: ["Main Library", "Main Stacks", "University Library", "UIUC Main Library"]),
        CampusPlace(id: "arc", name: "the Activities and Recreation Center",
                    // OSM entrance node 10030491837 (entrance=main), Peabody Drive side. Verify on site.
                    coordinate: Coordinate(latitude: 40.1012749, longitude: -88.2360184),
                    aliases: ["ARC", "Activities and Recreation Center", "ARC gym"]),
    ]

    /// Words dropped wherever they appear: "the CIF" = "CIF", "Activities & Recreation" =
    /// "Activities and Recreation" (the ampersand becomes a space).
    static let fillerWords: Set<String> = ["the", "and"]

    /// The place whose alias equals `query` after `normalize`, or nil (then MapKit searches).
    /// Whole-alias matches only. Called by `RouteSource.mapKit(to:from:)` before MKLocalSearch.
    public static func match(_ query: String) -> CampusPlace? {
        let key = normalize(query)
        guard !key.isEmpty else { return nil }
        return all.first { place in place.aliases.contains { normalize($0) == key } }
    }

    /// The entry with this id (the app's `CampusDestination.rawValue`), or nil.
    public static func place(id: String) -> CampusPlace? {
        all.first { $0.id == id }
    }

    /// Comparable form of a place name: lower case, accents folded, dots and apostrophes removed
    /// ("C.I.F." → "cif"), every other non-alphanumeric character a space, `fillerWords` dropped,
    /// single spaces. Also used by `DestinationPicker` for its name match.
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        var cleaned = ""
        for ch in folded {
            if ch == "." || ch == "'" || ch == "\u{2019}" { continue }
            cleaned.append(ch.isLetter || ch.isNumber ? ch : " ")
        }
        return cleaned.split(separator: " ").map(String.init)
            .filter { !fillerWords.contains($0) }
            .joined(separator: " ")
    }
}

/// One MKLocalSearch result reduced to what the picker needs (the app builds these).
public struct PlaceCandidate: Sendable, Equatable {
    /// The result's name ("Grainger Engineering Library", or an address line).
    public var name: String
    /// Where the result is.
    public var coordinate: Coordinate
    /// Creates a candidate from a MapKit result's name and coordinate.
    public init(name: String, coordinate: Coordinate) {
        self.name = name
        self.coordinate = coordinate
    }
}

/// Chooses which MKLocalSearch result to walk to (MapKit's first result was often far away).
/// Pinned by `searchPicksTheNearestReasonableResult`, `nameMatchesBeatNearerUnrelatedResults`,
/// `nothingWithinWalkingRangeIsNotFound`.
public enum DestinationPicker {
    /// Straight-line walking range, metres: anything farther is not a CaneKit walk, so it counts
    /// as "not found" rather than a 40 km route to a same-named store in another town. Matches
    /// the 3 km search radius `RouteSource` gives MKLocalSearch.
    public static let maxDistanceM: Double = 3000

    /// Index of the result to walk to, or nil when none is within `maxDistanceM` of `origin`.
    /// Rule: among the results in range, those whose name contains every word of `query`
    /// (after `CampusPlaces.normalize`) are preferred; the nearest preferred one wins, else the
    /// nearest one in range (a typed address rarely matches MapKit's spelling of it).
    /// Called by `RouteSource.mapKit(to:from:)`.
    public static func pick(_ candidates: [PlaceCandidate], near origin: Coordinate, query: String,
                            maxDistanceM: Double = maxDistanceM) -> Int? {
        let words = CampusPlaces.normalize(query).split(separator: " ").map(String.init)
        let inRange = candidates.indices
            .map { (index: $0, distance: GeoMath.distanceMeters(origin, candidates[$0].coordinate)) }
            .filter { $0.distance <= maxDistanceM }
        let named = inRange.filter { c in
            let nameWords = Set(CampusPlaces.normalize(candidates[c.index].name).split(separator: " ").map(String.init))
            return !words.isEmpty && words.allSatisfy(nameWords.contains)
        }
        let pool = named.isEmpty ? inRange : named
        return pool.min { $0.distance < $1.distance }?.index
    }
}

/// The confirmation spoken before a MapKit route starts, so a wrong pick can be stopped.
/// Pinned by `walkingIntroSaysThePlaceAndARoundedDistance`.
public enum WalkingIntro {
    /// "Walking to <place>, <distance>." — or "Walking to <place>." when the distance is unknown.
    /// Called by `AppModel.buildRoute` with `PlannedRoute.placeName` / `walkingMeters`.
    public static func line(place: String, meters: Double) -> String {
        guard let d = distancePhrase(meters) else { return "Walking to \(place)." }
        return "Walking to \(place), \(d)."
    }

    /// Nearest 10 m below a kilometre (at least "10 meters", never "0"), tenths of a kilometre
    /// from there ("1 kilometer", "1.2 kilometers"); nil for a negative or non-finite distance.
    static func distancePhrase(_ meters: Double) -> String? {
        guard meters.isFinite, meters >= 0 else { return nil }
        let tens = (meters / 10).rounded() * 10
        if tens < 1000 { return "\(max(10, Int(tens))) meters" }
        let km = (meters / 100).rounded() / 10
        if km == km.rounded() {
            let whole = Int(km)
            return whole == 1 ? "1 kilometer" : "\(whole) kilometers"
        }
        return String(format: "%.1f kilometers", km)
    }
}
