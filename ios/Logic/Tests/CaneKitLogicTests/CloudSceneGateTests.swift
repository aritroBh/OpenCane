//
//  CloudSceneGateTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins `CloudSceneGate` — the faithfulness gate for a CLOUD "Where am I" sentence.
//  Until this gate existed a cloud reply went from the provider straight to speech, while the
//  on-device path was gated by `SceneVocabulary.isFaithful`; the walker could not tell which
//  model was talking.
//
//  The fixtures are the strings measured on this project, not invented ones:
//    · street names the model read off Street View frames of the demo route — "S 5th St",
//      "S Grand Ave", "S Grand Blvd", "S. 36th St." — none of which Vision ever read;
//    · "The path ahead is clear and unobstructed", the answer a solid white frame (sun glare, or
//      the lens against a jacket) produced 4 times out of 4;
//    · counts ("three steps", "two cars"): Gemini 3.5 Flash-Lite's worst measured task is
//      counting, 52.7 %;
//    · distances: small VLMs judge distance BELOW chance (GuideDog, ACL 2026: 22.2 % against a
//      25 % baseline) while naming objects at 80–87 %.
//
//  Key invariant: every rejection here is a sentence the walker never hears; they hear the
//  on-device description instead, which only says what the sensors saw.
//
//  Source pinned: `ios/Logic/Sources/CaneKitLogic/CloudSceneGate.swift` (`check` → verdict with a
//  trip-log `note`, `sanitized` → the sentence or nil) plus the shared number predicate
//  `SceneVocabulary.numbersAreGrounded`. Caller: `SceneDescriber` (app) runs `check` on every cloud
//  reply. Breaks these catch, rule by rule (a–f): a count spoken as fact, an invented or
//  clock-face distance, a street / room / building name the camera never read, any "the way is
//  clear" promise (including paraphrases found by the adversarial probe), a paragraph instead of
//  one ≤ 20-word sentence, and — the other half of the bar — an ordinary description being mangled.
//

import Foundation
import Testing
@testable import CaneKitLogic

/// LiDAR line as `AppModel.contextLine` writes it, for the tests that need a real distance fact.
private let lidar14 = "1.4 meters ahead, obstacle."

// MARK: Rule a — counts

/// The model is at ~53 % on counting, so the numeral goes and the hazard stays: a walker needs to
/// know there are steps, not to trust that there are exactly three.
@Test func countsOfHazardsLoseTheirNumeral() {
    #expect(CloudSceneGate.sanitized("Three steps ahead.", lidar: "", ocr: [], detectedNouns: ["stairs"])
            == "steps ahead.")
    #expect(CloudSceneGate.sanitized("Two cars are parked on your right.", lidar: "", ocr: [], detectedNouns: ["cars"])
            == "cars are parked on your right.")
    #expect(CloudSceneGate.sanitized("4 people are crossing in front of you.", lidar: "", ocr: [], detectedNouns: ["people"])
            == "people are crossing in front of you.")
}

/// A numeral that is not counting the next word is never cut out of the middle of a sentence:
/// "one of the doors" must not become "of the doors". The number is ungrounded, so rule b refuses
/// the whole sentence and the walker hears the on-device description instead of a mangled one.
@Test func numeralsThatAreNotCountsAreNotSnippedOut() {
    #expect(CloudSceneGate.sanitized("one of the doors is ahead on your left.", lidar: "",
                                     ocr: [], detectedNouns: ["a door"]) == nil)
}

// MARK: Rule b — distances

/// A distance is only ever the LiDAR number. The same predicate refuses invented numbers on the
/// on-device path (`SceneVocabulary.numbersAreGrounded`), so there is one rule, not two.
@Test func distancesMustBeTheLidarNumber() {
    // Invented: LiDAR says 1.4 m, the model says two.
    #expect(CloudSceneGate.sanitized("A bench is two meters ahead.", lidar: lidar14, ocr: [], detectedNouns: ["a bench"]) == nil)
    // No depth fact at all: any distance is invented.
    #expect(CloudSceneGate.sanitized("A pole three meters ahead.", lidar: "", ocr: [], detectedNouns: ["a pole"]) == nil)
    // Grounded: the number the depth sensor gave may be repeated.
    #expect(CloudSceneGate.sanitized("A bench 1.4 meters ahead.", lidar: lidar14, ocr: [], detectedNouns: ["a bench"])
            == "A bench 1.4 meters ahead.")
    #expect(CloudSceneGate.sanitized("A door two meters ahead.", lidar: "Two meters ahead, obstacle.",
                                     ocr: [], detectedNouns: ["a door"]) == "A door two meters ahead.")
    // Feet are a distance too, and never what the LiDAR fact says.
    #expect(CloudSceneGate.sanitized("Curb about 6 feet ahead.", lidar: lidar14, ocr: [], detectedNouns: []) == nil)
}

/// Clock-face directions die with the same rule: GuideDog measured that VLMs read the clock off the
/// image frame, not the walker's body, so "10 o'clock" points somewhere the walker is not facing.
@Test func clockFaceDirectionsAreRefused() {
    #expect(CloudSceneGate.sanitized("Bike rack at 10 o'clock.", lidar: "", ocr: [], detectedNouns: ["a bike rack"]) == nil)
    #expect(CloudSceneGate.sanitized("A pole at 2 o'clock, a bench at 4 o'clock.", lidar: "",
                                     ocr: [], detectedNouns: ["a pole"]) == nil)
}

// MARK: Rule c — names the camera never read

/// The measured street-name hallucination class. Vision read no text on these frames, so no street
/// name may be spoken: sending a blind walker to the wrong corner is a navigation failure.
@Test func streetNamesTheCameraNeverReadAreRefused() {
    #expect(CloudSceneGate.sanitized("You are at the corner of S 5th St and the sidewalk continues north.",
                                     lidar: "", ocr: [], detectedNouns: ["the sidewalk"]) == nil)
    #expect(CloudSceneGate.sanitized("Crosswalk ahead across S Grand Ave.", lidar: "", ocr: [], detectedNouns: ["a crosswalk"]) == nil)
    #expect(CloudSceneGate.sanitized("The intersection of S Grand Blvd is ahead.", lidar: "", ocr: [], detectedNouns: ["an intersection"]) == nil)
    #expect(CloudSceneGate.sanitized("Ahead is S. 36th St.", lidar: "", ocr: [], detectedNouns: ["the street"]) == nil)
    // Room and building names are the same class.
    #expect(CloudSceneGate.sanitized("The door to Room 214 is on your left.", lidar: "", ocr: [], detectedNouns: ["a door"]) == nil)
    #expect(CloudSceneGate.sanitized("You are outside Grainger Library.", lidar: "", ocr: [], detectedNouns: ["buildings"]) == nil)
}

/// …but a name Vision actually read in that frame is evidence, and is allowed through.
@Test func namesTheCameraDidReadSurvive() {
    #expect(CloudSceneGate.sanitized("A sign reads DETOUR on your right.", lidar: "", ocr: ["DETOUR"],
                                     detectedNouns: ["a door"]) == "A sign reads DETOUR on your right.")
    #expect(CloudSceneGate.sanitized("A sign reads DETOUR on your right.", lidar: "", ocr: [],
                                     detectedNouns: ["a door"]) == nil)
    #expect(CloudSceneGate.sanitized("Crosswalk ahead across S Grand Ave.", lidar: "",
                                     ocr: ["S Grand Ave"], detectedNouns: ["a crosswalk"])
            == "Crosswalk ahead across S Grand Ave.")
}

/// A model that answers in Title Case is not a model naming streets: the capital-letter rule steps
/// aside when most of the reply is capitalised, and the street abbreviation still catches it.
@Test func titleCaseRepliesAreNotTreatedAsNames() {
    #expect(CloudSceneGate.sanitized("Bike Rack Ahead On Your Left.", lidar: "", ocr: [], detectedNouns: ["a bike rack"])
            == "Bike Rack Ahead On Your Left.")
    #expect(CloudSceneGate.sanitized("Crosswalk Ahead At S Grand Ave.", lidar: "", ocr: [], detectedNouns: ["a crosswalk"]) == nil)
}

// MARK: Rule d — reassurance

/// The worst failure this app has. A solid white frame produced exactly this sentence 4 times out
/// of 4: the model says the way is clear precisely when it can see nothing. The sensors, not the
/// model, decide whether a path is clear — and absence of evidence is not evidence of a clear path.
@Test func reassuranceTheSensorsCannotSupportIsRefused() {
    #expect(CloudSceneGate.sanitized("The path ahead is clear and unobstructed.", lidar: "", ocr: [], detectedNouns: []) == nil)
    // Even with things detected, and even with a depth fact, the promise is still refused.
    #expect(CloudSceneGate.sanitized("The path ahead is clear and unobstructed.", lidar: lidar14,
                                     ocr: [], detectedNouns: ["the sidewalk", "trees"]) == nil)
    #expect(CloudSceneGate.sanitized("Nothing in the way.", lidar: "", ocr: [], detectedNouns: ["the sidewalk"]) == nil)
    #expect(CloudSceneGate.sanitized("It is safe to cross.", lidar: "", ocr: [], detectedNouns: ["a crosswalk"]) == nil)
    #expect(CloudSceneGate.sanitized("No obstacles ahead, you can proceed.", lidar: "", ocr: [], detectedNouns: ["the sidewalk"]) == nil)
    #expect(CloudSceneGate.sanitized("The sidewalk is empty.", lidar: "", ocr: [], detectedNouns: ["the sidewalk"]) == nil)
}

/// The same promise without any of the obvious words. Every one of these passed the first version
/// of the gate (adversarial probe of this diff), which is why rule d is a phrase list and not just
/// "clear". Telling a blind walker to move is in here too: guidance comes from the route engine
/// and the depth sensor, never from a model looking at one frame.
@Test func promisesOfSafetyInOtherWordsAreRefused() {
    for s in ["The way is open ahead.",
              "You may walk forward without concern.",
              "I see no immediate danger ahead.",
              "The sidewalk continues with plenty of room.",
              "Proceed straight ahead.",
              "The path is wide and open, no need to slow down.",
              "Nothing blocking your path."] {
        #expect(CloudSceneGate.sanitized(s, lidar: lidar14, ocr: [], detectedNouns: ["the sidewalk"]) == nil,
                "still spoken: \(s)")
    }
}

/// A distance guessed in paces or blocks is a distance, so the numeral stays for rule b to refuse —
/// stripping it as a count left "Steps down in roughly paces." (adversarial probe).
@Test func paceAndBlockEstimatesAreRefusedNotMangled() {
    #expect(CloudSceneGate.sanitized("Steps down in roughly two paces.", lidar: "", ocr: [], detectedNouns: ["stairs"]) == nil)
    #expect(CloudSceneGate.sanitized("The crossing is two blocks ahead.", lidar: "", ocr: [], detectedNouns: ["a crosswalk"]) == nil)
}

/// The other half of the bar: what the rewritten prompt asks for must reach the walker untouched,
/// including warnings that read like reassurance words ("an obstruction", "blocks the sidewalk").
@Test func ordinaryDescriptionsReachTheWalkerUntouched() {
    let nouns = ["the sidewalk", "cars", "people", "trees", "a door", "a bench", "stairs", "a pole"]
    for s in ["A bench and a trash can on your right.",
              "Cars passing on your left, sidewalk continues ahead.",
              "A door in the center, people on the right.",
              "Wet leaves cover the sidewalk in the center.",
              "A construction barrier blocks the sidewalk on the left.",
              "An obstruction in the center of the path.",
              "Stairs going down in the center.",
              "A pole in the center and a bike rack on the left.",
              "Snow covers the curb ramp on the right."] {
        #expect(CloudSceneGate.sanitized(s, lidar: lidar14, ocr: [], detectedNouns: nouns) == s,
                "wrongly changed: \(s)")
    }
}

// MARK: Rule e — length

/// One sentence, twenty words: a walker gets the first thing that matters, not a paragraph.
@Test func repliesAreCappedAtOneSentenceAndTwentyWords() {
    let two = "A bike rack is on your left. Trees line the sidewalk further along."
    #expect(CloudSceneGate.sanitized(two, lidar: "", ocr: [], detectedNouns: ["a bike rack"])
            == "A bike rack is on your left.")
    let long = "a bench and a bike rack sit to your left while the sidewalk runs past trees toward a wide entrance door"
    let capped = CloudSceneGate.sanitized(long, lidar: "", ocr: [], detectedNouns: ["a bench"])
    #expect(capped?.split(separator: " ").count == 20)
    #expect(capped?.hasSuffix(".") == true)
}

// MARK: Rule f — nothing survives

/// When nothing trustworthy is left, the gate says so with nil and the caller speaks the
/// on-device description instead of speaking a trimmed fragment.
@Test func nothingTrustworthyLeftReturnsNil() {
    #expect(CloudSceneGate.sanitized("", lidar: "", ocr: [], detectedNouns: ["a bench"]) == nil)
    #expect(CloudSceneGate.sanitized("   ...  ", lidar: "", ocr: [], detectedNouns: ["a bench"]) == nil)
    #expect(CloudSceneGate.sanitized("7.", lidar: "", ocr: [], detectedNouns: []) == nil)
}

/// An ordinary description — what the rewritten prompt asks for — passes untouched, and the
/// verdict note names what happened so a trip log shows why a sentence was or was not spoken.
@Test func plainSidedDescriptionsPassAndTheNoteExplains() {
    let plain = "A bike rack on your left and people ahead on the sidewalk."
    let verdict = CloudSceneGate.check(plain, lidar: lidar14, ocr: [],
                                       detectedNouns: ["a bike rack", "people", "the sidewalk"])
    #expect(verdict.sentence == plain)
    #expect(verdict.note == "spoken")
    #expect(CloudSceneGate.check("Three steps ahead.", lidar: "", ocr: [], detectedNouns: ["stairs"]).note
            == "edited: dropped count \"Three\"")
    #expect(CloudSceneGate.check("The path ahead is clear.", lidar: "", ocr: [], detectedNouns: []).note
            == "refused: unsupported reassurance \"clear\"")
    #expect(CloudSceneGate.check("Ahead is S. 36th St.", lidar: "", ocr: [], detectedNouns: []).note
            == "refused: name not read by the camera \"St\"")
    #expect(CloudSceneGate.check("A bench is two meters ahead.", lidar: lidar14, ocr: [], detectedNouns: []).note
            == "refused: number not from the depth sensor \"2\"")
}

// MARK: The shared number predicate

/// `SceneVocabulary.numbersAreGrounded` is the one predicate both paths use, so a number can never
/// be legal on the cloud path and illegal on the on-device path.
@Test func groundedNumbersPredicateIsShared() {
    #expect(SceneVocabulary.numbersAreGrounded("two meters ahead", in: "Two meters ahead, obstacle."))
    // Order-free both ways: an old-order LiDAR fact still grounds the same number.
    #expect(SceneVocabulary.numbersAreGrounded("Two meters ahead, door.", in: "Obstacle ahead at two meters."))
    #expect(SceneVocabulary.numbersAreGrounded("a bench ahead", in: ""))
    #expect(!SceneVocabulary.numbersAreGrounded("three meters ahead", in: "1.4 meters ahead, obstacle."))
}

// MARK: Step 49 — the too-dark answer

/// `ScenePrompt.text` asks a model that cannot see to answer exactly "It is too dark to see." The
/// gate must pass that sentence unchanged (it is the honest answer, not a promise or a guess), in
/// the canonical spelling whatever the model did to the punctuation — and must still refuse a
/// dark-frame guess that promises a clear path.
@Test func tooDarkPassesTheGateUnchanged() {
    #expect(CloudSceneGate.tooDark == "It is too dark to see.")
    #expect(ScenePrompt.text.hasSuffix("answer exactly: " + CloudSceneGate.tooDark))
    for spelling in ["It is too dark to see.", "it is too dark to see", "\"It is too dark to see.\"",
                     "It is too dark to see", "  It is too dark to see.\n"] {
        let v = CloudSceneGate.check(spelling, lidar: "", ocr: [], detectedNouns: [])
        #expect(v.sentence == CloudSceneGate.tooDark, "\(spelling)")
        #expect(v.note == "spoken")
    }
    // Not a licence for anything else that mentions the dark.
    #expect(CloudSceneGate.sanitized("It is too dark to see, but the path is clear.", lidar: "",
                                     ocr: [], detectedNouns: []) == nil)
    #expect(CloudSceneGate.sanitized("It is dark. A pole on the left.", lidar: "", ocr: [],
                                     detectedNouns: []) == "It is dark.")   // one sentence, as before
}
