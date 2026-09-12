//
//  SceneVocabularyTests.swift
//  CaneKitLogicTests
//
//  Pins SceneVocabulary with the labels Apple Vision actually returned on Google Street View
//  frames of the ISR → CIF route (ios/scripts/vision_probe.swift output, 2026-09-11).
//
//  Source pinned: `ios/Logic/Sources/CaneKitLogic/SceneVocabulary.swift` — `nouns` / `narrationNouns`
//  / `list` / `sentence` (Vision identifiers → plain pedestrian nouns, ranked, taxonomy words
//  dropped), `isFaithful` (the gate on the on-device model's sentence), `mentionsDistance` and
//  `readableTexts` (OCR junk filter). Callers: `OnDeviceVision` (facts, template, faithfulness gate),
//  `SceneDescriber`, `VLMClient`. Fixture names WP1…WP9 are the route's waypoints.
//  Breaks these catch: "conveyance" / "portal" / "machine" reaching speech; a crosswalk ranked
//  below grass; a census of every label instead of the top two; and a language-model sentence that
//  invents an object, a hazard word or a number (the real Street View nonsense: "No hazards
//  detected. Distance: zero meters.") being spoken instead of the template. Test comments name the
//  review that found each case (Muse, Antigravity, Claude review workflow).
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

/// A scene answer should give the walker the two highest-ranked useful nouns, not a truthful census
/// of every classifier label. This catches a fallback/model-fact expansion that reintroduces the
/// overload this feature is meant to remove.
@Test func narrationKeepsOnlyTheTopTwoRankedNouns() {
    let corner: [(name: String, confidence: Float)] = [
        ("grass", 0.95), ("path", 0.94), ("crosswalk", 0.93), ("road", 0.92)
    ]

    #expect(SceneVocabulary.narrationNouns(corner) == ["a crosswalk", "a path"])
    #expect(SceneVocabulary.sentence(corner, max: 2) == "Ahead: a crosswalk and a path.")
}

/// The on-device model's Street View answer "No hazards detected. Distance: 0 meters." names
/// nothing and invents a number → rejected; a sentence naming a detected thing is accepted.
@Test func modelSentencesMustBeFaithfulToTheFacts() {
    let facts = "Camera sees: the street, cars"
    let nouns = ["the street", "cars"]
    #expect(!SceneVocabulary.isFaithful("No hazards detected. Distance: 0 meters.", facts: facts, nouns: nouns))
    #expect(SceneVocabulary.isFaithful("Street ahead with cars nearby.", facts: facts, nouns: nouns))
    #expect(!SceneVocabulary.isFaithful("Cars on the street, 3 meters ahead.", facts: facts, nouns: nouns))
    let withDepth = "Depth sensor: 2 meters ahead, obstacle.\nCamera sees: a door"
    #expect(SceneVocabulary.isFaithful("A door ahead, 2 meters away.", facts: withDepth, nouns: ["a door"]))
}

/// Real Street View e2e output of Apple's on-device model (before the gate): every one must be
/// rejected. OCR junk from the same run never reaches the model; real sign text does.
@Test func streetViewModelNonsenseIsRejectedAndOCRJunkFiltered() {
    let facts = "Camera sees: the street, cars"
    let nouns = ["the street", "cars"]
    for bad in ["No hazards detected. Distance: zero meters.",
                "No hazards detected. Distance measured: zero meters.",
                "11 meters to the edge, uneven surface ahead.",
                "Hazard: text at 1 meter, text at 11 meters."] {
        #expect(!SceneVocabulary.isFaithful(bad, facts: facts, nouns: nouns))
    }
    let junk = ["11", "111", "J.I", "JJ", "Ji", "Pr", "li", "{4J J", "{• J", "£xJ"]
    #expect(SceneVocabulary.readableTexts(junk).isEmpty)
    #expect(SceneVocabulary.readableTexts(["SIDEWALK CLOSED", "Green St", "EXIT"]) == ["SIDEWALK CLOSED", "Green St", "EXIT"])
}

/// Muse final review: spelled facts allow digits, synonyms count, prefixes do not.
@Test func faithfulnessUnderstandsSynonymsAndSpelledNumbers() {
    let facts = "Depth sensor: Two meters ahead, obstacle.\nCamera sees: the street, cars"
    let nouns = ["the street", "cars"]
    #expect(SceneVocabulary.isFaithful("Road ahead with a car, 2 meters away.", facts: facts, nouns: nouns))
    #expect(!SceneVocabulary.isFaithful("Cars on the street, three meters ahead.", facts: facts, nouns: nouns))
    #expect(!SceneVocabulary.isFaithful("Businesses line the block.", facts: "Camera sees: a bus", nouns: ["a bus"]))
    #expect(SceneVocabulary.isFaithful("A crossing is just ahead.", facts: "Camera sees: a crosswalk", nouns: ["a crosswalk"]))
    #expect(SceneVocabulary.isFaithful("Door ahead, one and a half meters.",
                                       facts: "One and a half meters ahead, obstacle. Camera sees: a door", nouns: ["a door"]))
}

/// Antigravity final review: "1.4" in the facts must not license an invented "4".
@Test func decimalsInTheFactsStayWhole() {
    let facts = "Depth sensor: 1.4 meters ahead, obstacle.\nCamera sees: a door"
    #expect(!SceneVocabulary.isFaithful("A door ahead, 4 meters away.", facts: facts, nouns: ["a door"]))
    #expect(SceneVocabulary.isFaithful("A door ahead, 1.4 meters away.", facts: facts, nouns: ["a door"]))
    #expect(SceneVocabulary.isFaithful("A door, 1.5 meters ahead.",
                                       facts: "One and a half meters ahead, obstacle. Camera sees: a door", nouns: ["a door"]))
}

/// Muse review of 3efc0b1: nothing detected → the model is never trusted; teens are numbers too;
/// a misread "EX1T" is still text.
@Test func blankWallsTeensAndMisreadsAreHandled() {
    #expect(!SceneVocabulary.isFaithful("A door ahead.", facts: "Nothing detected.", nouns: []))
    #expect(!SceneVocabulary.isFaithful("The street runs thirteen meters ahead.",
                                        facts: "Two meters ahead, obstacle. Camera sees: the street", nouns: ["the street"]))
    #expect(SceneVocabulary.readableTexts(["EX1T"]) == ["EX1T"])
    #expect(SceneVocabulary.readableTexts(["111", "{4J J"]).isEmpty)
}

/// Claude review workflow: with the old prompt Apple's model answered "Camera sees: trees, grass"
/// with "A crosswalk is ahead, then stairs, then a door, and finally trees." 4 of 4 times. A
/// sentence naming any vocabulary object that was not detected must be rejected.
@Test func inventedObjectsAreRejected() {
    let facts = "Camera sees: trees, grass"
    let nouns = ["trees", "grass"]
    #expect(!SceneVocabulary.isFaithful("A crosswalk is ahead, then stairs, then a door, and finally trees.", facts: facts, nouns: nouns))
    #expect(!SceneVocabulary.isFaithful("Crosswalk, stairs, door, trees, grass.", facts: facts, nouns: nouns))
    #expect(!SceneVocabulary.isFaithful("A crosswalk, stairs, and a door are ahead; trees are further away.",
                                        facts: "Depth sensor: 1.4 meters ahead, obstacle.\nCamera sees: a path, trees, grass",
                                        nouns: ["a path", "trees", "grass"]))
    #expect(SceneVocabulary.isFaithful("Trees and grass ahead.", facts: facts, nouns: nouns))
}

/// Realistic good sentences must still pass the stricter gate (no false rejections of plain wording).
@Test func plainGoodSentencesStillPass() {
    let facts = "Camera sees: a crosswalk, the street, cars"
    let nouns = ["a crosswalk", "the street", "cars"]
    #expect(SceneVocabulary.isFaithful("A crosswalk crosses the street, with cars passing.", facts: facts, nouns: nouns))
    #expect(SceneVocabulary.isFaithful("Crosswalk ahead; cars are on the road.", facts: facts, nouns: nouns))
    let indoor = "Camera sees: tables, chairs, windows"
    #expect(SceneVocabulary.isFaithful("Tables and chairs ahead, with windows behind them.", facts: indoor,
                                       nouns: ["tables", "chairs", "windows"]))
}

/// Words the facts contain are allowed (a sentence about visible sign text is grounded), and the
/// distance check looks for the LiDAR number, not the substring "meter" (Muse + Antigravity).
@Test func factWordsAreAllowedAndDistanceIsANumber() {
    let facts = "Camera sees: the street\nVisible text: \"SIDEWALK CLOSED\""
    #expect(SceneVocabulary.isFaithful("The street ahead; a sign says sidewalk closed.", facts: facts, nouns: ["the street"]))
    #expect(!SceneVocabulary.mentionsDistance("Parking meters line the street.", from: "1.4 meters ahead, obstacle."))
    #expect(SceneVocabulary.mentionsDistance("A pole ahead, 1.4 meters away.", from: "1.4 meters ahead, obstacle."))
    #expect(SceneVocabulary.mentionsDistance("A pole two meters ahead.", from: "Two meters ahead, obstacle."))
}

/// Hazard words outside the object vocabulary ("cone", "barrier", "trench") also count as invented
/// unless the facts mention them (Antigravity final review).
@Test func inventedHazardWordsAreRejected() {
    #expect(!SceneVocabulary.isFaithful("A cone ahead near the trees.", facts: "Camera sees: trees", nouns: ["trees"]))
    #expect(!SceneVocabulary.isFaithful("Trees, and a barrier on the path.", facts: "Camera sees: trees", nouns: ["trees"]))
}
