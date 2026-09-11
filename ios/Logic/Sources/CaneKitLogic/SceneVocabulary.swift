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
//  Used by OnDeviceVLMClient (template sentence and the facts handed to Apple's on-device model).
//  Tests: SceneVocabularyTests.swift (fixtures are the real Street View labels).
//

import Foundation

public enum SceneVocabulary {

    /// One spoken noun, its rank (lower is said first) and every Vision identifier that means it.
    struct Group: Sendable {
        let rank: Int
        let noun: String
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
        // "the street" and "cars" when only three nouns are said).
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
    /// - Parameters:
    ///   - labels: Vision identifiers with confidence (any order).
    ///   - minConfidence: labels below this are ignored.
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

    /// "a crosswalk, the street and cars" (Oxford-free, spoken).
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
    public static func isFaithful(_ sentence: String, facts: String, nouns: [String]) -> Bool {
        let lower = sentence.lowercased()
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard !words.isEmpty, words.count <= 30 else { return false }
        if !nouns.isEmpty {
            let heads = nouns.compactMap { $0.lowercased().split(separator: " ").last.map(String.init) }
            guard heads.contains(where: { h in words.contains { $0 == h || $0.hasPrefix(h) || h.hasPrefix($0) && $0.count >= 4 } })
            else { return false }
        }
        let numbers = words.filter { $0.allSatisfy(\.isNumber) }
        let factNumbers = Set(facts.split(whereSeparator: { !$0.isNumber }).map(String.init))
        return numbers.allSatisfy { factNumbers.contains(String($0)) }
    }

    /// The template sentence's scene part: "Ahead: a crosswalk, the street and cars." or nil.
    public static func sentence(_ labels: [(name: String, confidence: Float)]) -> String? {
        let n = nouns(labels)
        return n.isEmpty ? nil : "Ahead: \(list(n))."
    }
}
