//
//  VoiceControlGrammar.swift
//  CaneKitLogic
//
//  Tier 2 of the voice shell (docs/UX.md §4.2, §4.3): everything a walker can say that is NOT one
//  of `VoiceMenu`'s eight words. The eight words are what you need while moving; this is what you
//  set up while standing — the feature switches, the cue level and place, the flashlight, and the
//  two read-backs that make the Settings screen optional ("read my settings", "what can I say").
//
//  Why this exists: a blind walker cannot flip a switch they cannot find. The Sense page carries
//  ten of them, so reaching "Hazard watch" is on the order of twenty VoiceOver swipes with a thumb
//  on a phone clamped to a sweeping cane (docs/UX.md §1). Every one of those switches now has a
//  spoken form, and `SpokenSettingsReport` says what they are set to without a screen at all.
//
//  Why it is a separate file from `VoiceMenu` rather than eight more menu items: the eight words are
//  tuned and short, spoken in the launch line, and each has a digit. A long tail of thirty settings
//  phrasings mixed into that list would dilute the thing a walker has to remember while walking.
//  The split is the design (docs/UX.md §4.2), not an accident of layout.
//
//  Key invariants:
//    · **Whole-utterance matching after `VoiceMenu.normalize`.** Never "contains". The read-back
//      line itself says "hazard watch", and `SelfHearFilter` already had to learn what happens when
//      a command can be found inside a sentence the app said (Step 55).
//    · **A false hit acts.** Four of the nine features are warning channels (drop-offs, hazard
//      watch, obstacle names, sirens), so an accidental "off" costs a warning the walker was
//      relying on. Aliases therefore stay narrow: an explicit on/off word is required for every
//      feature ("turn on signs", not "signs"), because a bare noun is what a walker says when they
//      are *asking about* something, not commanding it.
//    · **The safety floor is not here** (docs/UX.md rule 7). No utterance in this file can turn off
//      "Head height.", the `.head` haptic or the ground-hazard *warning* path. "Detect drop-offs"
//      is the walker's own opt-in detector and is theirs to switch; the head warning is not, and
//      there is deliberately no phrase for it.
//    · **"stop" is not here.** It stays `FastPathIntentClassifier` rule 1, ahead of everything
//      (`stopIsNotAControlPhrase`).
//    · **`Feature`'s raw values are `HandsFreeOption`'s raw values**, plus `torch`, which has no
//      `HandsFreeOption` (the flashlight is not a hands-free option, it is a device state).
//      `FastPathIntentClassifier.action(for:)` therefore turns eight of the nine into the existing
//      `.updateSetting(option:enabled:)` — the same action Siri and the screen already use, so a
//      switch cannot behave differently depending on how it was flipped — and `torch` into
//      `.setTorch`. `AppModel.settingsSnapshot` reads all nine through an **exhaustive switch**, so
//      a feature added here fails to compile until the read-back knows its state. Pinned on this
//      side by `featureRawValuesAreTheHandsFreeOptionNames`.
//    · Pure and nonisolated: no clock, no I/O, no state.
//
//  Owner / callers: `FastPathIntentClassifier.classify` rule 0b (after `VoiceMenu`, before the stop
//  rule — see `controlGrammarRunsAfterTheMenuAndBeforeStop`), whose actions
//  `ConversationCoordinator.executeAction` performs, and `SpokenPhrases.shellLines` (every fixed
//  line here is prefetched in the natural voice).
//  Tests: `VoiceControlGrammarTests.swift`.
//

import Foundation

/// Tier-2 voice commands: the switches, the profile, and the read-backs.
public enum VoiceControlGrammar {

    /// One tier-2 command, as matched from a whole utterance.
    public enum Command: Sendable, Equatable {
        /// Turn one feature on or off. The app speaks the change and, for an off, its consequence.
        case setFeature(Feature, on: Bool)
        /// Change how much the app volunteers.
        case setCueLevel(CueLevel)
        /// Change where the walker is (indoor clutter is quieter).
        case setCuePlace(CuePlace)
        /// Speak the state of every switch, in the order the screen shows them.
        case readSettings
        /// Speak the tier-2 grammar itself, so it is discoverable without a screen.
        case listCommands
        /// Speak the Medical ID paragraph. ⚠ Read aloud in public — never automatic, and never a
        /// step in another command's flow (docs/UX.md §4.3).
        case readMedicalID
        /// Show the voice-only screen (true) or bring every button back (false).
        /// ⚠ "full screen" is the **escape hatch** voice-only mode promises out loud
        /// (`GuideLayout.escapePhrase`): the mode hides the tab bar, so this phrase is the only way
        /// back. It must never be removed or narrowed.
        case setVoiceOnlyScreen(Bool)
        /// Drop whatever confirmation is pending and do nothing.
        case cancel
    }

    /// A switchable feature a walker can name out loud.
    ///
    /// ⚠ Raw values are `HandsFreeOption`'s raw values (`ios/CaneKit/App/HandsFreeIntents.swift`)
    /// so that the Siri surface, the trip log's `option_set.option` field and this grammar all name
    /// the same thing. `torch` is the one case with no `HandsFreeOption`: the flashlight is a device
    /// state, not a hands-free option, and it is deliberately never persisted (a pocketed torch is
    /// a dead battery and a burn risk — AGENTS.md).
    public enum Feature: String, CaseIterable, Sendable, Equatable {
        /// LiDAR curbs, holes and drop-offs. Off by default, untuned on the real cane.
        case dropOffs
        /// On-device sign reading. On by default.
        case signs
        /// The vision model checking the path ahead every 8 s while a route guides. Off by default.
        case hazardWatch
        /// Naming people ahead. Off by default, experimental.
        case namePeople
        /// Speaking obstacle names at all. Off by default since Step 36.
        case obstacleNames
        /// The direction click. On by default; only plays into headphones.
        case beacon
        /// Listening for sirens and horns (an audio *input*, hard rule 7). Not persisted.
        case sirens
        /// Nodding to start listening. Not persisted, untuned.
        case nodToTalk
        /// The flashlight. Not persisted. No `HandsFreeOption` — see the type's ⚠.
        case torch

        /// How a read-back and a confirmation name this feature.
        ///
        /// ⚠ These match `HandsFreeOption.spokenName` word for word for the eight that have one, so
        /// the walker hears the same words from Siri, from the switch and from this grammar.
        /// `torch` uses the Settings label's words. Pinned by `spokenNamesAreSentenceReady`.
        public var spokenName: String {
            switch self {
            case .dropOffs: return "Drop-off detection"
            case .signs: return "Sign reading"
            case .hazardWatch: return "Hazard watch"
            case .namePeople: return "Naming people ahead"
            case .obstacleNames: return "Obstacle names"
            case .beacon: return "The audio beacon"
            case .sirens: return "Siren and horn listening"
            case .nodToTalk: return "Nod to talk"
            case .torch: return "The flashlight"
            }
        }

        /// The same name in the middle of a list ("On: sign reading, the audio beacon."), so the
        /// read-back does not read like nine sentence fragments — `spokenName` with its
        /// start-of-sentence capital removed.
        public var listName: String {
            let name = spokenName
            return name.prefix(1).lowercased() + name.dropFirst()
        }

        /// The nouns a walker says for this feature. Narrow on purpose: each still needs an on/off
        /// word beside it (see `match`).
        ///
        /// ⚠ No noun here may be a whole `VoiceMenu` word or verb — rule 0 runs first and would
        /// win, so such a noun would be dead text pretending to work. Pinned by
        /// `noFeatureNounCollidesWithTheMenu`.
        public var nouns: [String] {
            switch self {
            case .dropOffs:
                return ["drop offs", "dropoffs", "drop off detection", "curbs", "curb detection",
                        "drop off warnings"]
            case .signs:
                return ["signs", "sign reading", "reading signs"]
            case .hazardWatch:
                return ["hazard watch", "the hazard watch", "hazard watching"]
            case .namePeople:
                return ["people", "naming people", "people names", "naming people ahead"]
            case .obstacleNames:
                return ["obstacle names", "object names", "naming obstacles", "obstacle naming"]
            case .beacon:
                return ["beacon", "the beacon", "audio beacon", "the clicking", "the click"]
            case .sirens:
                return ["sirens", "horns", "sirens and horns", "siren listening"]
            case .nodToTalk:
                return ["nod to talk", "nodding", "head nod", "nod"]
            case .torch:
                return ["flashlight", "the flashlight", "torch", "the torch", "light", "the light"]
            }
        }
    }

    // MARK: Matching

    /// A whole utterance → a tier-2 command, or nil.
    ///
    /// Order is behaviour: the fixed phrases (read-backs, cancel, level, place) are exact-set
    /// lookups and run first, then the feature form, which is the only one that parses.
    /// - Parameter transcript: the final transcript, any case or punctuation.
    /// - Returns: the command, or nil when the utterance is not one of these forms.
    public static func match(_ transcript: String) -> Command? {
        let key = VoiceMenu.normalize(transcript)
        guard !key.isEmpty else { return nil }

        if readSettingsForms.contains(key) { return .readSettings }
        if listCommandForms.contains(key) { return .listCommands }
        if readMedicalForms.contains(key) { return .readMedicalID }
        if cancelForms.contains(key) { return .cancel }
        // ⚠ Before the level and place tables and before the feature parser: this is the escape
        // hatch out of voice-only mode, and nothing may shadow it.
        if let layout = layoutForms[key] { return .setVoiceOnlyScreen(layout) }
        if let level = levelForms[key] { return .setCueLevel(level) }
        if let place = placeForms[key] { return .setCuePlace(place) }
        return feature(key)
    }

    /// The feature form: an on/off word and a feature noun, and nothing else.
    ///
    /// Accepted shapes, for noun N: "turn on N", "turn N on", "N on", "enable N", "switch on N",
    /// "switch N on", "start N", and the same with off / disable.
    ///
    /// ⚠ A bare "N" is deliberately NOT a command: "beacon" on its own is what a walker says when
    /// asking about it, and a false hit here costs a warning channel. Pinned by
    /// `aBareFeatureNounIsNotACommand`.
    /// - Parameter key: an already-normalised utterance.
    /// - Returns: `.setFeature`, or nil.
    private static func feature(_ key: String) -> Command? {
        for (on, verbs) in [(true, onVerbs), (false, offVerbs)] {
            for verb in verbs {
                // "turn on" → prefix "turn", particle "on", so "turn <noun> on" also matches.
                let words = verb.split(separator: " ")
                let particle = words.count == 2 ? String(words[1]) : nil
                let prefix = words.count == 2 ? String(words[0]) : nil
                for f in Feature.allCases {
                    for noun in f.nouns {
                        if key == "\(verb) \(noun)" { return .setFeature(f, on: on) }
                        if key == "\(noun) \(verb)" { return .setFeature(f, on: on) }
                        if let particle, let prefix,
                           key == "\(prefix) \(noun) \(particle)" { return .setFeature(f, on: on) }
                    }
                }
            }
        }
        return nil
    }

    // MARK: Alias tables

    /// Verbs that mean "on". Bare "on" is here so "beacon on" works; it is never accepted alone,
    /// because `feature` only ever matches a verb *with* a noun.
    private static let onVerbs = ["turn on", "switch on", "enable", "start", "on"]

    /// Verbs that mean "off". ⚠ "stop" is absent: `FastPathIntentClassifier` rule 1 owns it, and
    /// "stop" as an off-verb would make "stop the beacon" ambiguous with ending a route — which is
    /// the one command in this app that must never be ambiguous.
    private static let offVerbs = ["turn off", "switch off", "disable", "off"]

    /// "What is on?" — the read-back that replaces the Settings screen (docs/UX.md rule 3).
    private static let readSettingsForms: Set<String> = [
        "read my settings", "read settings", "what are my settings", "what is on", "whats on",
        "what is turned on", "read my switches", "settings report",
    ]

    /// "What can I say?" — tier-2 discovery (docs/UX.md rule 4). ⚠ Not "help": that is
    /// `VoiceMenu.Item.help`, rule 0, and reads the numbered eight.
    private static let listCommandForms: Set<String> = [
        "what can i say", "list commands", "what else can i say", "more commands",
        "what commands are there", "other commands",
    ]

    /// Reading the Medical ID out loud. ⚠ Explicit only, never a step in another flow: it is a
    /// blood type and an emergency contact's name spoken on a public sidewalk (docs/UX.md §4.3).
    private static let readMedicalForms: Set<String> = [
        "read my medical id", "read my medical i d", "medical id", "medical i d",
        "read my emergency information", "announce my medical id",
    ]

    /// Dropping a pending confirmation. ⚠ These overlap `VoiceMenu.confirmation`'s "no" forms,
    /// which is correct and not a conflict: rule 0 runs first, so while a confirmation is pending
    /// these words cancel it there, and they only reach here when nothing is pending.
    private static let cancelForms: Set<String> = [
        "cancel", "never mind", "nevermind", "forget it", "cancel that",
    ]

    /// Cue level by name. ⚠ "quiet" and its close forms are absent: they are `VoiceMenu.Item.quiet`,
    /// matched by rule 0, which produces the same level (`quietStaysTheMenusWord`).
    private static let levelForms: [String: CueLevel] = [
        "standard": .standard, "standard cues": .standard, "standard mode": .standard,
        "normal cues": .standard,
        "detailed": .detailed, "detailed cues": .detailed, "detailed mode": .detailed,
        "tell me everything": .detailed,
    ]

    /// The voice-only screen, on and off (docs/UX.md §4.4).
    ///
    /// ⚠ `GuideLayout.escapePhrase` is a key here **by construction**, not by being typed twice:
    /// voice-only mode hides the tab bar and promises this exact phrase out loud, so the promise and
    /// the parser share the bytes (`theEscapeHatchIsNamedInTheLineThatNeedsIt`). Several plain
    /// synonyms sit beside it because this is the one phrase a walker may need while unable to see
    /// that anything is wrong, and a narrow alias list is the wrong trade *here* specifically.
    private static let layoutForms: [String: Bool] = [
        GuideLayout.escapePhrase: false,
        "show the buttons": false, "show buttons": false, "bring the buttons back": false,
        "normal screen": false, "full screen mode": false, "buttons back": false,
        "voice only": true, "voice only screen": true, "voice only mode": true,
        "hide the buttons": true, "just the microphone": true,
    ]

    /// Cue place by name.
    private static let placeForms: [String: CuePlace] = [
        "indoors": .indoors, "indoor mode": .indoors, "i am indoors": .indoors,
        "im indoors": .indoors, "we are inside": .indoors, "inside": .indoors,
        "outdoors": .outdoors, "outdoor mode": .outdoors, "i am outdoors": .outdoors,
        "im outdoors": .outdoors, "we are outside": .outdoors, "outside": .outdoors,
    ]

    // MARK: Spoken lines

    /// What "what can I say" reads: the tier-2 grammar in one line.
    ///
    /// Deliberately shapes rather than every alias: reading thirty phrasings at a walker would
    /// spend the whole auditory budget (docs/auditory-load.md) teaching them something they will
    /// use once. One example of each shape is enough to generalise from. Pinned by
    /// `theCommandListNamesEveryFeatureAndBothReadBacks`.
    public static let listLine =
        "You can say: turn on, or turn off, then drop-offs, signs, hazard watch, obstacle names, "
        + "people, the beacon, sirens, nodding, or the flashlight. Say quiet, standard, or detailed "
        + "cues. Say indoors or outdoors. Say read my settings, or read my medical I D. Say voice "
        + "only, or full screen. Say help for the main list, or stop to end a route."

    /// Spoken for `.cancel` when there was nothing to cancel — silence would leave the walker
    /// unsure whether the app heard them at all (docs/UX.md rule 2, "never a silent success").
    public static let cancelledLine = "Nothing to cancel."

    /// Spoken for `.readMedicalID` when the Medical ID has never been filled in. Names the screen,
    /// because this is one of the few things that genuinely needs a sighted helper once
    /// (docs/UX.md §4.3).
    public static let medicalUnavailableLine =
        "Your Medical ID is not filled in yet. It is on the Profile tab, and it needs a helper once."

    /// Every fixed line this grammar can speak, for the natural-voice prefetch.
    /// ⚠ Included in `SpokenPhrases.shellLines` (`everyControlLineIsPrefetched`); a new fixed line
    /// here that is not in this array comes out in Apple's system voice the first time it is said.
    public static let fixedLines: [String] = [listLine, cancelledLine, medicalUnavailableLine]
}
