//
//  SceneVocabularyTests.swift
//  CaneKitLogicTests
//
//  Pins SceneVocabulary with the labels Apple Vision actually returned on Google Street View
//  frames of the ISR → CIF route (ios/scripts/vision_probe.swift output, 2026-09-11).
//

import Testing
@testable import CaneKitLogic

/// Green Street (WP4): synonyms collapse to one "cars"; the hypernym "machine" is dropped.
@Test func synonymsCollapseAndHypernymsDrop() {
    let wp4: [(name: String, confidence: Float)] = [("automobile", 0.85), ("machine", 0.85), ("vehicle", 0.85),
                                                    ("car", 0.85), ("road", 0.83), ("street", 0.83)]
    #expect(SceneVocabulary.nouns(wp4) == ["the street", "cars"])
    #expect(SceneVocabulary.sentence(wp4) == "Ahead: the street and cars.")
}

/// Springfield (WP6): "conveyance" and "portal" never reach speech.
@Test func taxonomyWordsNeverReachSpeech() {
    let wp6: [(name: String, confidence: Float)] = [("conveyance", 0.98), ("portal", 0.98), ("manhole", 0.98),
                                                    ("road", 0.84), ("street", 0.84), ("machine", 0.83)]
    let said = SceneVocabulary.sentence(wp6) ?? ""
    #expect(!said.contains("conveyance") && !said.contains("portal") && !said.contains("machine"))
    #expect(said == "Ahead: the street and a manhole cover.")
}

/// Goodwin corner (WP3): the crosswalk is said first even though grass is more confident.
@Test func crossingInformationComesFirst() {
    let wp3: [(name: String, confidence: Float)] = [("grass", 0.89), ("path", 0.87), ("crosswalk", 0.86),
                                                    ("road", 0.79), ("street", 0.79), ("machine", 0.78)]
    #expect(SceneVocabulary.nouns(wp3) == ["a crosswalk", "a path", "the street"])
}

/// ISR lounge (WP1): indoor nouns, no "furniture" or "conveyance".
@Test func indoorSceneIsPlain() {
    let wp1: [(name: String, confidence: Float)] = [("furniture", 0.80), ("table", 0.77), ("conveyance", 0.53),
                                                    ("portal", 0.53), ("window", 0.52), ("chair", 0.52)]
    #expect(SceneVocabulary.sentence(wp1) == "Ahead: tables, chairs and windows.")
}

/// Nothing nameable (only hypernyms or low confidence) → nil, so the caller says so plainly.
@Test func nothingNameableIsNil() {
    let wp9: [(name: String, confidence: Float)] = [("conveyance", 0.37), ("portal", 0.36), ("brick", 0.31),
                                                    ("window", 0.2)]
    #expect(SceneVocabulary.sentence(wp9) == nil)
    #expect(SceneVocabulary.list(["a door"]) == "a door")
}

/// People are said (a busy sidewalk is not "nothing"); slip hazards beat street and cars; an
/// indoor plant is "plants", never "bushes" (Muse + Antigravity, Step 12 review).
@Test func peopleIceAndPlantsAreSaidSensibly() {
    let busy: [(name: String, confidence: Float)] = [("people", 0.8), ("sidewalk", 0.7)]
    #expect(SceneVocabulary.nouns(busy) == ["the sidewalk", "people"])
    let winter: [(name: String, confidence: Float)] = [("ice", 0.9), ("road", 0.85), ("automobile", 0.8), ("tree", 0.7)]
    #expect(SceneVocabulary.nouns(winter) == ["the street", "ice", "cars"])
    let lounge: [(name: String, confidence: Float)] = [("plant", 0.7), ("sofa", 0.6)]
    #expect(SceneVocabulary.sentence(lounge) == "Ahead: a sofa and plants.")
}

/// The on-device model's Street View answer "No hazards detected. Distance: 0 meters." names
/// nothing and invents a number → rejected; a sentence naming a detected thing is accepted.
@Test func modelSentencesMustBeFaithfulToTheFacts() {
    let facts = "Camera sees: the street, cars"
    let nouns = ["the street", "cars"]
    #expect(!SceneVocabulary.isFaithful("No hazards detected. Distance: 0 meters.", facts: facts, nouns: nouns))
    #expect(SceneVocabulary.isFaithful("Street ahead with cars nearby.", facts: facts, nouns: nouns))
    #expect(!SceneVocabulary.isFaithful("Cars on the street, 3 meters ahead.", facts: facts, nouns: nouns))
    let withDepth = "Depth sensor: Obstacle ahead at 2 meters.\nCamera sees: a door"
    #expect(SceneVocabulary.isFaithful("A door ahead, 2 meters away.", facts: withDepth, nouns: ["a door"]))
}
