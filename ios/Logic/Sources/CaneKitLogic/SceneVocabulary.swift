//
//  SceneVocabulary.swift
//  CaneKitLogic
//
//  Turns Apple Vision scene labels into words a blind pedestrian can use. Vision's classifier
//  returns a taxonomy, not speech: on Google Street View frames of the demo route it said
//  "automobile, machine, vehicle" at Green Street and "conveyance, portal, manhole" at Springfield,
//  and "Where am I" read those out verbatim. This table keeps only nouns that matter on foot,
//  merges synonyms (automobile / car / vehicle → "cars"), drops abstract hypernyms (conveyance,
//  portal, machine, structure, material), and orders what is said by usefulness to a cane user
//  (a crosswalk before grass).
//
//  It is also the faithfulness gate for the on-device model's sentence (`isFaithful`: no invented
//  objects, no invented numbers) and the shared number / token / stem helpers other gates use.
//
//  Callers: `OnDeviceVLMClient` (app: `narrationNouns` for the facts and the template sentence,
//  `isFaithful` on Apple's on-device model, `mentionsDistance` for the LiDAR prefix);
//  `SceneDescriber` (cloud path: `narrationNouns` + `readableTexts` as gate evidence,
//  `mentionsDistance`); `CloudSceneGate` (`numbersAreGrounded`, `numbers`, `tokens`,
//  `numberWords`); `PeopleAhead` (`mentions`, `numbers`, `tokens`); `HazardWatchPolicy` in
//  Hazards.swift (`tokens`, `stem`).
//  Isolation: stateless and nonisolated; the tables are immutable `static let`s.
//  Tests: SceneVocabularyTests.swift (16; fixtures are the real Street View labels), plus the
//  people cases in PeopleAheadTests and the shared number rule in CloudSceneGateTests.
//

import Foundation

/// Vision scene-classifier identifiers → the few spoken nouns a cane user can act on, plus the
/// faithfulness rules a model sentence must pass before it may be spoken. Stateless.
/// ⚠ Add a `Group` for a new useful identifier; never pass raw identifiers to speech (AGENTS.md).
public enum SceneVocabulary {

    /// Maximum number of scene-classifier nouns used in one calm spoken scene answer. People and
    /// measured LiDAR facts are separate authoritative channels; this limit only removes the
    /// lower-ranked background census from the narration path.
    public static let narrationMaxItems = 2

    /// One spoken noun, its rank (lower is said first) and every Vision identifier that means it.
    struct Group: Sendable {
        /// Usefulness to a walker; lower is said first. Ties break on classifier confidence.
        let rank: Int
        /// The words spoken, with their article ("a crosswalk", "the street", "cars"). Also a
        /// public contract: `PeopleAhead` / `SightingKind.vocabularyNoun` name groups by this.
        let noun: String
        /// Lower-case Vision identifiers merged into `noun`; their `_`-separated parts also count as
        /// synonyms for the faithfulness gate (`synonyms(of:)`).
        let ids: [String]
    }

    /// The vocabulary, most useful first. Identifiers not listed are dropped: the taxonomy's
    /// hypernyms ("conveyance", "portal", "machine", "structure", "material", "furniture") say
    /// nothing a walker can act on.
    static let groups: [Group] = [
        // Wayfinding and crossing
        Group(rank: 0, noun: "a crosswalk", ids: ["crosswalk", "zebra_crossing"]),
        Group(rank: 1, noun: "stairs", ids: ["stairs", "staircase", "steps"]),
        Group(rank: 1, noun: "an escalator", ids: ["escalator"]),
        Group(rank: 2, noun: "a traffic light", ids: ["traffic_light"]),
        Group(rank: 2, noun: "a stop sign", ids: ["stop_sign"]),
        Group(rank: 3, noun: "a door", ids: ["door", "doorway"]),
        Group(rank: 3, noun: "an entrance", ids: ["entrance"]),
        Group(rank: 3, noun: "a revolving door", ids: ["revolving_door"]),
        Group(rank: 3, noun: "an elevator", ids: ["elevator"]),
        Group(rank: 4, noun: "a ramp", ids: ["ramp"]),
        Group(rank: 5, noun: "the sidewalk", ids: ["sidewalk"]),
        Group(rank: 5, noun: "a path", ids: ["path", "walkway"]),
        Group(rank: 6, noun: "the street", ids: ["road", "street"]),
        Group(rank: 6, noun: "an intersection", ids: ["intersection"]),
        Group(rank: 6, noun: "a parking lot", ids: ["parking_lot"]),
        // Things that move or block
        // Slip hazards rank with things that move or block (Muse, Step 12: ice was dropped behind
        // "the street" and "cars" when only three nouns were said; narration now says two —
        // `narrationMaxItems` — which makes the rank matter more, not less).
        Group(rank: 7, noun: "ice", ids: ["ice"]),
        Group(rank: 7, noun: "snow", ids: ["snow"]),
        Group(rank: 7, noun: "a puddle", ids: ["puddle"]),
        Group(rank: 8, noun: "people", ids: ["person", "people", "adult", "child", "pedestrian"]),
        Group(rank: 7, noun: "cars", ids: ["automobile", "car", "vehicle"]),
        Group(rank: 7, noun: "a truck", ids: ["truck"]),
        Group(rank: 7, noun: "a bus", ids: ["bus"]),
        Group(rank: 7, noun: "a train", ids: ["train"]),
        Group(rank: 8, noun: "bicycles", ids: ["bicycle"]),
        Group(rank: 8, noun: "a motorcycle", ids: ["motorcycle"]),
        Group(rank: 8, noun: "a scooter", ids: ["scooter"]),
        Group(rank: 8, noun: "a dog", ids: ["dog"]),
        // Vision's dedicated animal detector (`RecognizeAnimalsRequest`) answers dog *or* cat, so
        // "a cat" needs a group of its own — without it a detected cat could not be spoken and
        // "cat" would not be a vocabulary stem the faithfulness gate can reject (PeopleAhead).
        Group(rank: 8, noun: "a cat", ids: ["cat"]),
        Group(rank: 9, noun: "a fence", ids: ["fence"]),
        Group(rank: 9, noun: "a pole", ids: ["pole"]),
        Group(rank: 9, noun: "a street light", ids: ["streetlight", "lamppost"]),
        Group(rank: 9, noun: "a barrier", ids: ["barrier"]),
        Group(rank: 9, noun: "a bollard", ids: ["bollard"]),
        Group(rank: 10, noun: "a bench", ids: ["bench"]),
        Group(rank: 10, noun: "a fire hydrant", ids: ["fire_hydrant", "hydrant"]),
        Group(rank: 10, noun: "a trash can", ids: ["trash_can"]),
        Group(rank: 10, noun: "a mailbox", ids: ["mailbox"]),
        Group(rank: 10, noun: "a bike rack", ids: ["bicycle_rack"]),
        Group(rank: 11, noun: "a manhole cover", ids: ["manhole"]),
        // Indoors
        Group(rank: 12, noun: "tables", ids: ["table"]),
        Group(rank: 12, noun: "chairs", ids: ["chair"]),
        Group(rank: 12, noun: "a sofa", ids: ["sofa", "couch"]),
        Group(rank: 12, noun: "desks", ids: ["desk"]),
        Group(rank: 12, noun: "a counter", ids: ["counter"]),
        // Surroundings
        Group(rank: 13, noun: "an archway", ids: ["arch"]),
        Group(rank: 13, noun: "buildings", ids: ["building"]),
        Group(rank: 13, noun: "houses", ids: ["house"]),
        Group(rank: 14, noun: "trees", ids: ["tree"]),
        Group(rank: 15, noun: "grass", ids: ["grass", "lawn"]),
        Group(rank: 15, noun: "bushes", ids: ["shrub", "bush"]),
        Group(rank: 15, noun: "plants", ids: ["plant"]),   // indoors this is a houseplant, not a bush
        Group(rank: 16, noun: "windows", ids: ["window"]),
    ]

    /// Vision identifier → its group, built once from `groups`.
    static let table: [String: Group] = {
        var t: [String: Group] = [:]
        for g in groups { for id in g.ids { t[id] = g } }
        return t
    }()

    /// Distinct spoken nouns for `labels`, most useful first, at most `max`.
    /// Identifiers are lower-cased before lookup; unknown ones are dropped; sorted by `rank`, then
    /// by confidence (higher first); a noun reached by two identifiers is said once.
    /// - Parameters:
    ///   - labels: Vision identifiers with confidence (any order).
    ///   - max: most nouns returned (3 by default; scene narration asks for `narrationMaxItems`).
    ///   - minConfidence: labels below this are ignored (0.3; `OnDeviceVision` already dropped
    ///     everything under its own 0.25 floor).
    /// - Returns: spoken noun phrases, e.g. ["a crosswalk", "the street"].
    /// Pinned by `synonymsCollapseAndHypernymsDrop`, `crossingInformationComesFirst`.
    public static func nouns(_ labels: [(name: String, confidence: Float)], max: Int = 3,
                             minConfidence: Float = 0.3) -> [String] {
        let known = labels
            .filter { $0.confidence >= minConfidence }
            .compactMap { l -> (noun: String, rank: Int, conf: Float)? in
                guard let g = table[l.name.lowercased()] else { return nil }
                return (g.noun, g.rank, l.confidence)
            }
            .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.conf > $1.conf }
        var out: [String] = []
        for k in known where !out.contains(k.noun) {
            out.append(k.noun)
            if out.count == max { break }
        }
        return out
    }

    /// The ranked classifier nouns allowed into a normal spoken scene answer.
    ///
    /// The general `nouns` API remains available to faithfulness and diagnostics callers that need
    /// the full candidate set. Scene narration uses this narrower, two-item default so a truthful
    /// frame does not become an exhausting inventory. Pinned by `narrationKeepsOnlyTheTopTwoRankedNouns`.
    /// - Parameters:
    ///   - labels: Vision identifiers with confidence.
    ///   - max: cap (default `narrationMaxItems`); ≤ 0 returns [] rather than trapping.
    /// - Returns: at most `max` nouns, same order as `nouns`.
    public static func narrationNouns(_ labels: [(name: String, confidence: Float)],
                                      max: Int = narrationMaxItems) -> [String] {
        guard max > 0 else { return [] }
        return nouns(labels, max: max)
    }

    /// "a crosswalk, the street and cars" (Oxford-free, spoken).
    /// - Parameter nouns: spoken nouns in the order to say them.
    /// - Returns: "" for none, the noun alone for one, else "a, b and c".
    public static func list(_ nouns: [String]) -> String {
        switch nouns.count {
        case 0: return ""
        case 1: return nouns[0]
        default: return nouns.dropLast().joined(separator: ", ") + " and " + nouns[nouns.count - 1]
        }
    }

    /// Is a language-model sentence faithful to the facts it was given? Apple's on-device model
    /// answered a Street View corner with "No hazards detected. Distance: 0 meters." — nothing
    /// described, a distance invented. Accept a sentence only if it names at least one of `nouns`
    /// (by its last word: "the street" → "street") when there are nouns, every number in it also
    /// appears in `facts`, and it is short enough to speak (≤ 30 words). Otherwise the caller
    /// speaks the deterministic template instead.
    ///
    /// `detected` carries facts from Vision's **dedicated** detectors — today the people and
    /// animals `PeopleAhead.nouns` found. They are grounded exactly like the scene labels and the
    /// LiDAR distance: a body rectangle is something the sensors saw, so a sentence may name it,
    /// and a frame where only people were detected (the classifier returning nothing is the case
    /// this whole path exists for) still has something to be faithful to. Nothing else is loosened.
    /// - Parameters:
    ///   - sentence: what the language model produced.
    ///   - facts: the plain-text facts it was given.
    ///   - nouns: spoken nouns from the scene classifier (`SceneVocabulary.nouns`).
    ///   - detected: spoken nouns from the dedicated detectors (`PeopleAhead.nouns`).
    /// - Returns: true only when every rule passes; false sends the caller to the template.
    /// ⚠ Pinned by `modelSentencesMustBeFaithfulToTheFacts`,
    ///   `streetViewModelNonsenseIsRejectedAndOCRJunkFiltered`, `inventedObjectsAreRejected`,
    ///   `inventedHazardWordsAreRejected`, `factWordsAreAllowedAndDistanceIsANumber`,
    ///   `detectedPeopleAreFaithfulWithoutSceneLabels` (PeopleAheadTests).
    public static func isFaithful(_ sentence: String, facts: String, nouns: [String],
                                  detected: [String] = []) -> Bool {
        let words = tokens(sentence)
        guard !words.isEmpty, words.count <= 30 else { return false }
        // Nothing nameable was detected: there is nothing the sentence could be faithful to, so the
        // deterministic template speaks (Muse: "A door ahead." at a blank wall passed the gate).
        let grounded = nouns + detected
        guard !grounded.isEmpty else { return false }
        // Accept the noun or any synonym the vocabulary merged into it ("road" for "the street",
        // "car" for "cars", "crossing" for "a crosswalk"), compared on a simple stem. Exact stem
        // equality only: prefix matching let "businesses" count as "bus" (Muse, final review).
        let terms = Set(grounded.flatMap(synonyms(of:)).map(stem))
        guard words.contains(where: { terms.contains(stem($0)) }) else { return false }
        // …and names nothing else from the vocabulary: with an example list in the prompt the
        // model answered "trees, grass" with "a crosswalk, then stairs, then a door, and finally
        // trees" (Claude review workflow). Any object word not detected rejects the sentence.
        // Anything the facts themselves say is grounded too ("a sign says sidewalk closed" when
        // the facts carry that visible text; Muse + Antigravity review of f5413b8).
        var allowed = terms.union(tokens(facts).map(stem))
        if facts.contains("Visible text") { allowed.insert(stem("sign")) }   // text seen = text on a sign
        let invented = words.contains { w in
            let s = stem(w)
            return vocabularyStems.contains(s) && !allowed.contains(s)
        }
        guard !invented else { return false }
        // Numbers, written as digits or words, must come from the facts: "two meters" in the facts
        // allows "2 meters"; an invented "three" or "zero" is rejected (Street View e2e, Muse).
        return numbersAreGrounded(sentence, in: facts)
    }

    /// Does every number in `sentence` also appear in `facts`? Digits and number words are the same
    /// number ("two meters" in the facts allows "2 meters"), decimals stay whole so an invented "4"
    /// cannot hide inside "1.4". Empty facts ground nothing, so any number is invented.
    ///
    /// The one place this rule lives: `isFaithful` uses it for the on-device sentence and
    /// `CloudSceneGate` for the cloud sentence, so a distance can never be legal on one path and
    /// illegal on the other. Pinned by `groundedNumbersPredicateIsShared`,
    /// `distancesMustBeTheLidarNumber`.
    public static func numbersAreGrounded(_ sentence: String, in facts: String) -> Bool {
        numbers(in: sentence).isSubset(of: numbers(in: facts))
    }

    /// True when `sentence` states a distance that `lidar` (the depth fact) gives — by number, not
    /// by the substring "meter" ("parking meters" and "kilometers" matched that; review of f5413b8).
    /// Callers prepend the LiDAR line only when this is false, so a distance is never said twice.
    /// - Parameters:
    ///   - sentence: the model's (already gated) sentence.
    ///   - lidar: the LiDAR fact line ("1.4 meters ahead, obstacle."); "" shares no number.
    public static func mentionsDistance(_ sentence: String, from lidar: String) -> Bool {
        !numbers(in: sentence).isDisjoint(with: numbers(in: lidar))
    }

    /// True when `sentence` already names `noun`, counting every Vision identifier the vocabulary
    /// merged into it ("person", "pedestrian" and "adult" all count as "people"). Used to decide
    /// whether the people line still has to be prepended to a model sentence — a detected person
    /// must be spoken, but never twice.
    /// - Parameters:
    ///   - sentence: the model's sentence.
    ///   - noun: a spoken noun from `groups` ("people", "a dog").
    /// Pinned by `mentionsCountsMergedIdentifiers` (PeopleAheadTests).
    public static func mentions(_ sentence: String, noun: String) -> Bool {
        let terms = Set(synonyms(of: noun).map(stem))
        return tokens(sentence).contains { terms.contains(stem($0)) }
    }

    /// Lower-case word and digit tokens ("1.5" → "1", "5"). Splits on anything that is neither a
    /// letter nor a number, so "drop-off" is two tokens. Use `numbers(in:)` for numbers — these
    /// tokens break decimals apart on purpose.
    static func tokens(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Every number mentioned, as decimal strings, decimals kept whole ("1.4" stays "1.4", so an
    /// invented "4" is not hidden inside it; Antigravity, final review): digits, number words
    /// ("two" → "2"), "one and a half" → "1.5", a lone "half" → "0.5".
    static func numbers(in text: String) -> Set<String> {
        var out = Set<String>()
        let lower = text.lowercased()
        if let re = try? NSRegularExpression(pattern: #"\d+(\.\d+)?"#) {
            let ns = lower as NSString
            for m in re.matches(in: lower, range: NSRange(location: 0, length: ns.length)) {
                out.insert(ns.substring(with: m.range))
            }
        }
        let w = lower.split(whereSeparator: { !$0.isLetter }).map(String.init)
        for (i, t) in w.enumerated() {
            if t == "half" {
                if i < 3 || w[i - 1] != "a" || w[i - 2] != "and" { out.insert("0.5") }
                continue
            }
            guard let d = numberWords[t] else { continue }
            let andAHalf = i + 3 < w.count && w[i + 1] == "and" && w[i + 2] == "a" && w[i + 3] == "half"
            out.insert(andAHalf ? d + ".5" : d)
        }
        return out
    }

    /// Number words the model or `SpokenDistance` might use, as digits. Compound words
    /// ("twenty-one") are not composed: they read as "20" and "1", which is still fail-closed
    /// because both must appear in the facts. `CloudSceneGate` also reads this table.
    static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
        "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12",
        "thirteen": "13", "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
        "eighteen": "18", "nineteen": "19", "twenty": "20", "thirty": "30", "forty": "40",
        "fifty": "50", "sixty": "60", "seventy": "70", "eighty": "80", "ninety": "90", "hundred": "100",
    ]

    /// The noun's own words (minus articles) plus every Vision identifier merged into it, split on
    /// "_" ("zebra_crossing" → "zebra", "crossing").
    static func synonyms(of noun: String) -> [String] {
        let own = tokens(noun).filter { !["a", "an", "the"].contains($0) }
        let ids = groups.first { $0.noun == noun }?.ids.flatMap { $0.split(separator: "_").map(String.init) } ?? []
        return own + ids
    }

    /// Every object word the vocabulary knows (noun words minus articles, plus identifier parts),
    /// stemmed: a sentence may only use the ones that were detected.
    static let vocabularyStems: Set<String> = Set((groups.flatMap { synonyms(of: $0.noun) } + hazardWords).map(stem))

    /// Hazard words the model might invent that are not scene labels ("A cone ahead" by the trees;
    /// Antigravity final review). They are allowed only when the facts contain them.
    static let hazardWords = ["cone", "barrier", "barricade", "trench", "pothole", "hole", "curb",
                              "construction", "branch", "bike", "ladder", "scaffolding", "wire", "step"]

    /// A tiny English stem: "cars" → "car", "bushes" → "bush", "benches" → "bench", "glass" stays.
    static func stem(_ w: String) -> String {
        if w.hasSuffix("es"), w.count > 4, ["s", "sh", "ch", "x"].contains(where: { w.dropLast(2).hasSuffix($0) }) {
            return String(w.dropLast(2))
        }
        if w.hasSuffix("s"), !w.hasSuffix("ss"), w.count > 3 { return String(w.dropLast()) }
        return w
    }

    /// Recognized text worth showing the language model: at least one run of 3+ letters, and
    /// letters make up most of it. On the Street View frames Vision "read" junk like "11", "J.I",
    /// "£xJ" off road markings, and the model turned "11" into "11 meters to the edge".
    /// - Parameter texts: recognized text lines (callers pre-filter at confidence ≥ 0.5).
    /// - Returns: the lines with a run of ≥ 3 letters-or-digits and ≥ 60 % letters (whitespace
    ///   ignored), in their original order.
    /// Pinned by `streetViewModelNonsenseIsRejectedAndOCRJunkFiltered`, `blankWallsTeensAndMisreadsAreHandled`.
    public static func readableTexts(_ texts: [String]) -> [String] {
        texts.filter { t in
            let chars = t.filter { !$0.isWhitespace }
            guard !chars.isEmpty else { return false }
            let letters = chars.filter(\.isLetter).count
            // Runs of letters *or digits*: a near "EXIT" misread as "EX1T" is still text
            // (Muse); the letter-ratio gate still drops "111" and "{4J J".
            var run = 0, best = 0
            for c in t { run = (c.isLetter || c.isNumber) ? run + 1 : 0; best = max(best, run) }
            return best >= 3 && Double(letters) / Double(chars.count) >= 0.6
        }
    }

    /// The template sentence's scene part: "Ahead: a crosswalk, the street and cars." or nil.
    /// Goes through `narrationNouns`, so `max` ≤ 0 gives nil. `OnDeviceVLMClient.template` passes
    /// `max: narrationMaxItems` (two nouns); the default 3 is what the Street View tests pin.
    /// - Parameters:
    ///   - labels: Vision identifiers with confidence.
    ///   - max: most nouns said.
    /// - Returns: the sentence, or nil when nothing nameable was detected (the caller then says so).
    public static func sentence(_ labels: [(name: String, confidence: Float)], max: Int = 3) -> String? {
        let n = narrationNouns(labels, max: max)
        return n.isEmpty ? nil : "Ahead: \(list(n))."
    }
}
