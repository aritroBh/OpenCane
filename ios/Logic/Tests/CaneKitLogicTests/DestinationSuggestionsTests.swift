//
//  DestinationSuggestionsTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins DestinationSuggestions.swift — the ranked list the destination search box shows
//  while the walker types. The rules that matter to a blind user are all here: a campus place is
//  never pushed below a MapKit row (MKLocalSearch answers "Grainger" with an industrial supply
//  store), the same place is never listed twice, the list never grows past what fits above the
//  keyboard, a distance is only ever claimed when a real fix was passed in, and the VoiceOver
//  label says name + kind + distance.
//
//  Key invariants / fixtures:
//    · `fromCIF(m:)` moves the CIF entrance north by exact metres, so distance ordering is
//      arithmetic rather than a hand-computed guess.
//    · The debounce interval and the row caps are asserted here because the app reads the
//      constants instead of repeating the numbers.
//

import Foundation
import Testing
@testable import CaneKitLogic

/// The CIF east entrance (gazetteer "cif"), the origin most of these tests measure from.
private let cifEntrance = Coordinate(latitude: 40.11242, longitude: -88.22788)

/// `cifEntrance` moved `m` metres north (negative = south).
private func fromCIF(_ m: Double) -> Coordinate {
    Coordinate(latitude: cifEntrance.latitude + m / 111_195, longitude: cifEntrance.longitude)
}

// MARK: - Numbers

/// The debounce is a quarter of a second: the app must read this, not repeat 0.25.
@Test func debounceIsAQuarterOfASecond() {
    #expect(DestinationSuggestions.debounceSeconds == 0.25)
    #expect(DestinationSuggestions.minimumQueryLength == 2)
    #expect(DestinationSuggestions.maxSuggestions == 6)
    #expect(DestinationSuggestions.maxCampusSuggestions == 3)
}

/// One letter (or nothing but punctuation) shows no list at all: it would match half of Urbana
/// and VoiceOver would announce a row count for nothing.
@Test func shortQueriesGetNoSuggestions() {
    for q in ["", " ", "g", "the", "?", "  a "] {
        #expect(DestinationSuggestions.suggestions(query: q,
                                                   completions: [CompletionLine(title: "Green Street", subtitle: "Urbana")],
                                                   from: nil).isEmpty, "\(q)")
    }
}

// MARK: - Campus first

/// "Grainger" must offer Grainger Engineering Library before MapKit's industrial supply store —
/// the exact failure this list exists to prevent — and the campus row must be marked as one.
@Test func campusPlacesRankFirst() {
    let completions = [CompletionLine(title: "Grainger Industrial Supply", subtitle: "Champaign, IL"),
                       CompletionLine(title: "Grainger Ave", subtitle: "Urbana, IL")]
    let rows = DestinationSuggestions.suggestions(query: "Grainger", completions: completions, from: nil)
    #expect(rows.first?.kind == .campus)
    #expect(rows.first?.placeId == "grainger")
    #expect(rows.first?.title == "Grainger Engineering Library")
    #expect(rows.dropFirst().allSatisfy { $0.kind == .map })
    #expect(rows.count == 3)
}

/// Unlike `CampusPlaces.match` (whole aliases only), the list matches what has been typed so far:
/// prefixes, inner words and mid-word fragments all find their place.
@Test func campusMatchingIsPartialUnlikeTheGazetteerLookup() {
    #expect(CampusPlaces.match("grain") == nil)      // the route path still refuses a partial name
    let cases: [(String, String)] = [
        ("gra", "grainger"), ("grainger e", "grainger"),
        ("ci", "cif"), ("town", "isr"), ("illinois street", "isr"),
        ("union", "illiniUnion"),        // inner word: "Illini Union"
        ("sieb", "siebel"), ("main lib", "mainLibrary"), ("recreation", "arc"),
    ]
    for (query, id) in cases {
        let rows = DestinationSuggestions.suggestions(query: query, completions: [], from: nil)
        #expect(rows.first?.placeId == id, "\(query) → \(rows.first?.placeId ?? "nothing")")
    }
}

/// A whole-alias hit beats a prefix hit, and between two equal scores the nearer place wins.
/// From 2 km north of CIF, Grainger (just north of CIF) is nearer than the Main Library (south).
@Test func nearerCampusPlacesComeFirstWithAFix() {
    let north = fromCIF(2000)
    let rows = DestinationSuggestions.campusMatches("li", from: north)      // library, library…
    let ids = rows.map(\.placeId)
    #expect(ids.contains("grainger"))
    #expect(ids.contains("mainLibrary"))
    let grainger = GeoMath.distanceMeters(north, CampusPlaces.place(id: "grainger")!.coordinate)
    let main = GeoMath.distanceMeters(north, CampusPlaces.place(id: "mainLibrary")!.coordinate)
    #expect(grainger < main)
    #expect(ids.firstIndex(of: "grainger")! < ids.firstIndex(of: "mainLibrary")!)
}

/// At most three campus rows, so a gazetteer match can never hide every MapKit answer.
@Test func atMostThreeCampusRows() {
    // "i" is too short for `suggestions`, so drive the ranker directly with a key many aliases share.
    let rows = DestinationSuggestions.campusMatches("il", from: nil)
    #expect(rows.count <= DestinationSuggestions.maxCampusSuggestions)
}

// MARK: - Map rows

/// MapKit's own spelling of a place already in the list is dropped, so "Grainger" never shows
/// the library twice; an unrelated result with the same first word stays.
@Test func mapRowsThatDuplicateACampusPlaceAreDropped() {
    let completions = [CompletionLine(title: "Grainger Engineering Library", subtitle: "1301 W Springfield Ave"),
                       CompletionLine(title: "grainger library", subtitle: "Urbana"),
                       CompletionLine(title: "Grainger Industrial Supply", subtitle: "Champaign")]
    let rows = DestinationSuggestions.suggestions(query: "Grainger", completions: completions, from: nil)
    #expect(rows.filter { $0.kind == .map }.map(\.title) == ["Grainger Industrial Supply"])
}

/// Empty titles and byte-identical repeats never reach the list (the completer emits both while
/// a query is being refined).
@Test func emptyAndRepeatedMapRowsAreDropped() {
    let completions = [CompletionLine(title: "  ", subtitle: "nothing"),
                       CompletionLine(title: "Espresso Royale", subtitle: "1117 W Oregon St"),
                       CompletionLine(title: "Espresso Royale", subtitle: "1117 W Oregon St"),
                       CompletionLine(title: "Espresso Royale", subtitle: "602 E Daniel St")]
    let rows = DestinationSuggestions.suggestions(query: "espresso", completions: completions, from: nil)
    #expect(rows.count == 2)
    #expect(rows.allSatisfy { $0.kind == .map })
    // The address goes into the search text, which is what makes MapKit pick the right one of two.
    #expect(rows[0].searchQuery == "Espresso Royale, 1117 W Oregon St")
}

/// Six rows maximum, campus rows kept.
@Test func theListNeverGrowsPastSixRows() {
    let completions = (1...20).map { CompletionLine(title: "Result \($0)", subtitle: "Urbana") }
    let rows = DestinationSuggestions.suggestions(query: "Grainger", completions: completions, from: nil)
    #expect(rows.count == DestinationSuggestions.maxSuggestions)
    #expect(rows.first?.kind == .campus)
}

// MARK: - What the walker hears and sees

/// The label carries the name, that it is a campus place, the distance when one was measured and
/// the address when there is one. A map row never claims a distance: the completer has no
/// coordinate, so there is nothing to measure.
@Test func voiceOverLabelNamesTheKindAndTheDistance() {
    let withFix = DestinationSuggestions.suggestions(query: "Grainger", completions: [], from: fromCIF(0))
    let campus = try! #require(withFix.first)
    // Grainger's entrance is ≈ 50 m from the CIF east entrance (both are OSM/route-file points).
    #expect(campus.voiceOverLabel == "Grainger Engineering Library, campus place, 50 meters away")
    #expect(campus.voiceOverHint == "Starts walking guidance to this place")

    let noFix = DestinationSuggestions.suggestions(query: "Grainger", completions: [], from: nil)
    #expect(noFix.first?.voiceOverLabel == "Grainger Engineering Library, campus place")
    #expect(noFix.first?.distanceM == nil)

    let map = DestinationSuggestions.mapRows([CompletionLine(title: "Espresso Royale", subtitle: "1117 W Oregon St")],
                                             excluding: [])
    #expect(map.first?.voiceOverLabel == "Espresso Royale, 1117 W Oregon St")
    #expect(map.first?.distanceM == nil)
}

/// The visible second line: the address for a map row, "On campus" for a gazetteer row, with the
/// short distance appended only when a fix gave us one.
@Test func detailLineShowsTheAddressOrTheCampusDistance() {
    let withFix = DestinationSuggestions.suggestions(query: "CIF", completions: [], from: fromCIF(300))
    #expect(withFix.first?.detailLine == "On campus · 300 m")
    let noFix = DestinationSuggestions.suggestions(query: "CIF", completions: [], from: nil)
    #expect(noFix.first?.detailLine == "On campus")
    let map = DestinationSuggestions.mapRows([CompletionLine(title: "Espresso Royale", subtitle: "1117 W Oregon St")],
                                             excluding: [])
    #expect(map.first?.detailLine == "1117 W Oregon St")
}

/// On-screen distances follow design.md §1: metres up to 950, then tenths of a kilometre.
@Test func shortDistanceSwitchesToKilometresAt950Metres() {
    #expect(DestinationSuggestions.shortDistance(0) == "0 m")
    #expect(DestinationSuggestions.shortDistance(4.4) == "4 m")
    #expect(DestinationSuggestions.shortDistance(949) == "949 m")
    #expect(DestinationSuggestions.shortDistance(950) == "1.0 km")
    #expect(DestinationSuggestions.shortDistance(1240) == "1.2 km")
    #expect(DestinationSuggestions.shortDistance(-1) == nil)
    #expect(DestinationSuggestions.shortDistance(.infinity) == nil)
}

/// The announcement VoiceOver hears when the list changes.
@Test func announcementCountsTheRows() {
    #expect(DestinationSuggestions.announcement(count: 0) == "No matching places")
    #expect(DestinationSuggestions.announcement(count: 1) == "1 result")
    #expect(DestinationSuggestions.announcement(count: 6) == "6 results")
}

/// The campus centre used to bias the completer's region is genuinely on campus: within walking
/// range of every gazetteer entrance.
@Test func campusCentreIsWithinWalkingRangeOfEveryPlace() {
    for place in CampusPlaces.all {
        let d = GeoMath.distanceMeters(CampusPlaces.center, place.coordinate)
        #expect(d < DestinationPicker.maxDistanceM, "\(place.id) is \(Int(d)) m from the centre")
    }
}
