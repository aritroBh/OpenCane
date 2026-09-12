//
//  DestinationSuggestions.swift
//  CaneKitLogic
//
//  What the destination search box offers while the walker types. Two sources, one ranked list:
//    · the campus gazetteer (`CampusPlaces`) — matched on *partial* text, unlike
//      `CampusPlaces.match` which is whole-alias only. These always rank first and are marked
//      as campus places, because MKLocalSearch answers "Grainger" with an industrial supply
//      store in another town and a blind walker cannot see that the wrong row is highlighted.
//    · `MKLocalSearchCompleter` rows, reduced by the app to `CompletionLine` (title + subtitle):
//      Foundation-only here, so the merge, the cap and the ranking are testable without MapKit.
//
//  Owner: `DestinationSearch` (ios/CaneKit/Navigation/DestinationSearch.swift) calls
//  `suggestions(query:completions:from:)` on every debounced keystroke; `DestinationField`
//  (ios/CaneKit/UI) draws the rows and speaks `voiceOverLabel`.
//
//  Key invariants:
//    · Foundation only. No MapKit / CoreLocation (the package must build with Command Line Tools).
//    · ⚠ Campus rows come first and are never pushed out by map rows (`campusPlacesRankFirst`).
//    · ⚠ `debounceSeconds` (0.25) is the only place the keystroke delay is written down; the app
//      reads it rather than repeating the number (`debounceIsAQuarterOfASecond`).
//    · A map row that is only a re-spelling of a gazetteer place is dropped, so the list never
//      shows "Grainger Engineering Library" twice (`mapRowsThatDuplicateACampusPlaceAreDropped`).
//    · A distance is shown **only** when the caller passed a real GPS fix. A completer row carries
//      no coordinate, so map rows never claim a distance (AGENTS.md: never say what we did not
//      measure).
//  Tests: DestinationSuggestionsTests.swift.
//

import Foundation

/// Where a suggestion came from — drives the row's badge and its VoiceOver wording.
public enum DestinationSuggestionKind: String, Sendable, Equatable {
    /// A `CampusPlaces` entry: a hand-verified entrance, ranked first and badged "Campus".
    case campus
    /// An `MKLocalSearchCompleter` row (point of interest or address).
    case map
}

/// One row of the destination search list, ready to draw and to speak.
///
/// Built only by `DestinationSuggestions.suggestions(query:completions:from:)`. `id` is stable
/// for a given row so SwiftUI's `ForEach` does not re-create the button while the list updates.
public struct DestinationSuggestion: Sendable, Equatable, Identifiable {
    /// Stable list identity ("campus:grainger", "map:Espresso Royale|1117 W Oregon St").
    public let id: String
    /// First line: the place name ("Grainger Engineering Library").
    public let title: String
    /// Second line: the address or category MapKit gave, "" when there is none.
    public let subtitle: String
    /// Campus gazetteer row or MapKit row.
    public let kind: DestinationSuggestionKind
    /// `CampusPlace.id` for a campus row, nil for a map row. The app uses it to start the route
    /// through the gazetteer path (`AppModel.navigate(to place:)`) instead of a text search.
    public let placeId: String?
    /// Straight-line metres from the walker, or nil when there is no fix (map rows: always nil).
    public let distanceM: Double?

    /// Creates a row. Only `DestinationSuggestions` (and its tests) build these.
    public init(id: String, title: String, subtitle: String, kind: DestinationSuggestionKind,
                placeId: String? = nil, distanceM: Double? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.placeId = placeId
        self.distanceM = distanceM
    }

    /// The text to hand `AppModel.navigate(to:)` for a map row: the name plus its address line,
    /// which is what makes "Espresso Royale, 1117 W Oregon St" resolve to the right one of five.
    /// (A campus row goes through `placeId` instead and never uses this.)
    public var searchQuery: String {
        subtitle.isEmpty ? title : "\(title), \(subtitle)"
    }

    /// What VoiceOver reads for the row: the name, the campus marker, the distance when it is
    /// known, then the address. A sighted user sees the same four things (title + `detailLine`
    /// + the "Campus" badge). Pinned by `voiceOverLabelNamesTheKindAndTheDistance`.
    public var voiceOverLabel: String {
        var parts = [title]
        if kind == .campus { parts.append("campus place") }
        if let d = distanceM, let phrase = WalkingIntro.distancePhrase(d) { parts.append("\(phrase) away") }
        if !subtitle.isEmpty { parts.append(subtitle) }
        return parts.joined(separator: ", ")
    }

    /// The row's visible second line: the MapKit address for a map row, "On campus" (plus the
    /// short distance when a fix gave us one) for a gazetteer row. Empty when there is nothing
    /// to add, and then the view draws one line only.
    /// Pinned by `detailLineShowsTheAddressOrTheCampusDistance`.
    public var detailLine: String {
        guard kind == .campus else { return subtitle }
        guard let d = distanceM, let short = DestinationSuggestions.shortDistance(d) else { return "On campus" }
        return "On campus · \(short)"
    }

    /// VoiceOver hint: tapping a suggestion starts guidance at once, with no second button.
    public var voiceOverHint: String {
        "Starts walking guidance to this place"
    }
}

/// One `MKLocalSearchCompleter` result, reduced to the two strings it actually carries.
///
/// The app builds these inside the completer's `nonisolated` delegate (MapKit's
/// `MKLocalSearchCompletion` is not `Sendable`, these strings are) and hands them here.
public struct CompletionLine: Sendable, Equatable {
    /// The completer's `title` ("Espresso Royale").
    public let title: String
    /// The completer's `subtitle` ("1117 W Oregon St, Urbana, IL"), often "".
    public let subtitle: String
    /// Creates a line from a completer row's two strings.
    public init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }
}

/// Ranking, merging and the three numbers behind the destination search box.
///
/// Pinned by `debounceIsAQuarterOfASecond`, `shortQueriesGetNoSuggestions`,
/// `campusPlacesRankFirst`, `campusMatchingIsPartialUnlikeTheGazetteerLookup`,
/// `nearerCampusPlacesComeFirstWithAFix`, `mapRowsThatDuplicateACampusPlaceAreDropped`,
/// `theListNeverGrowsPastSixRows`, `voiceOverLabelNamesTheKindAndTheDistance`,
/// `announcementCountsTheRows`.
public enum DestinationSuggestions {

    // MARK: Numbers

    /// Seconds to wait after the last keystroke before asking MapKit (and re-ranking).
    /// 0.25 s is about one fast typist's keystroke: it collapses "gra|ing|er" into one request
    /// instead of seven, and is still under the ~0.3 s a person reads as instant.
    /// ⚠ The app must read this constant, never repeat the number.
    public static let debounceSeconds: Double = 0.25

    /// Below this many non-space characters the list stays empty: one letter matches half of
    /// Urbana and a VoiceOver user would hear the row count change for nothing.
    public static let minimumQueryLength: Int = 2

    /// Most rows ever shown. Six is what fits above the keyboard on a 17 Pro Max at the default
    /// text size, and it is a short enough list for VoiceOver to swipe through.
    public static let maxSuggestions: Int = 6

    /// Most campus rows shown, so a gazetteer match can never hide every MapKit answer
    /// (typing "c" would otherwise fill the list with CIF-ish rows).
    public static let maxCampusSuggestions: Int = 3

    // MARK: The list

    /// The ranked list for `query`: campus matches first (nearest first when there is a fix),
    /// then the completer rows in MapKit's own order, deduplicated, capped at `maxSuggestions`.
    ///
    /// - Parameters:
    ///   - query: exactly what the walker has typed.
    ///   - completions: the completer's rows, already reduced to strings (empty before the first
    ///     reply, or when the app has no network).
    ///   - origin: the current GPS fix, or nil when there is none — then no row shows a distance.
    /// - Returns: 0…`maxSuggestions` rows; empty for a query under `minimumQueryLength`.
    public static func suggestions(query: String,
                                   completions: [CompletionLine],
                                   from origin: Coordinate?) -> [DestinationSuggestion] {
        let key = CampusPlaces.normalize(query)
        guard key.count >= minimumQueryLength else { return [] }
        let campus = campusMatches(key, from: origin)
        let map = mapRows(completions, excluding: campus)
        return Array((campus + map).prefix(maxSuggestions))
    }

    /// The gazetteer rows for an already-normalized `key`, best match first.
    ///
    /// Scoring per place (best alias wins): an alias that equals the key beats one that starts
    /// with it, which beats one whose *words* start with it ("union" → "Illini Union"), which
    /// beats one that merely contains it. Ties go to the nearer place when there is a fix, then
    /// to `CampusPlaces.all` order.
    static func campusMatches(_ key: String, from origin: Coordinate?) -> [DestinationSuggestion] {
        let scored: [(place: CampusPlace, score: Int, distance: Double?, order: Int)] =
            CampusPlaces.all.enumerated().compactMap { order, place in
                let best = place.aliases.compactMap { score(alias: CampusPlaces.normalize($0), key: key) }.min()
                guard let best else { return nil }
                let d = origin.map { GeoMath.distanceMeters($0, place.coordinate) }
                return (place, best, d, order)
            }
        return scored
            .sorted { a, b in
                if a.score != b.score { return a.score < b.score }
                if let da = a.distance, let db = b.distance, da != db { return da < db }
                return a.order < b.order
            }
            .prefix(maxCampusSuggestions)
            .map { row in
                DestinationSuggestion(id: "campus:\(row.place.id)", title: row.place.name,
                                      subtitle: "", kind: .campus,
                                      placeId: row.place.id, distanceM: row.distance)
            }
    }

    /// 0 = the alias is the key, 1 = it starts with the key, 2 = one of its words starts with the
    /// key, 3 = it contains the key, nil = no match. Both strings are already normalized.
    private static func score(alias: String, key: String) -> Int? {
        if alias == key { return 0 }
        if alias.hasPrefix(key) { return 1 }
        if alias.split(separator: " ").contains(where: { $0.hasPrefix(key) }) { return 2 }
        if alias.contains(key) { return 3 }
        return nil
    }

    /// The completer rows, in MapKit's order, minus empties, exact repeats, and anything that is
    /// only another spelling of a campus row already in the list (title matches a gazetteer alias
    /// of that place, or the campus row's own name).
    static func mapRows(_ completions: [CompletionLine],
                        excluding campus: [DestinationSuggestion]) -> [DestinationSuggestion] {
        var blocked = Set<String>()
        for row in campus {
            blocked.insert(CampusPlaces.normalize(row.title))
            if let id = row.placeId, let place = CampusPlaces.place(id: id) {
                for alias in place.aliases { blocked.insert(CampusPlaces.normalize(alias)) }
            }
        }
        var seen = Set<String>()
        var out: [DestinationSuggestion] = []
        for line in completions {
            let title = line.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let subtitle = line.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let name = CampusPlaces.normalize(title)
            guard !blocked.contains(name) else { continue }
            let id = "map:\(title)|\(subtitle)"
            guard seen.insert(id).inserted else { continue }
            out.append(DestinationSuggestion(id: id, title: title, subtitle: subtitle, kind: .map))
        }
        return out
    }

    // MARK: Distance on screen

    /// Metres → the short on-screen form of docs/design.md §1: "N m" below 950 m, "N.N km" from
    /// there ("1.0 km", not "1 km", so the row does not jump width as the walker moves).
    /// nil for a negative or non-finite distance. Spoken distances use `WalkingIntro.distancePhrase`.
    ///
    /// The kilometres are rounded to tenths *before* formatting (like `WalkingIntro`), so the
    /// switch-over reads "949 m" → "1.0 km"; `String(format: "%.1f", 0.95)` would print "0.9 km"
    /// and look like the walk got shorter.
    /// Pinned by `shortDistanceSwitchesToKilometresAt950Metres`.
    public static func shortDistance(_ meters: Double) -> String? {
        guard meters.isFinite, meters >= 0 else { return nil }
        if meters < 950 { return "\(Int(meters.rounded())) m" }
        return String(format: "%.1f km", (meters / 100).rounded() / 10)
    }

    // MARK: VoiceOver

    /// The line posted as a VoiceOver announcement when the list changes, so a blind walker knows
    /// there is something to swipe to without hunting for it.
    /// - Parameter count: `suggestions(...)`.count.
    /// - Returns: "No matching places", "1 result", "N results".
    public static func announcement(count: Int) -> String {
        switch count {
        case 0: return "No matching places"
        case 1: return "1 result"
        default: return "\(count) results"
        }
    }
}
