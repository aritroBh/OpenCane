//
//  ThreatWatch.swift
//  CaneKitLogic
//
//  Reads what the vision model said about the scene and decides whether it described a threat to
//  the walker — a weapon, or someone behaving like a robber — worth waking the family.
//
//  Why text and not a detector: OpenCane already asks a vision-language model what is ahead
//  (`HazardPrompt`, `ScenePrompt`). That reply is the only place a gun or a knife would ever be
//  named, so this is where the decision belongs. There is no weapon classifier on the phone and
//  writing one is not a hackathon-weekend job.
//
//  ⚠ **This is the one place in OpenCane where a false positive is genuinely expensive**: it emails
//  a family that their blind relative may be being robbed. So the matching is deliberately strict:
//    · whole words only ("gunmetal", "knife-edge" and "shotgun microphone" do not match);
//    · a benign collocation cancels the match ("knife and fork", "nail gun", "toy gun");
//    · a negation before the word cancels it ("there is no weapon", "not a knife") — a model asked
//      "is anything dangerous ahead?" answers in the negative constantly;
//    · a match must be a *noun sighting*, so the phrase list is nouns, never adjectives.
//  A missed weapon is bad. A weekly false robbery alert is what makes a family mute the app, and
//  then the real one is missed too.
//
//  ⚠ It cannot be better than the model that wrote the text. The model is not a weapons expert,
//  it cannot see behind the walker, and `HazardPrompt` does not ask it about crime. Treat this as
//  "the describer happened to mention a weapon", which is exactly how the event is worded.
//
//  Owner: `HazardScanner` (app) checks each raw vision reply; `SceneDescriber` checks each answer.
//
//  Key invariants:
//    · Pure and case-insensitive; no clock (the caller rate-limits).
//    · `sighting(in:)` returns the matched word, so the event and the trip log can say what was
//      seen rather than "a threat".
//  Tests: ThreatWatchTests.swift.
//

import Foundation

/// What the model said it saw.
public struct ThreatSighting: Sendable, Equatable {
    /// The word that matched ("gun", "knife", "robber").
    public var term: String
    /// The model's sentence, kept so the alert can quote it rather than paraphrase.
    public var text: String
}

/// Weapon / assault words in vision-model output.
public enum ThreatWatch {

    /// Nouns that mean a weapon or an attacker. Nouns only: an adjective ("threatening weather")
    /// is not a sighting.
    public static let terms: [String] = [
        "gun", "handgun", "pistol", "revolver", "rifle", "shotgun", "firearm",
        "knife", "blade", "machete", "weapon",
        "robber", "robbery", "mugger", "mugging", "attacker", "assailant", "intruder",
    ]

    /// Phrases that contain a term but are not a threat. Checked before the term itself, so
    /// "knife and fork" never becomes an alert.
    public static let benignPhrases: [String] = [
        "knife and fork", "fork and knife", "butter knife", "kitchen knife", "table knife",
        "pocket knife", "nail gun", "glue gun", "water gun", "toy gun", "squirt gun",
        "spray gun", "heat gun", "gun shop", "knife shop", "shotgun microphone",
        "knife block", "cutlery",
    ]

    /// Words that, immediately before a term, invert it. A hazard model answers "no weapons
    /// visible" far more often than it reports one.
    public static let negations: [String] = [
        "no", "not", "without", "never", "isn't", "aren't", "wasn't", "no visible", "none",
    ]

    /// Words that end a negation's reach, so a new clause can still report a weapon. Without
    /// these, "no cars, but a man with a gun" would be silently swallowed by the leading "no".
    public static let clauseResets: [String] = ["but", "however", "though", "although", "yet"]

    /// The first real threat word in `text`, or nil.
    ///
    /// ⚠ A negation covers the rest of its clause, not just the next word or two. The first
    /// version looked back a fixed two words, which read "without any gun or knife" as a weapon
    /// sighting — the negation covered `gun` and then ran out before `knife`. A model listing what
    /// it did *not* see is the single most common reply shape, so the scope has to follow the
    /// clause: negation is armed by a negating word and disarmed by a sentence end or a
    /// contrasting conjunction ("no cars, **but** a man with a gun" must still alert).
    public static func sighting(in text: String) -> ThreatSighting? {
        let lower = text.lowercased()
        guard !lower.isEmpty else { return nil }

        // A benign phrase disarms the whole sentence: "he was holding a knife and fork".
        for phrase in benignPhrases where lower.contains(phrase) { return nil }

        var word = ""
        var negated = false

        /// Applies one completed word; returns the sighting if it is an armed threat term.
        func take(_ w: String) -> ThreatSighting? {
            if negations.contains(w) { negated = true; return nil }
            if clauseResets.contains(w) { negated = false; return nil }
            if terms.contains(w), !negated {
                return ThreatSighting(term: w, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }

        for character in lower {
            if character.isLetter || character == "'" {
                word.append(character)
                continue
            }
            if !word.isEmpty {
                if let hit = take(word) { return hit }
                word = ""
            }
            // A sentence ends a negation's reach; a comma does not (it usually continues a list).
            if character == "." || character == "!" || character == "?" || character == ";" {
                negated = false
            }
        }
        if !word.isEmpty, let hit = take(word) { return hit }
        return nil
    }

    /// The event for a sighting. `critical`, like a fall: if this is real the walker needs someone
    /// now, and the bot's rule is that critical reaches family.
    ///
    /// The note quotes the model rather than asserting a fact, because that is all OpenCane knows:
    /// "OpenCane's camera described: …". A family member reading it can judge for themselves.
    public static func event(_ sighting: ThreatSighting, lat: Double?, lng: Double?) -> OpenCaneEvent {
        var event = OpenCaneEvent(type: .threat, severity: .critical, lat: lat, lng: lng,
                                  note: "Possible \(sighting.term) seen. OpenCane's camera described: \(sighting.text)")
        event.extra = ["threat_term": .string(sighting.term),
                       "camera_description": .string(sighting.text)]
        return event
    }
}
