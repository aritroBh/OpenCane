//
//  VoiceControlGrammarTests.swift
//  CaneKitLogicTests
//
//  Tier 2 of the voice shell: what a walker can say to reach a switch without finding it
//  (docs/UX.md §4.3), and the read-back that replaces the Settings screen.
//
//  What these tests are actually protecting: a false hit *acts*. Four of the nine features are
//  warning channels, so an utterance that turns one off by accident costs the walker a warning they
//  were relying on. Most of this file is therefore about what must NOT match.
//

import Testing
@testable import CaneKitLogic

// MARK: - Feature naming and the app coupling

/// ⚠ `Feature`'s raw values are `HandsFreeOption`'s raw values (app side,
/// `ios/CaneKit/App/HandsFreeIntents.swift`) plus `torch`, so Siri, the trip log's
/// `option_set.option` field and this grammar all name the same thing. This asserts the exact set:
/// renaming a case here without renaming it there silently stops a switch from being reachable by
/// voice, and the app's own `performVoiceControl` switch is exhaustive so it cannot drift the other
/// way.
@Test func featureRawValuesAreTheHandsFreeOptionNames() {
    let expected: Set<String> = ["dropOffs", "signs", "hazardWatch", "namePeople", "obstacleNames",
                                "beacon", "sirens", "nodToTalk", "torch"]
    #expect(Set(VoiceControlGrammar.Feature.allCases.map(\.rawValue)) == expected)
}

/// Every feature can start a sentence and sit in a list without reading as a fragment.
@Test func spokenNamesAreSentenceReady() {
    for f in VoiceControlGrammar.Feature.allCases {
        #expect(!f.spokenName.isEmpty)
        #expect(f.spokenName.first!.isUppercase)
        #expect(f.listName.first!.isLowercase)
        // Not a sentence of its own: the report supplies the punctuation.
        #expect(!f.spokenName.hasSuffix("."))
    }
}

/// ⚠ Rule 0 (`VoiceMenu`) runs first, so a feature noun that is also a whole menu word, digit word
/// or extra verb would be dead text pretending to be a command. "nod" is fine; "quiet" would not be.
@Test func noFeatureNounCollidesWithTheMenu() {
    for f in VoiceControlGrammar.Feature.allCases {
        for noun in f.nouns {
            #expect(VoiceMenu.match(noun) == nil, "\(noun) is already a menu word")
            #expect(VoiceMenu.verb(noun) == nil, "\(noun) is already a menu verb")
            #expect(VoiceMenu.confirmation(noun) == nil, "\(noun) is already a yes/no")
        }
    }
}

// MARK: - What matches

/// The four accepted shapes, for one feature each, so a walker's natural word order works.
@Test func theFourFeatureShapesAllMatch() {
    #expect(VoiceControlGrammar.match("turn on the beacon") == .setFeature(.beacon, on: true))
    #expect(VoiceControlGrammar.match("turn the beacon on") == .setFeature(.beacon, on: true))
    #expect(VoiceControlGrammar.match("beacon on") == .setFeature(.beacon, on: true))
    #expect(VoiceControlGrammar.match("enable signs") == .setFeature(.signs, on: true))

    #expect(VoiceControlGrammar.match("turn off hazard watch") == .setFeature(.hazardWatch, on: false))
    #expect(VoiceControlGrammar.match("turn hazard watch off") == .setFeature(.hazardWatch, on: false))
    #expect(VoiceControlGrammar.match("hazard watch off") == .setFeature(.hazardWatch, on: false))
    #expect(VoiceControlGrammar.match("disable hazard watch") == .setFeature(.hazardWatch, on: false))
}

/// Case and punctuation are the recogniser's business, not the walker's.
@Test func matchingIgnoresCaseAndPunctuation() {
    #expect(VoiceControlGrammar.match("Turn On The Flashlight!") == .setFeature(.torch, on: true))
    #expect(VoiceControlGrammar.match("  read my settings.  ") == .readSettings)
    #expect(VoiceControlGrammar.match("What can I say?") == .listCommands)
}

/// Every one of the nine features is reachable both ways. This is docs/UX.md rule 1 — voice
/// completeness — asserted rather than asserted-about.
@Test func everyFeatureIsReachableOnAndOff() {
    for f in VoiceControlGrammar.Feature.allCases {
        let noun = f.nouns[0]
        #expect(VoiceControlGrammar.match("turn on \(noun)") == .setFeature(f, on: true))
        #expect(VoiceControlGrammar.match("turn off \(noun)") == .setFeature(f, on: false))
    }
}

/// The profile words, and the read-backs.
@Test func profileAndReadBackFormsMatch() {
    #expect(VoiceControlGrammar.match("standard cues") == .setCueLevel(.standard))
    #expect(VoiceControlGrammar.match("detailed") == .setCueLevel(.detailed))
    #expect(VoiceControlGrammar.match("tell me everything") == .setCueLevel(.detailed))
    #expect(VoiceControlGrammar.match("indoors") == .setCuePlace(.indoors))
    #expect(VoiceControlGrammar.match("we are outside") == .setCuePlace(.outdoors))
    #expect(VoiceControlGrammar.match("what is on") == .readSettings)
    #expect(VoiceControlGrammar.match("list commands") == .listCommands)
    #expect(VoiceControlGrammar.match("read my medical id") == .readMedicalID)
    #expect(VoiceControlGrammar.match("never mind") == .cancel)
}

// MARK: - What must NOT match

/// ⚠ The most important test in the file. A bare noun is what a walker says when they are *asking*
/// about a feature ("beacon?", "hazard watch"), and turning a warning channel off because of it is
/// the failure this grammar exists to avoid. A bare noun goes to the cloud as a question instead.
@Test func aBareFeatureNounIsNotACommand() {
    for f in VoiceControlGrammar.Feature.allCases {
        for noun in f.nouns {
            #expect(VoiceControlGrammar.match(noun) == nil, "bare \(noun) acted")
        }
    }
}

/// ⚠ "stop" belongs to `FastPathIntentClassifier` rule 1 and nothing else. If any stop phrase ever
/// matched here, ending a route would become ambiguous with turning something off — and rule 0b runs
/// before rule 1, so this grammar would win.
@Test func stopIsNotAControlPhrase() {
    for phrase in ["stop", "stop route", "stop navigating", "stop navigation", "cancel route",
                   "end route", "stop the beacon", "stop signs"] {
        #expect(VoiceControlGrammar.match(phrase) == nil, "\(phrase) matched the control grammar")
    }
}

/// A sentence that merely *contains* a command is not a command. The read-back line itself contains
/// "hazard watch" and "the beacon", and `SelfHearFilter` (Step 55) is the precedent: a "contains"
/// matcher makes the app act on its own words.
@Test func aSentenceContainingACommandIsNotACommand() {
    for phrase in ["is the beacon on", "why did you turn off hazard watch",
                   "the flashlight is on isnt it", "i want to turn on the beacon later",
                   "turn on the beacon and start the route"] {
        #expect(VoiceControlGrammar.match(phrase) == nil, "\(phrase) acted")
    }
}

/// ⚠ "quiet" stays the menu's word (rule 0). Both paths produce the same level, so this is about
/// keeping one owner for the utterance, not about behaviour differing.
@Test func quietStaysTheMenusWord() {
    #expect(VoiceControlGrammar.match("quiet") == nil)
    #expect(VoiceMenu.match("quiet") == .quiet)
    #expect(FastPathIntentClassifier.classify(query: "quiet") == .setCueLevel(.quiet))
}

/// ⚠ "what can I say" used to be a `.help` alias, which answered the question for the *long* list
/// with the eight words the walker had already heard at launch. Tier 2 owns it now, and `helpLine`
/// names it so the wider grammar is reachable (docs/UX.md rule 4). Both halves asserted here so
/// neither can drift back.
@Test func whatCanISayBelongsToTierTwo() {
    #expect(VoiceMenu.match("what can i say") == nil)
    #expect(VoiceControlGrammar.match("what can i say") == .listCommands)
    #expect(VoiceMenu.helpLine.contains("what can I say"))
    // "help" still means the eight.
    #expect(VoiceMenu.match("help") == .help)
    #expect(VoiceMenu.match("options") == .help)
    #expect(VoiceMenu.match("menu") == .help)
}

/// Open questions still reach the model. A grammar that swallowed these would make the app stupider,
/// not more accessible.
@Test func openQuestionsAreStillLeftAlone() {
    for phrase in ["what is in front of me", "how far to the library", "is it raining",
                   "who is that", "what does that sign say"] {
        #expect(VoiceControlGrammar.match(phrase) == nil, "\(phrase) was swallowed")
    }
}

// MARK: - The classifier's rule order

/// Rule 0 (menu) → rule 0b (this grammar) → rule 1 (stop). The order is behaviour: the menu owns its
/// eight words, this grammar owns the switches, and no stop phrase may be taken by either.
@Test func controlGrammarRunsAfterTheMenuAndBeforeStop() {
    // Rule 0 still wins for its own words.
    #expect(FastPathIntentClassifier.classify(query: "help") == .help)
    #expect(FastPathIntentClassifier.classify(query: "route") == .startDefaultRoute)
    // Rule 0b reaches the switches.
    #expect(FastPathIntentClassifier.classify(query: "turn off hazard watch")
            == .updateSetting(option: "hazardWatch", enabled: false))
    #expect(FastPathIntentClassifier.classify(query: "read my settings") == .readSettings)
    #expect(FastPathIntentClassifier.classify(query: "what can i say") == .listCommands)
    #expect(FastPathIntentClassifier.classify(query: "turn on the flashlight")
            == .setTorch(on: true))
    // Rule 1 still owns stop.
    #expect(FastPathIntentClassifier.classify(query: "stop") == .stopRoute)
    #expect(FastPathIntentClassifier.classify(query: "end route") == .stopRoute)
}

/// The older, looser rules 2–5b are unchanged: they match on substrings and accept phrasings rule 0b
/// refuses ("please turn off the drop offs"), and they must keep doing so — rule 0b is additive.
@Test func theOlderSettingsRulesStillWork() {
    #expect(FastPathIntentClassifier.classify(query: "silence cane") == .silenceCane(silenced: true))
    #expect(FastPathIntentClassifier.classify(query: "please turn off the drop off warnings")
            == .updateSetting(option: "dropOffs", enabled: false))
    #expect(FastPathIntentClassifier.classify(query: "how is the battery")
            == .answerStatus(aspect: .battery))
}

// MARK: - The spoken list

/// "What can I say" has to name every feature and both read-backs, or the grammar is invisible
/// (docs/UX.md rule 4) — and an invisible command is a command nobody uses.
@Test func theCommandListNamesEveryFeatureAndBothReadBacks() {
    let line = VoiceControlGrammar.listLine.lowercased()
    for fragment in ["turn on", "turn off", "drop-offs", "signs", "hazard watch", "obstacle names",
                     "people", "the beacon", "sirens", "nodding", "the flashlight",
                     "quiet", "standard", "detailed", "indoors", "outdoors",
                     "read my settings", "medical i d", "help", "stop"] {
        #expect(line.contains(fragment), "the command list never mentions \(fragment)")
    }
}

/// Every fixed line is prefetched in the natural voice, or the walker hears Apple's voice the first
/// time they ask what they can say (`SpeechQueue`, Step 54).
@Test func everyControlLineIsPrefetched() {
    let shell = Set(SpokenPhrases.shellLines)
    for line in VoiceControlGrammar.fixedLines {
        #expect(shell.contains(line), "not prefetched: \(line)")
    }
    for line in SpokenSettingsReport.fixedLines {
        #expect(shell.contains(line), "not prefetched: \(line)")
    }
    for line in GuideLayout.spokenLines {
        #expect(shell.contains(line), "not prefetched: \(line)")
    }
    for line in CuePlace.allCases.map(\.spokenLine) {
        #expect(shell.contains(line), "not prefetched: \(line)")
    }
}

// MARK: - Settings report

@Suite("Settings report") struct SettingsReportTests {

    /// Every switch on, so the "off" group is absent and the "on" group is complete.
    private var allOn: SpokenSettingsReport.Snapshot {
        .init(level: .detailed, place: .outdoors, hapticsSilenced: false,
              features: Dictionary(uniqueKeysWithValues:
                VoiceControlGrammar.Feature.allCases.map { ($0, true) }))
    }

    /// The shipped defaults: signs and beacon on, everything else off.
    private var defaults: SpokenSettingsReport.Snapshot {
        .init(level: .detailed, place: .outdoors, hapticsSilenced: false,
              features: [.signs: true, .beacon: true])
    }

    /// ⚠ A walker who stops listening after four seconds must already have heard the part that
    /// changes whether they are being warned: the level, the place, and the haptics state.
    @Test func theReportLeadsWithTheSafetyState() {
        let line = SpokenSettingsReport.line(defaults)
        #expect(line.hasPrefix("Detailed cues, outdoors. Cane haptics on."))
    }

    /// Every feature is named exactly once, whatever its value. A read-back that omits a switch
    /// reads as "that feature does not exist".
    @Test func everyFeatureIsReportedExactlyOnce() {
        let line = SpokenSettingsReport.line(defaults)
        for f in VoiceControlGrammar.Feature.allCases {
            let hits = line.components(separatedBy: f.listName).count - 1
            #expect(hits == 1, "\(f.rawValue) appears \(hits) times")
        }
    }

    /// A key the app did not supply reads as off, not as absent: a feature the app could not read is
    /// a feature the walker is not getting, and saying nothing about it would be the dangerous half.
    @Test func aMissingKeyReadsAsOff() {
        let line = SpokenSettingsReport.line(defaults)
        #expect(line.contains("On: sign reading, the audio beacon."))
        #expect(line.contains("Off: drop-off detection"))
        #expect(line.contains("nod to talk"))
    }

    /// With everything on there is no "Off:" group at all, and no stray empty clause.
    @Test func nothingOffMeansNoOffGroup() {
        let line = SpokenSettingsReport.line(allOn)
        #expect(!line.contains("Off:"))
        #expect(!line.contains("  "))
        #expect(line.contains("On: drop-off detection"))
    }

    /// Nothing on says so in words rather than reading an empty list.
    @Test func nothingOnSaysSo() {
        let line = SpokenSettingsReport.line(
            .init(level: .quiet, place: .indoors, hapticsSilenced: false, features: [:]))
        #expect(line.contains("Nothing else is on."))
        #expect(line.hasPrefix("Quiet cues, indoors."))
    }

    /// Silencing is a mode, not an absence: it routes obstacle cues to the watch and to speech
    /// (AGENTS.md), and a walker who cannot feel the cane needs to know which of those it is.
    @Test func silencedHapticsSayWhereTheCuesWent() {
        var s = defaults
        s.hapticsSilenced = true
        let line = SpokenSettingsReport.line(s)
        #expect(line.contains("Cane haptics are silenced; obstacles go to the watch and to speech."))
    }

    /// The layout mode is named, because a walker who cannot see the tab bar has to be able to
    /// ask whether it is gone (docs/UX.md §4.4). Default of the snapshot is off — the shipped default.
    @Test func theReportNamesTheVoiceOnlyLayout() {
        #expect(SpokenSettingsReport.line(defaults).contains("Voice-only screen off."))
        var on = defaults
        on.voiceOnly = true
        #expect(SpokenSettingsReport.line(on).contains("Voice-only screen on."))
    }

    /// ⚠ Every report ends by promising the safety floor. There is deliberately no switch for
    /// head-height warnings (docs/UX.md rule 7), so their absence from the lists would otherwise
    /// read as "off" — the single most dangerous thing this line could imply.
    @Test func theReportPromisesTheSafetyFloor() {
        for s in [allOn, defaults] {
            #expect(SpokenSettingsReport.line(s).hasSuffix(SpokenSettingsReport.alwaysOnClause))
        }
        #expect(SpokenSettingsReport.alwaysOnClause == "Head-height warnings are always on.")
    }

    /// It is one line, so `SpeechResume` can cut and resume it by clause, and it stays inside the
    /// budget a `.scene` line may spend (docs/auditory-load.md). 400 characters is ~25 s of speech;
    /// past that the read-back has become a monologue and needs grouping, not a bigger number. [H]
    @Test func theReportIsOneLineAndStaysShortEnoughToBeUseful() {
        let line = SpokenSettingsReport.line(defaults)
        #expect(!line.contains("\n"))
        #expect(line.count < 400, "the settings report is \(line.count) characters")
        // Clause enders, so a cut line resumes mid-report rather than from the first word.
        #expect(line.contains(". "))
    }
}
