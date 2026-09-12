//
//  PeopleAheadTests.swift
//  CaneKitLogicTests
//
//  Pins every number that turns a Vision body detection into words: the left / ahead / right
//  bands, the count wording, the distance wording and its trusted range, how many groups are
//  spoken, and the confidence floors. None of this needs a camera, which matters because Vision's
//  neural models do not run in the simulator ("Failed to create espresso context") — the wording
//  rules are testable on the Mac even though the detector itself is only verifiable on the phone.
//
//  Boxes are written in Vision's convention: normalized, **bottom-left** origin, on the upright
//  portrait frame.
//

import Testing
@testable import CaneKitLogic

/// A body box centred at `x` across the frame, full height, with a distance.
private func person(at x: Float, meters: Float? = nil, confidence: Float = 0.9) -> Sighting {
    Sighting(kind: .person,
             box: NormalizedBox(minX: x - 0.1, minY: 0.1, width: 0.2, height: 0.6),
             confidence: confidence, distance: meters)
}

// MARK: - Direction

@Test func bearingBands() {
    // +/-0.12 around the centre is "ahead" (~+/-6 deg, ~one body width at 3 m).
    #expect(PeopleAhead.bearing(midX: 0.5) == .ahead)
    #expect(PeopleAhead.bearing(midX: 0.39) == .ahead)
    #expect(PeopleAhead.bearing(midX: 0.61) == .ahead)
    #expect(PeopleAhead.bearing(midX: 0.37) == .left)
    #expect(PeopleAhead.bearing(midX: 0.63) == .right)
    #expect(PeopleAhead.bearing(midX: 0.0) == .left)
    #expect(PeopleAhead.bearing(midX: 1.0) == .right)
}

@Test func bearingHonoursMirror() {
    // A mirrored mount swaps the spoken side, never the image (the JPEG is only rotated).
    #expect(PeopleAhead.bearing(midX: 0.1, mirrored: true) == .right)
    #expect(PeopleAhead.bearing(midX: 0.9, mirrored: true) == .left)
    #expect(PeopleAhead.bearing(midX: 0.5, mirrored: true) == .ahead)
}

// MARK: - Words

@Test func countWords() {
    #expect(PeopleAhead.countPhrase(.person, count: 1) == "a person")
    #expect(PeopleAhead.countPhrase(.person, count: 2) == "two people")
    #expect(PeopleAhead.countPhrase(.person, count: 3) == "three people")
    // Past three the count is neither reliable (bodies overlap) nor useful.
    #expect(PeopleAhead.countPhrase(.person, count: 4) == "several people")
    #expect(PeopleAhead.countPhrase(.person, count: 11) == "several people")
    #expect(PeopleAhead.countPhrase(.dog, count: 1) == "a dog")
    #expect(PeopleAhead.countPhrase(.dog, count: 2) == "two dogs")
    #expect(PeopleAhead.countPhrase(.cat, count: 1) == "a cat")
}

@Test func distanceWords() {
    #expect(PeopleAhead.distancePhrase(2.0) == "about two meters")
    #expect(PeopleAhead.distancePhrase(3.0) == "about 3 meters")
    #expect(PeopleAhead.distancePhrase(0.6) == "about half a meter")
    // The nearest distance the LiDAR range allows still rounds to half a metre; the "very close"
    // branch (no "about", which would not be English) only matters if `trusted` ever drops
    // below 0.25 m.
    #expect(PeopleAhead.distancePhrase(0.35) == "about half a meter")
    #expect(PeopleAhead.distancePhrase(DepthSnapshot.trusted.lowerBound)?.hasPrefix("about") == true)
    // No depth, or depth outside the range ARKit's LiDAR can be trusted over (0.3-5 m): no number.
    #expect(PeopleAhead.distancePhrase(nil) == nil)
    #expect(PeopleAhead.distancePhrase(9) == nil)
    #expect(PeopleAhead.distancePhrase(0.1) == nil)
    #expect(PeopleAhead.distancePhrase(.infinity) == nil)
}

// MARK: - The line

@Test func onePersonAhead() {
    #expect(PeopleAhead.line([person(at: 0.5, meters: 2)]) == "About two meters ahead, a person.")
}

@Test func twoPeopleWithDistance() {
    // The frame that made this feature necessary: the classifier said nothing, two bodies at 3 m.
    let s = [person(at: 0.47, meters: 3.1), person(at: 0.55, meters: 3.4)]
    #expect(PeopleAhead.line(s) == "About 3 meters ahead, two people.")
}

@Test func noDepthMeansNoNumber() {
    // Faithfulness: with no LiDAR answer the direction is still spoken, the distance never invented.
    #expect(PeopleAhead.line([person(at: 0.2)]) == "A person on your left.")
    #expect(PeopleAhead.line([person(at: 0.9, meters: 12)]) == "A person on your right.")
}

@Test func severalPeople() {
    let crowd = (0..<5).map { person(at: 0.45 + Float($0) * 0.01, meters: 2.2) }
    #expect(PeopleAhead.line(crowd) == "About two meters ahead, several people.")
}

@Test func twoGroupsNearestFirst() {
    // Nearest group leads and carries the distance; the second is direction only, so the whole
    // line stays inside the describer's one-sentence budget.
    let s = [person(at: 0.9, meters: 4.0), person(at: 0.5, meters: 1.5)]
    #expect(PeopleAhead.line(s) == "About one and a half meters ahead, a person, and a person on your right.")
}

@Test func thirdGroupIsDropped() {
    let s = [person(at: 0.5, meters: 1.5), person(at: 0.9, meters: 2.5), person(at: 0.1, meters: 3.5)]
    let line = PeopleAhead.line(s) ?? ""
    #expect(line == "About one and a half meters ahead, a person, and a person on your right.")
    #expect(!line.contains("left"))
}

@Test func groupWithoutDepthSortsLast() {
    let s = [person(at: 0.1), person(at: 0.5, meters: 4)]
    #expect(PeopleAhead.line(s) == "About 4 meters ahead, a person, and a person on your left.")
}

@Test func aRealDistanceIsNeverDropped() {
    // People lead the line, so when the leading group has no depth the second group's real LiDAR
    // distance moves onto its own clause instead of going unsaid (adversarial review).
    let dog = Sighting(kind: .dog, box: NormalizedBox(minX: 0.8, minY: 0, width: 0.1, height: 0.1),
                       confidence: 0.9, distance: 1.2)
    #expect(PeopleAhead.line([dog, person(at: 0.5)])
            == "A person ahead and about one meter on your right, a dog.")
}

@Test func nonFiniteBoxIsDroppedNotCalledAhead() {
    // Every NaN comparison is false, so a NaN centre would land in the "ahead" band — the one
    // that means "in your way" (Muse review).
    let bad = Sighting(kind: .person,
                       box: NormalizedBox(minX: .nan, minY: 0.1, width: 0.2, height: 0.6),
                       confidence: 0.95, distance: 2)
    #expect(PeopleAhead.line([bad]) == nil)
    #expect(PeopleAhead.line([bad, person(at: 0.9, meters: 3)]) == "About 3 meters on your right, a person.")
}

@Test func animalsComeAfterPeople() {
    let dog = Sighting(kind: .dog, box: NormalizedBox(minX: 0.8, minY: 0.0, width: 0.1, height: 0.1),
                       confidence: 0.9, distance: 1.0)
    // The dog is nearer, but a person outranks it: one line, people first.
    #expect(PeopleAhead.line([dog, person(at: 0.5, meters: 3)])
            == "About 3 meters ahead, a person, and a dog on your right.")
}

@Test func animalAloneIsSpoken() {
    let dog = Sighting(kind: .dog, box: NormalizedBox(minX: 0.0, minY: 0.0, width: 0.2, height: 0.2),
                       confidence: 0.8, distance: 2.0)
    #expect(PeopleAhead.line([dog]) == "About two meters on your left, a dog.")
}

@Test func lowConfidenceDropped() {
    // A false "a person ahead" is worse than silence.
    #expect(PeopleAhead.line([person(at: 0.5, meters: 2, confidence: 0.49)]) == nil)
    #expect(PeopleAhead.line([person(at: 0.5, meters: 2, confidence: 0.5)]) != nil)
    let shyDog = Sighting(kind: .dog, box: NormalizedBox(minX: 0.4, minY: 0, width: 0.2, height: 0.2),
                          confidence: 0.55, distance: 2)
    #expect(PeopleAhead.line([shyDog]) == nil)      // animals are held to 0.6
}

@Test func nothingDetectedIsNil() {
    #expect(PeopleAhead.line([]) == nil)
}

@Test func mirroredLineSwapsSides() {
    #expect(PeopleAhead.line([person(at: 0.1, meters: 2)], mirrored: true)
            == "About two meters on your right, a person.")
}

// MARK: - Facts handed on

@Test func nounsAreVocabularyNouns() {
    let dog = Sighting(kind: .dog, box: NormalizedBox(minX: 0, minY: 0, width: 0.1, height: 0.1),
                       confidence: 0.9)
    #expect(PeopleAhead.nouns([person(at: 0.5), dog]) == ["people", "a dog"])
    // Every noun must exist in SceneVocabulary, or the faithfulness gate could not ground it.
    for n in PeopleAhead.nouns([person(at: 0.5), dog]) {
        #expect(SceneVocabulary.groups.contains { $0.noun == n })
    }
    #expect(PeopleAhead.nouns([person(at: 0.5, confidence: 0.2)]).isEmpty)
}

@Test func logSummary() {
    let dog = Sighting(kind: .dog, box: NormalizedBox(minX: 0, minY: 0, width: 0.1, height: 0.1),
                       confidence: 0.9)
    #expect(PeopleAhead.summary([person(at: 0.5), person(at: 0.2), dog]) == "2 person, 1 dog")
    #expect(PeopleAhead.summary([]) == "")
}

// MARK: - Faithfulness (the gate the people facts must pass)

@Test func detectedPeopleAreFaithfulWithoutSceneLabels() {
    // The exact failure this feature exists for: the classifier returned nothing, so `nouns` is
    // empty. Before, every sentence was rejected and the walker heard only the LiDAR template.
    let facts = "People detector: About 3 meters ahead, two people."
    // The model may answer in either order; the numbers and nouns are what ground it.
    #expect(SceneVocabulary.isFaithful("Two people ahead, about 3 meters.",
                                       facts: facts, nouns: [], detected: ["people"]))
    #expect(SceneVocabulary.isFaithful("About 3 meters ahead, two people.",
                                       facts: facts, nouns: [], detected: ["people"]))
    // A synonym of the merged group still counts.
    #expect(SceneVocabulary.isFaithful("A pedestrian is ahead.",
                                       facts: facts, nouns: [], detected: ["people"]))
}

@Test func detectingPeopleDoesNotLoosenAnythingElse() {
    let facts = "People detector: About two meters ahead, a person."
    // A dog that was never detected is still rejected...
    #expect(!SceneVocabulary.isFaithful("A person and a dog ahead.",
                                        facts: facts, nouns: [], detected: ["people"]))
    // ...as is an invented number.
    #expect(!SceneVocabulary.isFaithful("A person ahead at five meters.",
                                        facts: facts, nouns: [], detected: ["people"]))
    // ...and a sentence naming nothing that was detected.
    #expect(!SceneVocabulary.isFaithful("The sidewalk is clear.",
                                        facts: facts, nouns: [], detected: ["people"]))
    // With nothing detected at all the gate is unchanged: the template speaks.
    #expect(!SceneVocabulary.isFaithful("A person ahead.", facts: "Nothing detected.", nouns: []))
}

// MARK: - Does the model's sentence still need the people line?

@Test func modelMustCarryEveryDetectedNoun() {
    let line = "About 3 meters ahead, a person, and a dog on your right."
    // Naming only the dog must NOT suppress the person: an "any noun named" test dropped the
    // person entirely (Muse review of this change).
    #expect(PeopleAhead.needsSpeaking(line, given: "A dog on your right, 3 meters away.",
                                      detected: ["people", "a dog"]))
    #expect(PeopleAhead.needsSpeaking(line, given: "The sidewalk is clear.",
                                      detected: ["people", "a dog"]))
    #expect(!PeopleAhead.needsSpeaking(line, given: "A person ahead at 3 meters and a dog to the right.",
                                       detected: ["people", "a dog"]))
}

@Test func modelMustCarryTheNumbers() {
    let line = "About 3 meters ahead, two people."
    // Right nouns, wrong (or missing) numbers: say the authoritative line as well.
    #expect(PeopleAhead.needsSpeaking(line, given: "People are ahead of you.", detected: ["people"]))
    #expect(PeopleAhead.needsSpeaking(line, given: "Two people five meters ahead.", detected: ["people"]))
    #expect(!PeopleAhead.needsSpeaking(line, given: "Two people ahead, about 3 meters.", detected: ["people"]))
    // Number words count as numbers ("two" == 2, "three" == 3).
    #expect(!PeopleAhead.needsSpeaking("About three meters ahead, two people.",
                                       given: "2 people ahead at 3 meters.", detected: ["people"]))
}

@Test func modelMustCarryTheDirection() {
    // With no depth the line has no number, so the numbers check is vacuous: without the
    // direction words a model that swapped the side would suppress the true line and the walker
    // would be sent the wrong way (adversarial review).
    #expect(PeopleAhead.needsSpeaking("A person ahead.", given: "A person is on your left.",
                                      detected: ["people"]))
    #expect(!PeopleAhead.needsSpeaking("A person ahead.", given: "A person ahead of you.",
                                       detected: ["people"]))
    #expect(PeopleAhead.needsSpeaking("A person on your right.", given: "A person on your left.",
                                      detected: ["people"]))
    #expect(!PeopleAhead.needsSpeaking("A person on your right.", given: "A person to the right.",
                                       detected: ["people"]))
    // A dropped "very close" carries no number either.
    #expect(PeopleAhead.needsSpeaking("Very close ahead, a person.", given: "A person ahead.",
                                      detected: ["people"]))
}

@Test func theTemplateNeverDoublesTheLine() {
    // The deterministic template already contains the line verbatim, so nothing is prepended.
    let line = "About 3 meters ahead, two people."
    let template = "1.4 meters ahead, obstacle. \(line) Ahead: the sidewalk and trees."
    #expect(!PeopleAhead.needsSpeaking(line, given: template, detected: ["people"]))
}

@Test func nothingDetectedNeedsNoLine() {
    #expect(!PeopleAhead.needsSpeaking("", given: "Ahead: the sidewalk and trees.", detected: []))
}

@Test func mentionsCountsMergedIdentifiers() {
    #expect(SceneVocabulary.mentions("Two people ahead.", noun: "people"))
    #expect(SceneVocabulary.mentions("A pedestrian is crossing.", noun: "people"))
    #expect(SceneVocabulary.mentions("An adult ahead.", noun: "people"))
    #expect(!SceneVocabulary.mentions("The sidewalk is clear.", noun: "people"))
    #expect(SceneVocabulary.mentions("A dog on your right.", noun: "a dog"))
    #expect(!SceneVocabulary.mentions("A dog on your right.", noun: "people"))
}
