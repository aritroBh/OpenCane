//
//  VoiceMenu.swift
//  CaneKitLogic
//
//  The eight words of the voice shell (Step 56): route, where am I, describe, status, repeat,
//  quiet, help, emergency — each also reachable by its digit, one to eight.
//
//  Why this exists: the first cane-mounted walk (2026-09-13) showed the app was usable only with
//  eyes — four tabs, a 108 pt Talk tile, one utterance at a time, then nothing. A blind walker
//  needs a *phone-menu*: a short spoken list, then one word or one digit, matched on the phone in
//  under a millisecond and never sent to the cloud. This file is that grammar. Words are primary,
//  digits are aliases (all reviewers; the founder asked for digits — both work, "help" reads the
//  numbered list).
//
//  Key invariants:
//    · Whole-utterance matching after normalisation (lower-case, punctuation stripped, whitespace
//      collapsed). Never "contains": the menu line itself contains "route", and the self-hear
//      filter already had to learn that lesson (`SelfHearFilter`).
//    · No homophones: "one"/"1" match, "won" does not; "two"/"2" match, "to"/"too" do not. A
//      recogniser that heard "to" heard a preposition, not a command, and a false hit *acts*.
//    · "stop" is not here. It stays `FastPathIntentClassifier` rule 1 (exact phrases) so the
//      classifier's order — stop before everything — is unchanged (`stopIsNotAMenuWord`).
//    · Every line spoken from here (`menuLine`, `helpLine`, each `confirmationLine`) is in
//      `SpokenPhrases.shellLines`, so it is prefetched in the natural voice by bytes
//      (`everyLineTheShellCanSpeakIsPrefetched`).
//    · Pure and nonisolated; no clock, no I/O.
//
//  Owner / callers: `FastPathIntentClassifier.classify` (rule 0: `match`, `verb`, `confirmation`),
//  `ConversationCoordinator.executeAction` (`confirmationLine`, `helpLine`), `AppModel` (speaks
//  `menuLine` after "OpenCane ready."), `SpokenPhrases.shellLines`.
//  Tests: VoiceMenuTests.swift (9).
//

import Foundation

/// The IVR grammar: items, digits, the two spoken lists, and the three parsers.
public enum VoiceMenu {

    /// One menu item, in spoken order. Raw values are the trip-log `ivr` field on `conv_turn`
    /// (`ConversationCoordinator`), so they are stable names, not display strings.
    public enum Item: String, CaseIterable, Sendable, Equatable {
        /// "route" / one: start the demo route (ISR → CIF); while navigating, the route status.
        case route
        /// "where am I" / two: describe the scene (the camera path, same as `describe`).
        case whereAmI
        /// "describe" / three: describe the scene.
        case describe
        /// "status" / four: the spoken status report (`AppModel.speakStatus`).
        case status
        /// "repeat" / five: say the current instruction again.
        case repeatLast
        /// "quiet" / six: cue level Quiet (`CueLevel.quiet`).
        case quiet
        /// "help" / seven: read the numbered list (`helpLine`).
        case help
        /// "emergency" / eight: the confirmation-gated emergency call (`EmergencyConfirm`).
        case emergency

        /// The fixed line the shell speaks for this item when the app effect does not speak for
        /// itself (`ConversationCoordinator.executeAction` returns it as the response). Short, so a
        /// route line behind it is not held; cached, so it comes out in the natural voice.
        /// `quiet` reuses `CueLevel.quiet.spokenLine` byte for byte — the level change speaks that
        /// line itself when the level actually changes, and the shell speaks the same line when it
        /// was already Quiet. `help` is `helpLine`; `emergency` is the no-contact line (the prompt
        /// with a name and number is per profile, `EmergencyConfirm.promptLine`).
        /// Pinned by `confirmationLinesAreShortAndReuseCueText`.
        public var confirmationLine: String {
            switch self {
            case .route: return "Starting the route."
            case .whereAmI, .describe: return "Looking."
            case .status: return "Status."
            case .repeatLast: return "Repeating."
            case .quiet: return CueLevel.quiet.spokenLine
            case .help: return VoiceMenu.helpLine
            case .emergency: return EmergencyConfirm.noContactLine
            }
        }
    }

    /// Verbs the shell understands that are not menu items: `next` (skip a waypoint), `standard`
    /// and `detailed` (cue levels). Whole-utterance like the items (`extraVerbsAreWholeUtteranceToo`).
    public enum Verb: String, Sendable, Equatable {
        case next, standard, detailed
    }

    /// The spoken word of an item, as it appears in `menuLine` and `helpLine`.
    /// - Parameter item: the menu item.
    /// - Returns: "route", "where am I", "describe", "status", "repeat", "quiet", "help", "emergency".
    public static func word(_ item: Item) -> String {
        switch item {
        case .route: return "route"
        case .whereAmI: return "where am I"
        case .describe: return "describe"
        case .status: return "status"
        case .repeatLast: return "repeat"
        case .quiet: return "quiet"
        case .help: return "help"
        case .emergency: return "emergency"
        }
    }

    /// The item's digit, 1…8 in menu order. Pinned by `everyItemHasAWordAndADigit`.
    public static func digit(_ item: Item) -> Int {
        Item.allCases.firstIndex(of: item)! + 1
    }

    /// The digit as the recogniser spells it out ("one" … "eight"); used in `helpLine` and as
    /// the spoken alias. No homophones are ever added here.
    public static func digitWord(_ item: Item) -> String {
        digitWords[digit(item) - 1]
    }

    /// "one" … "eight", index = digit − 1.
    private static let digitWords = ["one", "two", "three", "four", "five", "six", "seven", "eight"]

    /// The launch menu, spoken once after "OpenCane ready." and again on a bare "help"? No — on
    /// "help" the numbered `helpLine` is read; this is the short form. ⚠ Exact bytes are pinned by
    /// `menuLineIsTheEightWords`: it is prefetched and matched by the self-hear filter as clauses.
    public static let menuLine = "Say route, where am I, describe, status, repeat, quiet, help, or emergency."

    /// The numbered list read on "help" / seven: "One, route. Two, where am I. … Eight, emergency.
    /// Or say stop to end the route, or what can I say for more." Built from the items so it cannot
    /// drift from them (`helpListsEveryItemWithItsDigit`).
    ///
    /// ⚠ The tail names tier 2 (`VoiceControlGrammar`, docs/UX.md rule 4). Without it the wider
    /// grammar — every feature switch, the cue place, the read-backs — is invisible: a walker who
    /// only ever hears the eight words has no reason to believe there is anything else to say. This
    /// is the one place the two tiers are connected, so do not trim it.
    public static let helpLine: String = {
        let entries = Item.allCases.map { "\(digitWord($0).capitalized), \(word($0))." }
        return entries.joined(separator: " ") + " Or say stop to end the route, or what can I say for more."
    }()

    /// Recogniser output → item, whole utterance only. Words, digits as words, digits as
    /// numerals, and a few close spoken forms per item (kept narrow: a false hit acts).
    /// - Parameter transcript: the final transcript, any case or punctuation.
    /// - Returns: the item, or nil when the utterance is not exactly one of its forms.
    public static func match(_ transcript: String) -> Item? {
        let key = normalize(transcript)
        guard !key.isEmpty else { return nil }
        return aliases[key]
    }

    /// The three extra verbs, whole utterance only.
    /// - Parameter transcript: the final transcript.
    /// - Returns: `.next`, `.standard`, `.detailed`, or nil.
    public static func verb(_ transcript: String) -> Verb? {
        extraVerbs[normalize(transcript)]
    }

    /// Yes / no for the emergency prompt (`EmergencyConfirm`), whole utterance only.
    /// - Parameter transcript: the final transcript.
    /// - Returns: true for an affirmative, false for a refusal or cancel, nil otherwise.
    public static func confirmation(_ transcript: String) -> Bool? {
        let key = normalize(transcript)
        if yesForms.contains(key) { return true }
        if noForms.contains(key) { return false }
        return nil
    }

    /// Lower-case, drop everything but letters, digits and spaces, collapse whitespace. Apostrophes
    /// are dropped too, so "don't" normalises to "dont" (the alias tables use that spelling).
    /// - Parameter text: raw transcript.
    /// - Returns: the lookup key.
    public static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = ""
        var pendingSpace = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.unicodeScalars.append(scalar)
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingSpace = true
            }
            // Punctuation inside a word ("don't") is dropped without inserting a space.
        }
        return out
    }

    // MARK: Alias tables

    /// Every accepted whole utterance → item. Words first, then digits, then the close spoken forms
    /// worth keeping from the first pass (Gemini's list, trimmed: "call 911" was dropped — the
    /// app calls the *emergency contact*, and the prompt must not sound like 911).
    private static let aliases: [String: Item] = {
        var table: [String: Item] = [:]
        for item in Item.allCases {
            table[normalize(word(item))] = item
            table[digitWord(item)] = item
            table[String(digit(item))] = item
        }
        let extra: [Item: [String]] = [
            // Not "route to cif": that is rule 14's gazetteer route to the CIF entrance.
            .route: ["start route", "start the route", "start my route"],
            .whereAmI: ["where am i right now", "current location", "where are we"],
            // Not "what is ahead": a scene *question* keeps the grounded question path.
            .describe: ["describe scene", "describe the scene"],
            .status: ["status check", "check status", "tell me status", "status report"],
            .repeatLast: ["say again", "say that again", "repeat instruction", "what did you say",
                          "repeat that"],
            .quiet: ["quiet cues", "quiet mode"],
            // Not "help me": a walker in trouble says it, and the menu is the wrong answer.
            // ⚠ "what can i say" moved to `VoiceControlGrammar` (docs/UX.md §4.3): it is the
            // natural question for the *long* list, and answering it with the eight words a walker
            // has already heard at launch was the wrong list. `helpLine` now points at it.
            .help: ["options", "menu"],
            .emergency: ["call emergency", "call for help", "call my emergency contact"],
        ]
        for (item, forms) in extra {
            for form in forms { table[normalize(form)] = item }
        }
        return table
    }()

    /// Whole utterances (normalised) for the three extra verbs: next, standard, detailed.
    /// Public so the docs table and tests read the same list the matcher uses.
    public static let extraVerbs: [String: Verb] = [
        "next": .next, "next waypoint": .next, "skip waypoint": .next, "skip": .next,
        "standard": .standard, "standard cues": .standard, "standard mode": .standard,
        "detailed": .detailed, "detailed cues": .detailed, "detailed mode": .detailed,
    ]

    /// Affirmatives for the emergency prompt.
    private static let yesForms: Set<String> = [
        "yes", "yeah", "yep", "yes please", "confirm", "yes call", "call", "do it",
    ]

    /// Refusals for the emergency prompt. Bare "cancel" is deliberately not one (review 2026-09-13,
    /// OpenCode): mid-route it meant "stop" and answered "Nothing to confirm."; it goes on to the
    /// rest of the classifier ("cancel route" stops).
    private static let noForms: Set<String> = [
        "no", "nope", "no cancel", "dont call", "do not call", "cancel call", "never mind",
    ]
}
