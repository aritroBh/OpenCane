//
//  VoiceMenuTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins VoiceMenu.swift — the eight-word IVR grammar of the voice shell (Step 56).
//
//  Why these are the tests: a blind walker hears the menu once and then speaks one word or one
//  digit. The failure modes are (a) a menu word matched *inside* a sentence ("the route is long"
//  starting the demo route), (b) a homophone the recogniser produces for a digit ("won", "to",
//  "for") acting as a command, (c) the spoken menu and help drifting from the items they list, and
//  (d) "stop" — the one word that must stay an exact-phrase rule of its own — being swallowed here.
//
//  Source pinned: `ios/Logic/Sources/CaneKitLogic/VoiceMenu.swift` (`VoiceMenu.Item`, `word(_:)`,
//  `digit(_:)`, `helpLine`, `match(_:)`, `confirmation(_:)`, `verb(_:)`,
//  `Item.confirmationLine`). Callers: `FastPathIntentClassifier.classify` rule 0 (app path:
//  `ConversationCoordinator.handleQuery`), `AppModel` (no launch menu since Step 67),
//  `SpokenPhrases.shellLines` (prefetches every line here).
//

import Testing
@testable import CaneKitLogic

@Suite("Voice menu — the eight words")
struct VoiceMenuTests {

    /// Eight items, each with a non-empty word and a digit 1…8 in menu order, digits unique.
    @Test func everyItemHasAWordAndADigit() {
        #expect(VoiceMenu.Item.allCases.count == 8)
        var digits = Set<Int>()
        for (index, item) in VoiceMenu.Item.allCases.enumerated() {
            #expect(!VoiceMenu.word(item).isEmpty)
            #expect(VoiceMenu.digit(item) == index + 1)
            digits.insert(VoiceMenu.digit(item))
        }
        #expect(digits == Set(1...8))
    }

    /// Whole-utterance only, after normalisation: case, end punctuation and extra spaces are
    /// ignored; a word inside a sentence is not a command.
    @Test func wordsMatchWholeUtteranceOnly() {
        #expect(VoiceMenu.match("route") == .route)
        #expect(VoiceMenu.match("Route.") == .route)
        #expect(VoiceMenu.match("  Where am I?  ") == .whereAmI)
        #expect(VoiceMenu.match("where  am   i") == .whereAmI)
        #expect(VoiceMenu.match("the route is long") == nil)
        #expect(VoiceMenu.match("help me find the route") == nil)
        #expect(VoiceMenu.match("status report please") == nil)
        #expect(VoiceMenu.match("") == nil)
    }

    /// Digits as words and as numerals are aliases; homophones are deliberately not.
    @Test func digitsAreAliases() {
        let expected: [(String, String, VoiceMenu.Item)] = [
            ("one", "1", .route), ("two", "2", .whereAmI), ("three", "3", .describe),
            ("four", "4", .status), ("five", "5", .repeatLast), ("six", "6", .quiet),
            ("seven", "7", .help), ("eight", "8", .emergency),
        ]
        for (word, numeral, item) in expected {
            #expect(VoiceMenu.match(word) == item, "\(word)")
            #expect(VoiceMenu.match(numeral) == item, "\(numeral)")
        }
        for homophone in ["won", "to", "too", "for", "ate", "tree", "sex"] {
            #expect(VoiceMenu.match(homophone) == nil, "\(homophone)")
        }
        #expect(VoiceMenu.match("9") == nil)
        #expect(VoiceMenu.match("0") == nil)
    }

    /// The help line names every item with its digit, in order, and ends with the stop reminder.
    @Test func helpListsEveryItemWithItsDigit() {
        let help = VoiceMenu.helpLine
        var cursor = help.startIndex
        for item in VoiceMenu.Item.allCases {
            let entry = "\(VoiceMenu.digitWord(item).capitalized), \(VoiceMenu.word(item))."
            guard let range = help.range(of: entry, range: cursor..<help.endIndex) else {
                Issue.record("help line is missing \"\(entry)\": \(help)")
                return
            }
            cursor = range.upperBound
        }
        #expect(help.hasSuffix("Or say stop to end the route."))
        #expect(VoiceMenu.Item.help.confirmationLine == help)
    }

    /// Step 67 (owner: "when it immediately pops up there's a lot of jargon. It should just be
    /// 'OpenCane ready'"): there is no launch menu any more. The only menu the shell ever speaks is
    /// the numbered `helpLine`, and only when the walker asks for it — "help", "menu", "options" or
    /// "seven". It still names every item.
    @Test func theOnlyMenuIsTheOneTheWalkerAsksFor() {
        for ask in ["help", "Help.", "menu", "options", "what can I say", "seven", "7"] {
            #expect(VoiceMenu.match(ask) == .help, "\(ask)")
        }
        #expect(VoiceMenu.Item.help.confirmationLine == VoiceMenu.helpLine)
        for item in VoiceMenu.Item.allCases {
            #expect(VoiceMenu.helpLine.contains(VoiceMenu.word(item)), "\(VoiceMenu.word(item))")
        }
    }

    /// Yes / no / cancel for the emergency prompt; anything else is not a confirmation.
    @Test func yesNoConfirmations() {
        for yes in ["yes", "Yes.", "yeah", "yep", "yes please", "confirm", "yes call"] {
            #expect(VoiceMenu.confirmation(yes) == true, "\(yes)")
        }
        for no in ["no", "No!", "nope", "no cancel", "don't call", "do not call", "cancel call"] {
            #expect(VoiceMenu.confirmation(no) == false, "\(no)")
        }
        #expect(VoiceMenu.confirmation("yes and also route") == nil)
        #expect(VoiceMenu.confirmation("route") == nil)
        #expect(VoiceMenu.confirmation("") == nil)
    }

    /// "stop" is never a menu item, a digit, a confirmation or a verb: it stays the classifier's
    /// exact-phrase rule 1, so auto-listen cannot turn a stray "stop" into anything but Stop route.
    @Test func stopIsNotAMenuWord() {
        #expect(VoiceMenu.match("stop") == nil)
        #expect(VoiceMenu.confirmation("stop") == nil)
        #expect(VoiceMenu.verb("stop") == nil)
        #expect(!VoiceMenu.Item.allCases.contains { VoiceMenu.word($0) == "stop" })
    }

    /// The three verbs outside the menu: next (a waypoint), standard and detailed (cue levels);
    /// whole-utterance like the items. `quiet` is a menu item, not a verb.
    @Test func extraVerbsAreWholeUtteranceToo() {
        #expect(VoiceMenu.verb("next") == .next)
        #expect(VoiceMenu.verb("Next waypoint.") == .next)
        #expect(VoiceMenu.verb("standard") == .standard)
        #expect(VoiceMenu.verb("standard cues") == .standard)
        #expect(VoiceMenu.verb("detailed") == .detailed)
        #expect(VoiceMenu.verb("what is next on the route") == nil)
        #expect(VoiceMenu.verb("quiet") == nil)
    }

    /// Every confirmation line is short, ends in a full stop and reuses the exact cue-level text
    /// the app already speaks (`CueLevel.quiet.spokenLine`), so one utterance has one cached line.
    @Test func confirmationLinesAreShortAndReuseCueText() {
        for item in VoiceMenu.Item.allCases {
            let line = item.confirmationLine
            #expect(line.hasSuffix("."), "\(item.rawValue)")
            #expect(!line.isEmpty, "\(item.rawValue)")
        }
        #expect(VoiceMenu.Item.quiet.confirmationLine == CueLevel.quiet.spokenLine)
        #expect(VoiceMenu.Item.whereAmI.confirmationLine == VoiceMenu.Item.describe.confirmationLine)
        #expect(VoiceMenu.Item.emergency.confirmationLine == EmergencyConfirm.noContactLine)
    }
}
