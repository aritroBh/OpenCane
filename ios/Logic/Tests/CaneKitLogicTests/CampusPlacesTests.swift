//
//  CampusPlacesTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins CampusPlaces.swift — the campus gazetteer checked before any MapKit search
//  (aliases → entrance coordinates), the nearest-reasonable-result picker that replaced "take
//  MapKit's first match", and the confirmation line spoken before a MapKit route starts
//  ("Walking to Grainger Engineering Library, 750 meters.").
//
//  Key invariants / fixtures:
//    · `cif` is the CIF east entrance (last waypoint of route_isr_cif.json); `north(m)` / `east(m)`
//      move a point by metres, so picker distances are exact rather than hand-computed.
//    · The gazetteer's CIF and ISR entries must equal the route file's last / first waypoint
//      (read through #filePath, like `shippedRouteFileIsConsistent`).
//    · The place ids are also the raw values of the app's `CampusDestination` AppEnum (Siri
//      "Take me to Grainger in CaneKit"); `campusPlaceIdsArePinned` guards that contract.
//

import Foundation
import Testing
@testable import CaneKitLogic

private let cif = Coordinate(latitude: 40.11242, longitude: -88.22788)

/// `cif` moved `m` metres north (negative = south).
private func north(_ m: Double) -> Coordinate {
    Coordinate(latitude: cif.latitude + m / 111_195, longitude: cif.longitude)
}

/// `cif` moved `m` metres east (negative = west).
private func east(_ m: Double) -> Coordinate {
    Coordinate(latitude: cif.latitude,
               longitude: cif.longitude + m / (111_195 * cos(cif.latitude * .pi / 180)))
}

// MARK: - Gazetteer

/// "CIF", "the C.I.F.!", "Campus-Instructional   Facility": case, punctuation, spacing and a
/// leading "the" never matter.
@Test func campusAliasesIgnoreCasePunctuationAndThe() {
    for q in ["CIF", "cif", "C.I.F.", "the CIF", "The C.I.F.!", "  campus   instructional facility ",
              "Campus-Instructional Facility", "THE CAMPUS INSTRUCTIONAL FACILITY.", "cif?"] {
        #expect(CampusPlaces.match(q)?.id == "cif", "\(q)")
    }
}

/// Every place answers to the names a student would say.
@Test func everyCampusPlaceAnswersToItsAliases() {
    let cases: [(String, String)] = [
        ("ISR", "isr"), ("Townsend Hall", "isr"), ("townsend", "isr"),
        ("Illinois Street Residence Halls", "isr"),
        ("Grainger", "grainger"), ("grainger library", "grainger"),
        ("Grainger Engineering Library", "grainger"),
        ("the Illini Union.", "illiniUnion"), ("Illini Union", "illiniUnion"), ("the union", "illiniUnion"),
        ("Siebel", "siebel"), ("Siebel Center", "siebel"), ("Siebel Center for Computer Science", "siebel"),
        ("Main Library", "mainLibrary"), ("the main library", "mainLibrary"), ("Main Stacks", "mainLibrary"),
        ("ARC", "arc"), ("the A.R.C.", "arc"), ("Activities and Recreation Center", "arc"),
        ("Activities & Recreation Center", "arc"),
    ]
    for (q, id) in cases {
        #expect(CampusPlaces.match(q)?.id == id, "\(q) → \(id)")
    }
}

/// Anything that is not a whole alias goes to MapKit: no partial or fuzzy hits.
@Test func unknownOrPartialNamesFallThroughToMapKit() {
    for q in ["Starbucks", "", "   ", "the", "CIFX", "Grainger Street", "library", "union street",
              "siebel parking", "..."] {
        #expect(CampusPlaces.match(q) == nil, "\(q)")
    }
}

/// The two route endpoints are the route file's own entrances, not a second opinion.
@Test func gazetteerEndpointsAreTheRouteFileEntrances() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("../CaneKit/Resources/route_isr_cif.json").standardized
    let route = try Route.load(from: Data(contentsOf: url))
    let first = try #require(route.waypoints.first), last = try #require(route.waypoints.last)
    #expect(CampusPlaces.place(id: "cif")?.coordinate == last.coordinate)
    #expect(CampusPlaces.place(id: "isr")?.coordinate == first.coordinate)
}

/// Every entry is on campus (a typo'd coordinate would send the walker across town), has a
/// spoken name and aliases, and no alias belongs to two places.
@Test func everyCampusPlaceIsOnCampusAndAliasesAreUnique() {
    var seen: [String: String] = [:]
    for p in CampusPlaces.all {
        #expect(!p.name.isEmpty && !p.aliases.isEmpty, "\(p.id)")
        #expect(GeoMath.distanceMeters(p.coordinate, cif) < 2500, "\(p.id) is off campus")
        for a in p.aliases {
            let key = CampusPlaces.normalize(a)
            #expect(!key.isEmpty, "\(p.id): alias \(a) normalizes to nothing")
            #expect(seen[key] == nil || seen[key] == p.id, "\(a) belongs to \(seen[key] ?? "") and \(p.id)")
            seen[key] = p.id
        }
    }
}

/// The ids are the app's `CampusDestination` raw values (AppIntents.swift): change both together.
@Test func campusPlaceIdsArePinned() {
    #expect(CampusPlaces.all.map(\.id) == ["cif", "isr", "grainger", "illiniUnion", "siebel", "mainLibrary", "arc"])
    for p in CampusPlaces.all { #expect(CampusPlaces.place(id: p.id) == p) }
    #expect(CampusPlaces.place(id: "nope") == nil)
}

// MARK: - Picking a MapKit result

/// The bug from the phone: MapKit's first answer for "Grainger" was a supply store across town.
/// The nearest candidate inside the walking range wins, whatever MapKit's order.
@Test func searchPicksTheNearestReasonableResult() {
    let candidates = [
        PlaceCandidate(name: "Grainger Industrial Supply", coordinate: north(4000)),   // MapKit's first
        PlaceCandidate(name: "W.W. Grainger", coordinate: east(2000)),
        PlaceCandidate(name: "Grainger Engineering Library", coordinate: east(700)),
    ]
    #expect(DestinationPicker.pick(candidates, near: cif, query: "Grainger") == 2)
}

/// A result whose name contains every word of the query beats a nearer unrelated one; with no
/// name match (an address typed), the nearest result in range is taken.
@Test func nameMatchesBeatNearerUnrelatedResults() {
    let named = [
        PlaceCandidate(name: "Cafe Paradiso", coordinate: north(100)),
        PlaceCandidate(name: "Illini Grove", coordinate: north(900)),
    ]
    #expect(DestinationPicker.pick(named, near: cif, query: "the Illini Grove") == 1)
    let address = [
        PlaceCandidate(name: "1401 W Green St", coordinate: north(-400)),
        PlaceCandidate(name: "1401 W Green St, Champaign", coordinate: east(-2500)),
    ]
    #expect(DestinationPicker.pick(address, near: cif, query: "1401 West Green Street") == 0)
}

/// Nothing within 3 km of the walker is "not found", not a 40 km walk.
@Test func nothingWithinWalkingRangeIsNotFound() {
    #expect(DestinationPicker.maxDistanceM == 3000)
    #expect(DestinationPicker.pick([], near: cif, query: "anything") == nil)
    #expect(DestinationPicker.pick([PlaceCandidate(name: "Far", coordinate: north(3010))], near: cif, query: "Far") == nil)
    #expect(DestinationPicker.pick([PlaceCandidate(name: "Near", coordinate: north(2990))], near: cif, query: "Near") == 0)
}

// MARK: - Confirmation line

/// Spoken before the route starts, so a wrong pick can be stopped: nearest 10 m under a
/// kilometre (never "0 meters"), tenths of a kilometre above, no distance when unknown.
@Test func walkingIntroSaysThePlaceAndARoundedDistance() {
    #expect(WalkingIntro.line(place: "Grainger Engineering Library", meters: 747)
            == "Walking to Grainger Engineering Library, 750 meters.")
    #expect(WalkingIntro.line(place: "the Illini Union", meters: 44) == "Walking to the Illini Union, 40 meters.")
    #expect(WalkingIntro.line(place: "X", meters: 3) == "Walking to X, 10 meters.")
    #expect(WalkingIntro.line(place: "X", meters: 994) == "Walking to X, 990 meters.")
    #expect(WalkingIntro.line(place: "X", meters: 996) == "Walking to X, 1 kilometer.")
    #expect(WalkingIntro.line(place: "X", meters: 1234) == "Walking to X, 1.2 kilometers.")
    #expect(WalkingIntro.line(place: "X", meters: 1960) == "Walking to X, 2 kilometers.")
    #expect(WalkingIntro.line(place: "X", meters: -1) == "Walking to X.")
    #expect(WalkingIntro.line(place: "X", meters: .nan) == "Walking to X.")
}
