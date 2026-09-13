//
//  ThreatWatchTests.swift
//  CaneKitLogicTests
//
//  Pins weapon / attacker detection in vision-model text. The negative cases carry the weight:
//  this alert emails a family that their blind relative may be being robbed, and a false one a
//  week is exactly how a family learns to mute OpenCane.
//

import Foundation
import Testing
@testable import CaneKitLogic

/// A plain sighting is reported, and the matched word comes back for the event and the log.
@Test func aWeaponIsReported() throws {
    let s = try #require(ThreatWatch.sighting(in: "A man ahead is holding a gun."))
    #expect(s.term == "gun")
    #expect(s.text == "A man ahead is holding a gun.")

    #expect(ThreatWatch.sighting(in: "Someone with a knife is approaching")?.term == "knife")
    #expect(ThreatWatch.sighting(in: "A robber is running toward you")?.term == "robber")
}

/// ⚠ A hazard model answers in the negative constantly. "No weapons" must never alert.
@Test func negationsDoNotAlert() {
    #expect(ThreatWatch.sighting(in: "There is no weapon in sight.") == nil)
    #expect(ThreatWatch.sighting(in: "Not a knife, just an umbrella.") == nil)
    #expect(ThreatWatch.sighting(in: "The path is clear, without any gun or knife.") == nil)
    #expect(ThreatWatch.sighting(in: "No visible weapon.") == nil)
}

/// ⚠ A negation covers its whole clause, including every item of a list. The first version looked
/// back two words and so read "without any gun or knife" as a knife sighting.
@Test func aNegationCoversTheWholeList() {
    #expect(ThreatWatch.sighting(in: "The path is clear, without any gun or knife.") == nil)
    #expect(ThreatWatch.sighting(in: "No weapon, no knife, nothing dangerous.") == nil)
}

/// …but it stops at a contrasting conjunction, or the real weapon in the second half is lost.
@Test func aContrastResetsTheNegation() {
    #expect(ThreatWatch.sighting(in: "No cars, but a man with a gun is ahead.")?.term == "gun")
    #expect(ThreatWatch.sighting(in: "Nothing on the left. A knife is on the right.")?.term == "knife")
}

/// Everyday objects that happen to contain a weapon word are not weapons.
@Test func benignCollocationsDoNotAlert() {
    #expect(ThreatWatch.sighting(in: "A table set with a knife and fork.") == nil)
    #expect(ThreatWatch.sighting(in: "A worker is using a nail gun.") == nil)
    #expect(ThreatWatch.sighting(in: "A child carries a toy gun.") == nil)
    #expect(ThreatWatch.sighting(in: "A butter knife on the counter.") == nil)
}

/// Whole words only: a substring inside another word is not a sighting.
@Test func substringsDoNotAlert() {
    #expect(ThreatWatch.sighting(in: "The railing has a gunmetal finish.") == nil)
    #expect(ThreatWatch.sighting(in: "A knifelike ridge in the pavement.") == nil)
    #expect(ThreatWatch.sighting(in: "Bladed grass along the path.") == nil)
}

/// Ordinary scene descriptions — the overwhelming majority of replies — never alert.
@Test func ordinaryScenesDoNotAlert() {
    for line in ["A crosswalk ahead with a bus stop on the right.",
                 "Obstacle ahead at 1.4 meters. Ahead: a doorway.",
                 "Two people are walking toward you.",
                 "A bicycle is parked against the wall."] {
        #expect(ThreatWatch.sighting(in: line) == nil, "should not alert on: \(line)")
    }
}

/// Punctuation and casing do not hide a weapon.
@Test func punctuationAndCaseDoNotHideIt() {
    #expect(ThreatWatch.sighting(in: "WARNING: (GUN) ahead!")?.term == "gun")
    #expect(ThreatWatch.sighting(in: "a machete.")?.term == "machete")
}

/// Empty or blank text is not a sighting.
@Test func emptyTextIsNotASighting() {
    #expect(ThreatWatch.sighting(in: "") == nil)
    #expect(ThreatWatch.sighting(in: "   ") == nil)
}

/// ⚠ The event quotes the camera rather than asserting a fact: OpenCane does not know there is a
/// gun, it knows a describer said so, and the family reading the email must be able to tell.
@Test func theEventQuotesTheCameraAndIsCritical() throws {
    let sighting = try #require(ThreatWatch.sighting(in: "A man ahead is holding a gun."))
    let event = ThreatWatch.event(sighting, lat: 40.1, lng: -88.2)

    #expect(event.type == .threat)
    #expect(event.severity == .critical)
    #expect(event.note?.contains("OpenCane's camera described:") == true)
    #expect(event.extra?["threat_term"] == .string("gun"))
    #expect(event.lat == 40.1)
}
