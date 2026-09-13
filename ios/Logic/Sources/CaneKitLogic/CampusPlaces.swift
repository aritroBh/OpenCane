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
//      Also `routeStarted` (Step 54; Step 68 wording "Route to <destination>. <first line>"): the intro, built once
//      for both `NavigationEngine.start` (speaks it) and `AppModel` (prefetches it).
//
//  Owner / callers (all in the app, all main actor; every type here is a stateless value):
//    · `RouteSource.mapKit(to:from:)` — `CampusPlaces.match` first, then `DestinationPicker.pick`
//      over the MKLocalSearch results (reached through `RouteSource.walking(to:from:)`).
//    · `AppModel.buildRoute(to:searchLine:)` — `WalkingIntro.line(place:meters:accuracyM:)`, the
//      announcement it hands to `AppModel.beginRoute(_:announce:)`.
//    · `DestinationSuggestions` (Logic), `DestinationSearch` and `DestinationField` —
//      `CampusPlaces.all` / `normalize` / `place(id:)` / `center` for the as-you-type list.
//    · `FastPathIntentClassifier` (Logic) — "take me to …" matched against `all` by alias.
//    · The app's `CampusDestination` AppEnum (AppIntents.swift) uses the place ids as raw values;
//      `TakeMeToIntent` resolves a case with `CampusPlaces.place(id:)`.
//
//  Key invariants:
//    · Foundation only (no MapKit / CoreLocation): candidates arrive as `PlaceCandidate`.
//    · Matching is whole-alias only after `normalize` (case, accents, punctuation, "the", "and"
//      ignored). No fuzzy or partial matching: "Grainger Street" must go to MapKit. Recogniser
//      mishearings are added as exact aliases instead ("Granger Library", "C I F"; Step 67).
//    · ⚠ CIF and ISR coordinates are the last / first waypoint of route_isr_cif.json
//      (`gazetteerEndpointsAreTheRouteFileEntrances`). The other entrances are OSM entrance nodes
//      queried 2026-09-11 and have NOT been walked: verify on site.
//    · Every `name` is itself an alias (`everyCampusPlaceNameRoundTripsThroughMatch`, Step 62).
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
    /// ⚠ `FastPathIntentClassifier` hands this *name* (not the id) to `AppModel.navigate(to:)`,
    /// which runs `match` on it again, so every name must normalize onto one of its own aliases
    /// (`everyCampusPlaceNameRoundTripsThroughMatch`). Until Step 62 "the Townsend Hall doors" did
    /// not, and "take me to Townsend Hall" searched MapKit instead of walking to the route file's WP1;
    /// the alias "Townsend Hall doors" fixed it ("the" is dropped by `normalize`).
    public let name: String
    /// The entrance a walking route should end at (WGS-84).
    public let coordinate: Coordinate
    /// Everything that should match this place, compared after `CampusPlaces.normalize`. Also the
    /// partial-match pool for `DestinationSuggestions.campusMatches` and the duplicate filter for
    /// its MapKit rows. ⚠ No alias may belong to two places
    /// (`everyCampusPlaceIsOnCampusAndAliasesAreUnique`): `match` returns the first hit.
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
/// `everyCampusPlaceIsOnCampusAndAliasesAreUnique`, `campusPlaceIdsArePinned`,
/// `everyCampusPlaceNameRoundTripsThroughMatch`.
public enum CampusPlaces {

    /// Every known place, in the order the app's AppEnum lists them.
    /// Sources: CIF / ISR = route_isr_cif.json waypoints 9 / 1; the rest are OpenStreetMap
    /// entrance nodes (Overpass, queried 2026-09-11), verify on site before relying on them.
    public static let all: [CampusPlace] = [
        CampusPlace(id: "cif", name: "the CIF east entrance",
                    // route_isr_cif.json WP9 (the demo route's arrival point).
                    coordinate: Coordinate(latitude: 40.11242, longitude: -88.22788),
                    // "CIF building", "C I F", "see eye eff": how the recogniser writes "CIF" (Step 67).
                    aliases: ["CIF", "Campus Instructional Facility", "CIF east entrance",
                              "Campus Instructional Facility east entrance",
                              "CIF building", "C I F", "see eye eff"]),
        CampusPlace(id: "isr", name: "the Townsend Hall doors",
                    // route_isr_cif.json WP1 (OSM entrance node 5418851678, ISR south vestibule).
                    coordinate: Coordinate(latitude: 40.10949, longitude: -88.22135),
                    // "Townsend Hall doors" (Step 62) is the spoken name itself, so `match(name)` round-trips.
                    aliases: ["ISR", "Townsend", "Townsend Hall", "ISR Townsend Hall",
                              "Illinois Street Residence Hall", "Illinois Street Residence Halls",
                              "Townsend Hall doors"]),
        CampusPlace(id: "grainger", name: "Grainger Engineering Library",
                    // OSM entrance node 5296014632, Springfield Avenue side. Verify on site.
                    coordinate: Coordinate(latitude: 40.1125612, longitude: -88.2272830),
                    // "Granger" is the common speech-recognition mishearing of "Grainger"
                    // (phone log 2026-09-13T15-48-34Z: "… to Granger library"). Step 67 adds the
                    // longer mishearings. ⚠ Not "library" alone: that is also the Main Library.
                    aliases: ["Grainger", "Grainger Library", "Grainger Engineering Library",
                              "Grainger Engineering Library Information Center",
                              "Granger", "Granger Library", "Granger Engineering Library",
                              "Grainger Engineering",
                              // Review round Steps 67–68 (Muse #9): compound mishearings.
                              "Granger Engineering", "Granger Building", "Grainger Building"]),
        CampusPlace(id: "illiniUnion", name: "the Illini Union",
                    // OSM entrance node 5399191831 (entrance=main), Green Street side. Verify on site.
                    coordinate: Coordinate(latitude: 40.1098522, longitude: -88.2272312),
                    aliases: ["Illini Union", "Union", "Student Union", "Illini Student Union"]),
        CampusPlace(id: "siebel", name: "the Siebel Center",
                    // OSM entrance node 5427072676 (entrance=main), Goodwin Avenue side. Verify on site.
                    coordinate: Coordinate(latitude: 40.1141046, longitude: -88.2243039),
                    // "Sift" is the common speech-recognition mishearing of "Siebel".
                    aliases: ["Siebel", "Siebel Center", "Siebel Center for Computer Science",
                              "Thomas Siebel Center", "Thomas M Siebel Center for Computer Science",
                              "Sift", "Sift Center"]),
        CampusPlace(id: "mainLibrary", name: "the Main Library",
                    // OSM entrance node 12981484012, Gregory Drive side. Verify on site.
                    coordinate: Coordinate(latitude: 40.1043031, longitude: -88.2287797),
                    aliases: ["Main Library", "Main Stacks", "University Library", "UIUC Main Library"]),
        CampusPlace(id: "arc", name: "the Activities and Recreation Center",
                    // OSM entrance node 10030491837 (entrance=main), Peabody Drive side. Verify on site.
                    coordinate: Coordinate(latitude: 40.1012749, longitude: -88.2360184),
                    aliases: ["ARC", "Activities and Recreation Center", "ARC gym"]),
    ]

    /// The mean of every entrance above: "campus", for the one job that needs a point and has no
    /// GPS fix — biasing `MKLocalSearchCompleter`'s region while the walker types on the idle
    /// screen (GPS only runs during a route, design.md §6.1). It is never used as a distance
    /// origin: a distance from a guessed origin would be a made-up number.
    /// Callers: `DestinationSearch` (region centre when `origin` is nil). Pinned by
    /// `campusCentreIsWithinWalkingRangeOfEveryPlace` (DestinationSuggestionsTests.swift).
    public static let center: Coordinate = Coordinate(
        latitude: all.reduce(0) { $0 + $1.coordinate.latitude } / Double(all.count),
        longitude: all.reduce(0) { $0 + $1.coordinate.longitude } / Double(all.count))

    /// Words dropped wherever they appear: "the CIF" = "CIF", "Activities & Recreation" =
    /// "Activities and Recreation" (the ampersand becomes a space). Internal; read only by
    /// `normalize`. Pinned by `campusAliasesIgnoreCasePunctuationAndThe`.
    static let fillerWords: Set<String> = ["the", "and"]

    /// The place whose alias equals `query` after `normalize`, or nil (then MapKit searches).
    /// Whole-alias matches only. Called by `RouteSource.mapKit(to:from:)` before MKLocalSearch.
    public static func match(_ query: String) -> CampusPlace? {
        let key = normalize(query)
        guard !key.isEmpty else { return nil }
        return all.first { place in place.aliases.contains { normalize($0) == key } }
    }

    /// The entry with this id (the app's `CampusDestination.rawValue`), or nil. Callers:
    /// `TakeMeToIntent.perform`, `DestinationField` (a tapped campus row), `DestinationSuggestions.mapRows`.
    public static func place(id: String) -> CampusPlace? {
        all.first { $0.id == id }
    }

    /// Comparable form of a place name: lower case, accents folded, dots and apostrophes removed
    /// ("C.I.F." → "cif"), every other non-alphanumeric character a space, `fillerWords` dropped,
    /// single spaces. Also used by `DestinationPicker` for its name match, by
    /// `DestinationSuggestions` (and the app's `DestinationSearch` / `DestinationField`) for the
    /// minimum query length, and by `FastPathIntentClassifier` for its gazetteer lookup.
    /// A query that is only filler or punctuation ("the", "?") normalizes to "".
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

/// One MKLocalSearch result reduced to what the picker needs. Built by `RouteSource.mapKit(to:from:)`
/// from each `MKMapItem` (Foundation-only here, so the picker is testable without MapKit).
public struct PlaceCandidate: Sendable, Equatable {
    /// The result's name ("Grainger Engineering Library", or an address line); the app falls back
    /// to the typed query when MapKit gives no name. Becomes the route's place name when picked.
    public var name: String
    /// Where the result is (WGS-84, the map item's location).
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
    /// - Parameters:
    ///   - candidates: MapKit's results in MapKit's order (the order is ignored).
    ///   - origin: the walker's GPS fix — never a guessed point (no distance from `CampusPlaces.center`).
    ///   - query: what the walker typed or said; an empty query prefers nothing.
    ///   - maxDistanceM: straight-line range in metres (default `DestinationPicker.maxDistanceM`).
    /// - Returns: an index into `candidates`, or nil (the app then throws `destinationNotFound`).
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
    /// GPS horizontal accuracy (m) worse than this means the fix was probably taken indoors,
    /// so the route's first steps are meaningless until the walker is outside. Pinned by
    /// `weakGpsAddsAnExitFirstClause`.
    public static let weakAccuracyM = 25.0

    /// "Walking to <place>, <distance>." — or "Walking to <place>." when the distance is unknown.
    /// With a weak fix, appends an exit-first clause: MapKit's first steps from a bad fix point
    /// nowhere real, and a blind walker starting inside needs the building exit before any turn.
    /// Worded conditionally — weak GPS also happens in urban canyons, not only indoors.
    /// Called by `AppModel.buildRoute` with `PlannedRoute.placeName` / `walkingMeters` /
    /// the fix accuracy.
    /// - Parameters:
    ///   - place: the spoken place name (gazetteer `name` or the picked MapKit name).
    ///   - meters: MapKit's walking distance; negative / non-finite → no distance clause.
    ///   - accuracyM: horizontal accuracy (m) of the fix the route was planned from; nil, non-finite
    ///     or ≤ `weakAccuracyM` adds nothing. The weak clause is only added when a distance is spoken.
    public static func line(place: String, meters: Double, accuracyM: Double? = nil) -> String {
        guard let d = distancePhrase(meters) else { return "Walking to \(place)." }
        guard let accuracy = accuracyM, accuracy.isFinite, accuracy > weakAccuracyM else {
            return "Walking to \(place), \(d)."
        }
        return "Walking to \(place), \(d). GPS is weak. If you are inside, head for the exit first."
    }

    /// The route intro, "Route to <destination>. <first waypoint's line>" (Step 68; Step 54 said
    /// "Route started. <route name>. First: <line>" — 200 characters on the demo route, now 159).
    ///
    /// Why one function: `NavigationEngine.start` speaks it and `AppModel` prefetches it into the
    /// natural-voice cache (`queueRouteStart` during the depth wait, `buildRoute` as soon as MapKit
    /// answers, `startRouteNow` for the degraded paths). The cache is keyed by exact bytes; the
    /// old copy of this string in `startRouteNow` was prefetched a moment before the engine spoke
    /// it, so on a cold cache the first line of every route came out in the system voice.
    /// The waypoint's `say` is the route file's text and is not shortened here.
    /// Pinned by `introLineIsWhatNavigationSpeaks`, `introNamesTheDestinationNotTheRoute`.
    /// - Parameter route: the route about to start; an empty route is just "Route to <name>." (the
    ///   engine still speaks it before the first fix).
    public static func routeStarted(_ route: Route) -> String {
        routeStarted(destination: destinationName(route), firstLine: route.waypoints.first?.say ?? "")
    }

    /// The intro from its two parts; `routeStarted(_:)` is the production entry.
    /// - Parameters:
    ///   - destination: `destinationName(_:)`.
    ///   - firstLine: the first waypoint's `say`, or "" (then no trailing space).
    public static func routeStarted(destination: String, firstLine: String) -> String {
        let head = "Route to \(destination)."
        let first = firstLine.trimmingCharacters(in: .whitespaces)
        return first.isEmpty ? head : "\(head) \(first)"
    }

    /// The spoken destination of a route: MapKit's "To <name>" → "<name>"; a hand-named
    /// "<origin> to <destination>" ("ISR Townsend Hall to CIF") → the part after the last " to ";
    /// otherwise the last waypoint's place name; otherwise the route name. A trailing full stop is
    /// dropped so the intro never says "..". Pinned by `introNamesTheDestinationNotTheRoute`.
    /// - Parameter route: the route about to start.
    public static func destinationName(_ route: Route) -> String {
        let name = route.name.trimmingCharacters(in: .whitespaces)
        var dest: String
        if name.hasPrefix("To ") {
            dest = String(name.dropFirst(3))
        } else if let r = name.range(of: " to ", options: .backwards) {
            dest = String(name[r.upperBound...])
        } else if let last = route.waypoints.last?.placeName, !last.isEmpty {
            dest = last
        } else {
            dest = name
        }
        dest = dest.trimmingCharacters(in: .whitespaces)
        while dest.hasSuffix(".") { dest.removeLast() }
        return dest.isEmpty ? name : dest
    }

    /// Nearest 10 m below a kilometre (at least "10 meters", never "0"), tenths of a kilometre
    /// from there ("1 kilometer", "1.2 kilometers"); nil for a negative or non-finite distance.
    /// Also the spoken distance on a destination-search row (`DestinationSuggestion.voiceOverLabel`),
    /// so the list and the "Walking to …" line round the same way.
    public static func distancePhrase(_ meters: Double) -> String? {
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
