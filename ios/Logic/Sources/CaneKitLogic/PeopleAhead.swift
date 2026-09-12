//
//  PeopleAhead.swift
//  CaneKitLogic
//
//  Turns Apple Vision's body and animal detections into the one line a blind walker actually
//  wants: "About 3 meters ahead, two people."
//
//  Why it exists: the 1,303-class scene classifier is a whole-frame guess and it fails silently.
//  The real iPhone trip log of 2026-09-11 has `describe_result` with
//  `vision_error: "no labels (1303 raw)"` — 1,303 observations, not one over the 0.25 confidence
//  floor — so "Where am I" said only the LiDAR template and never named the people in front of
//  the walker. `DetectHumanRectanglesRequest` and `RecognizeAnimalsRequest` are separate, much
//  narrower models that answer *where* as well as *what*, and they answer when the classifier
//  does not.
//
//  What this file owns (every number that turns a detection into words, so it is testable
//  without a camera): the confidence floors, the left / ahead / right bands, how counts become
//  words, how many groups are worth saying, and where the distance comes from. The app half
//  (`OnDeviceVision`, `OnDeviceVLMClient`) only runs the requests and reads the depth grid.
//
//  Faithfulness: a sighting is a **fact**, exactly like the LiDAR distance. `PeopleAhead.line`
//  is spoken whether or not Apple's language model produces anything, and `PeopleAhead.nouns`
//  feeds `SceneVocabulary.isFaithful(_:facts:nouns:detected:)` so a sentence that names people
//  is allowed through the gate. Nothing else is loosened.
//
//  Tests: PeopleAheadTests.swift.
//

import Foundation

/// What was detected. Kept tiny on purpose: Vision's dedicated detectors only answer
/// "a human body", "a dog", "a cat" — everything richer is the scene classifier's job.
public enum SightingKind: String, Sendable, Codable, CaseIterable {
    /// A human body rectangle (`DetectHumanRectanglesRequest`).
    case person
    /// A dog (`RecognizeAnimalsRequest`, identifier "dog").
    case dog
    /// A cat (`RecognizeAnimalsRequest`, identifier "cat").
    case cat

    /// The `SceneVocabulary` group noun this kind is grounded by, so a model sentence naming it
    /// passes `isFaithful`. Must stay a noun that exists in `SceneVocabulary.groups`.
    public var vocabularyNoun: String {
        switch self {
        case .person: return "people"
        case .dog: return "a dog"
        case .cat: return "a cat"
        }
    }

    /// Spoken form for exactly one ("a person", "a dog", "a cat").
    var singular: String {
        switch self {
        case .person: return "a person"
        case .dog: return "a dog"
        case .cat: return "a cat"
        }
    }

    /// Spoken form for more than one ("people", "dogs", "cats").
    var plural: String {
        switch self {
        case .person: return "people"
        case .dog: return "dogs"
        case .cat: return "cats"
        }
    }

    /// People are said before animals when only one group fits in the line.
    var priority: Int { self == .person ? 0 : 1 }

    /// Detections below this confidence are noise. People: `DetectHumanRectanglesRequest`
    /// scores real bodies well above 0.5, and a false "a person ahead" is worse than silence.
    /// Animals: `RecognizeAnimalsRequest` is a classifier and is held to a higher bar.
    var minConfidence: Float {
        self == .person ? 0.5 : 0.6
    }
}

/// Where a detection sits across the frame, from the walker's point of view.
public enum SightingBearing: String, Sendable, Codable, CaseIterable {
    /// Off to the walker's left.
    case left
    /// In the walking path.
    case ahead
    /// Off to the walker's right.
    case right

    /// What the walker hears ("on your left", "ahead", "on your right").
    public var spoken: String {
        switch self {
        case .left: return "on your left"
        case .ahead: return "ahead"
        case .right: return "on your right"
        }
    }

    /// Left, then ahead, then right, for a stable order when distances tie.
    var order: Int {
        switch self {
        case .ahead: return 0
        case .left: return 1
        case .right: return 2
        }
    }
}

/// One body or animal Vision found in one frame, plus the depth read inside its own box.
public struct Sighting: Sendable, Equatable {
    /// Person, dog or cat.
    public var kind: SightingKind
    /// Vision's normalized bounding box on the upright frame (bottom-left origin).
    public var box: NormalizedBox
    /// Vision's confidence, 0…1.
    public var confidence: Float
    /// Metres from `DepthSnapshot.distance(inVisionBox:)`, or nil when LiDAR could not answer.
    /// nil means the walker hears the direction with **no** number — never a guessed one.
    public var distance: Float?

    /// - Parameters:
    ///   - kind: person, dog or cat.
    ///   - box: Vision's normalized bounding box (bottom-left origin).
    ///   - confidence: Vision's confidence, 0…1.
    ///   - distance: metres from the depth grid, or nil when unknown.
    public init(kind: SightingKind, box: NormalizedBox, confidence: Float, distance: Float? = nil) {
        self.kind = kind
        self.box = box
        self.confidence = confidence
        self.distance = distance
    }
}

/// Every rule that turns sightings into one spoken line. Stateless.
public enum PeopleAhead {

    // MARK: Tunables (all pinned by PeopleAheadTests)

    /// Half-width of the "ahead" band, as a fraction of the image width. The iPhone's wide camera
    /// covers ~50 deg across a portrait frame, so 0.12 is ~+/-6 deg — about +/-0.31 m at 3 m,
    /// roughly one body width. Narrower and a person in the path is called "on your left";
    /// wider and "ahead" stops meaning "in your way".
    public static let aheadHalfWidth: Float = 0.12

    /// Counts above this are spoken as "several" rather than a number: past three, the exact
    /// count is neither reliable (bodies overlap) nor useful.
    public static let maxCounted = 3

    /// At most this many direction groups are spoken. One line, under 20 words: a blind walker
    /// cannot hold a census, and the describer speaks at the lowest priority behind route cues.
    public static let maxGroups = 2

    // MARK: Direction

    /// Which way a detection lies, from its box centre.
    /// - Parameters:
    ///   - midX: box centre across the frame, 0 = image left, 1 = image right.
    ///   - mirrored: the mount swaps left and right (`AppModel.mirrorLeftRight`); the camera image
    ///     is never mirrored, so the swap is applied to the spoken word, exactly as `LaneMath`
    ///     applies it to the lane index.
    /// ⚠ Pinned by `bearingBands`, `bearingHonoursMirror`.
    public static func bearing(midX: Float, mirrored: Bool = false) -> SightingBearing {
        let raw: SightingBearing
        if midX < 0.5 - aheadHalfWidth {
            raw = .left
        } else if midX > 0.5 + aheadHalfWidth {
            raw = .right
        } else {
            raw = .ahead
        }
        guard mirrored else { return raw }
        switch raw {
        case .left: return .right
        case .right: return .left
        case .ahead: return .ahead
        }
    }

    // MARK: Words

    /// "a person" / "two people" / "several people" (lower case; the caller capitalises).
    /// - Parameters:
    ///   - kind: person, dog or cat.
    ///   - count: how many were detected in this direction (≥ 1).
    /// ⚠ Pinned by `countWords`.
    public static func countPhrase(_ kind: SightingKind, count: Int) -> String {
        switch count {
        case ..<2: return kind.singular
        case 2: return "two \(kind.plural)"
        case 3: return "three \(kind.plural)"
        default: return "several \(kind.plural)"
        }
    }

    /// "about 3 meters" / "very close", or nil when depth is unknown or untrustworthy.
    /// "about" is deliberate: a person moves, and `SpokenDistance` rounds to the half metre.
    /// - Parameter meters: metres from the depth grid.
    /// ⚠ Pinned by `distanceWords`.
    public static func distancePhrase(_ meters: Float?) -> String? {
        guard let meters, DepthSnapshot.trusted.contains(meters) else { return nil }
        let phrase = SpokenDistance.phrase(meters)
        guard !phrase.isEmpty else { return nil }
        // "about very close" is not English; the phrase is already an approximation.
        return phrase == "very close" ? phrase : "about \(phrase)"
    }

    // MARK: The line

    /// The one sentence the walker hears, or nil when nothing cleared the confidence floor.
    ///
    /// Sightings are grouped by kind and direction; the nearest group is said first and carries
    /// the distance, a second group is added without one (so the line stays under 20 words), and
    /// anything further is dropped. People always outrank animals. Every clause is distance-first
    /// ("About 3 meters ahead, two people"): same contract as the obstacle and ground-hazard
    /// lines — time-to-contact before identity.
    /// - Parameters:
    ///   - sightings: this frame's detections, distances already attached (nil where unknown).
    ///   - mirrored: see `bearing(midX:mirrored:)`.
    /// - Returns: e.g. "About 3 meters ahead, two people.", "A person on your left.",
    ///   "About two meters ahead, a person, and a dog on your right."
    /// ⚠ Pinned by `onePersonAhead`, `twoPeopleWithDistance`, `noDepthMeansNoNumber`,
    ///   `severalPeople`, `twoGroupsNearestFirst`, `animalsComeAfterPeople`, `lowConfidenceDropped`.
    public static func line(_ sightings: [Sighting], mirrored: Bool = false) -> String? {
        let groups = self.groups(sightings, mirrored: mirrored)
        guard !groups.isEmpty else { return nil }

        let spoken = Array(groups.prefix(maxGroups))
        let lead = distancePhrase(spoken[0].distance)
        var text = clause(spoken[0], distance: lead, capitalized: true)
        if spoken.count > 1 {
            // A real LiDAR distance is never dropped: people lead the line, so when the leading
            // group had no depth the second group's distance moves onto its own clause rather
            // than going unsaid (adversarial review of this change).
            let tail = lead == nil ? distancePhrase(spoken[1].distance) : nil
            text += (lead == nil ? " and " : ", and ") + clause(spoken[1], distance: tail, capitalized: false)
        }
        return text + "."
    }

    /// One group's clause, distance first ("About 3 meters ahead, two people").
    ///
    /// Without depth it is direction only ("A person on your left") — a missing number is never
    /// invented. The bearing word sits inside the distance phrase ("About 3 meters ahead"), so an
    /// ahead-group never stutters ("ahead … ahead").
    /// - Parameters:
    ///   - group: the kind/direction/count group to phrase.
    ///   - distance: `distancePhrase(group.distance)`, or nil to say direction only.
    ///   - capitalized: upper-case the first letter (the line's first clause only).
    /// - Returns: the clause without any trailing full stop.
    static func clause(_ group: Group, distance: String?, capitalized: Bool) -> String {
        let text: String
        if let distance {
            text = "\(distance) \(group.bearing.spoken), \(countPhrase(group.kind, count: group.count))"
        } else {
            text = "\(countPhrase(group.kind, count: group.count)) \(group.bearing.spoken)"
        }
        guard capitalized else { return text }
        return text.prefix(1).uppercased() + String(text.dropFirst())
    }

    /// The `SceneVocabulary` nouns these sightings ground, so a language-model sentence that
    /// names people (or a dog) is allowed through `isFaithful`. Empty when nothing was detected.
    /// - Parameter sightings: this frame's detections (unfiltered; the confidence floor is applied here).
    /// ⚠ Pinned by `nounsAreVocabularyNouns`.
    public static func nouns(_ sightings: [Sighting]) -> [String] {
        var out: [String] = []
        for kind in [SightingKind.person, .dog, .cat]
        where sightings.contains(where: { $0.kind == kind && $0.confidence >= kind.minConfidence }) {
            out.append(kind.vocabularyNoun)
        }
        return out
    }

    /// Must `line` still be spoken after the language model has had its turn?
    ///
    /// Yes unless the model's sentence carries the whole fact: every detected noun named, every
    /// number of `line` repeated, **and** every direction word of `line` present. Anything less
    /// and the authoritative line is spoken as well — a detected person is a fact and may never
    /// be dropped, and a count, a distance or a *side* the model quietly changed is worse than
    /// hearing the line twice. Fail-closed on purpose, twice over: an "any noun named" test let a
    /// sentence about the dog suppress the person (Muse), and without the direction words a model
    /// answering "A person on your left." suppressed a line that said "ahead" (second review).
    /// - Parameters:
    ///   - line: `PeopleAhead.line`'s sentence.
    ///   - sentence: what the language model produced.
    ///   - detected: `PeopleAhead.nouns` for the same frame.
    /// ⚠ Pinned by `modelMustCarryEveryDetectedNoun`, `modelMustCarryTheNumbers`,
    ///   `modelMustCarryTheDirection`, `nothingDetectedNeedsNoLine`.
    public static func needsSpeaking(_ line: String, given sentence: String,
                                     detected: [String]) -> Bool {
        guard !detected.isEmpty else { return false }
        let named = detected.allSatisfy { SceneVocabulary.mentions(sentence, noun: $0) }
        let numbered = SceneVocabulary.numbers(in: line)
            .isSubset(of: SceneVocabulary.numbers(in: sentence))
        // Direction and urgency words, which carry no number: a swapped side or a dropped
        // "very close" must not count as the fact having been said.
        let said = Set(SceneVocabulary.tokens(sentence))
        let mine = Set(SceneVocabulary.tokens(line))
        let placed = placeWords.allSatisfy { !mine.contains($0) || said.contains($0) }
        return !(named && numbered && placed)
    }

    /// Words of a people line that locate or qualify it without using a number, so
    /// `needsSpeaking` can tell whether the model kept them.
    static let placeWords = ["ahead", "left", "right", "close"]

    /// A short summary for the trip log ("2 person, 1 dog"), so a walk log shows what the
    /// detectors saw and not only what was said (AGENTS.md "make the invisible visible").
    /// - Parameter sightings: this frame's detections (unfiltered).
    /// ⚠ Pinned by `logSummary`.
    public static func summary(_ sightings: [Sighting]) -> String {
        let kept = sightings.filter { $0.confidence >= $0.kind.minConfidence }
        guard !kept.isEmpty else { return "" }
        return SightingKind.allCases.compactMap { kind -> String? in
            let n = kept.filter { $0.kind == kind }.count
            return n > 0 ? "\(n) \(kind.rawValue)" : nil
        }.joined(separator: ", ")
    }

    // MARK: Grouping

    /// One kind in one direction: how many, and how far the nearest of them is.
    struct Group: Equatable {
        var kind: SightingKind
        var bearing: SightingBearing
        var count: Int
        var distance: Float?
    }

    /// Groups the sightings that clear their confidence floor, people before animals and nearest
    /// first within a kind; a group with no depth sorts behind every group that has one.
    ///
    /// People outrank a nearer animal on purpose: only two groups fit in one line, and a walker
    /// needs to know about the person. An animal close enough to trip over is already inside the
    /// LiDAR lanes' range and has buzzed the cane.
    static func groups(_ sightings: [Sighting], mirrored: Bool) -> [Group] {
        var byKey: [String: Group] = [:]
        // A non-finite box centre would fall into the `ahead` band (every NaN comparison is
        // false), i.e. the one band that means "in your way"; drop it instead (Muse review).
        for s in sightings where s.confidence >= s.kind.minConfidence && s.box.midX.isFinite {
            let bearing = bearing(midX: s.box.midX, mirrored: mirrored)
            let key = "\(s.kind.rawValue)|\(bearing.rawValue)"
            // Only a distance LiDAR can be trusted over counts (`DepthSnapshot.trusted`);
            // anything else leaves the group without a number rather than inventing one.
            let d = s.distance.flatMap { DepthSnapshot.trusted.contains($0) ? $0 : nil }
            if var g = byKey[key] {
                g.count += 1
                g.distance = [g.distance, d].compactMap { $0 }.min()
                byKey[key] = g
            } else {
                byKey[key] = Group(kind: s.kind, bearing: bearing, count: 1, distance: d)
            }
        }
        return byKey.values.sorted { a, b in
            if a.kind.priority != b.kind.priority { return a.kind.priority < b.kind.priority }
            let da = a.distance ?? .greatestFiniteMagnitude
            let db = b.distance ?? .greatestFiniteMagnitude
            if da != db { return da < db }
            if a.count != b.count { return a.count > b.count }
            return a.bearing.order < b.bearing.order
        }
    }
}
