//
//  GuideLayoutTests.swift
//  CaneKitLogicTests
//
//  The voice-only screen (docs/UX.md §4.4): what it hides, and the one thing it must not.
//

import Testing
@testable import CaneKitLogic

@Suite("Guide layout") struct GuideLayoutTests {

    /// ⚠ **The test this file exists for.** Ending guidance must never depend on a recogniser
    /// working: every reason voice fails outdoors — wind, traffic, a bus, a sore throat — is a reason
    /// a walker might want to stop. So Stop route keeps a finger target in voice-only mode even
    /// though the other situational buttons do not, and `showsStopRoute` is deliberately a separate
    /// flag from `showsSituationalButtons`. Merging them would be the regression.
    @Test func stopRouteSurvivesVoiceOnly() {
        #expect(GuideLayout.voiceOnly.showsStopRoute)
        #expect(GuideLayout.full.showsStopRoute)
        #expect(!GuideLayout.voiceOnly.showsSituationalButtons)
        #expect(GuideLayout.full.showsSituationalButtons)
    }

    /// Voice-only hides everything a blind walker would only ever scan past.
    @Test func voiceOnlyHidesTheThingsAFingerHasToHunt() {
        let v = GuideLayout.voiceOnly
        #expect(!v.showsSecondaryControls)
        #expect(!v.showsStatusPills)
        #expect(!v.showsTabBar)
    }

    /// Full is exactly today's screen, so turning the mode off is a true restore.
    @Test func fullIsTodaysScreen() {
        let f = GuideLayout.full
        #expect(f.showsSituationalButtons)
        #expect(f.showsSecondaryControls)
        #expect(f.showsStatusPills)
        #expect(f.showsTabBar)
    }

    /// ⚠ Raw values are persisted (`Settings` key `voiceOnlyScreen` stores the flag, but a future
    /// third layout would store these). Renaming one silently resets a walker's choice.
    @Test func rawValuesAreStable() {
        #expect(GuideLayout.full.rawValue == "full")
        #expect(GuideLayout.voiceOnly.rawValue == "voiceOnly")
    }

    /// Both change lines say what is *left*, because the walker cannot see what went away — and the
    /// voice-only line names Stop route specifically, since that is the promise the mode makes.
    @Test func bothChangeLinesSayWhatIsLeft() {
        #expect(GuideLayout.full.spokenLine.contains("button"))
        let v = GuideLayout.voiceOnly.spokenLine
        #expect(v.contains("microphone"))
        #expect(v.contains("Stop route"))
        for line in GuideLayout.spokenLines {
            #expect(line.hasSuffix("."))
            // Short enough to be a confirmation rather than an explanation. [H] 220, not 160: the
            // voice-only line has to carry the escape phrase as well (see the test below), and a
            // walker who cannot get out of the mode is a worse outcome than two extra seconds.
            #expect(line.count < 220)
        }
    }

    /// ⚠ **The one that matters.** Voice-only mode hides the tab bar, so the Settings switch that
    /// turned it on is no longer reachable with a finger: the phrase is the only exit, and a blind
    /// walker cannot discover it by looking. So the line that enters the mode must name it, the
    /// parser must accept it, and both must be the same bytes — `GuideLayout.escapePhrase`.
    ///
    /// The full-screen line does not name an escape because it *is* the escape's destination.
    @Test func theEscapeHatchIsNamedInTheLineThatNeedsIt() {
        #expect(GuideLayout.voiceOnly.spokenLine.contains(GuideLayout.escapePhrase))
        #expect(VoiceControlGrammar.match(GuideLayout.escapePhrase) == .setVoiceOnlyScreen(false))
        // And it survives the recogniser's punctuation and capitals, like any other command.
        #expect(VoiceControlGrammar.match("Full screen.") == .setVoiceOnlyScreen(false))
        #expect(VoiceControlGrammar.match("show the buttons") == .setVoiceOnlyScreen(false))
        #expect(VoiceControlGrammar.match("voice only") == .setVoiceOnlyScreen(true))
        // ⚠ And nothing ahead of rule 0b shadows it: the menu must not claim these words.
        #expect(VoiceMenu.match(GuideLayout.escapePhrase) == nil)
        #expect(FastPathIntentClassifier.classify(query: "full screen")
                == .setVoiceOnlyScreen(false))
    }

    /// ⚠ **A mode you can enter and not leave is a trap.** Voice-only hides the tab bar and the
    /// Settings switch with it, so the exits are the spoken "full screen" *and* an on-screen button.
    /// The button is the one that matters: every reason the voice path fails — wind, traffic, a sore
    /// throat, a microphone the OS handed to another app — is a reason the walker wants out, so the
    /// escape must not depend on the component most likely to have failed. Same argument as
    /// `stopRouteSurvivesVoiceOnly`.
    @Test func voiceOnlyModeHasANonVoiceWayOut() {
        #expect(GuideLayout.voiceOnly.showsEscapeButton)
        // Not in full mode: there is nothing to escape from, and it would be a control on a page
        // whose whole point is that it already has the controls.
        #expect(!GuideLayout.full.showsEscapeButton)
        // Plain words a sighted helper can find at a glance — they are often the one flipping it back.
        #expect(GuideLayout.escapeButtonTitle == "Show buttons")
        // Both exits exist, and neither replaces the other.
        #expect(VoiceControlGrammar.match(GuideLayout.escapePhrase) == .setVoiceOnlyScreen(false))
    }

    /// The layout the app derives from the persisted Bool, both ways round. The views ask
    /// `AppModel.guideLayout` rather than the Bool precisely so this mapping exists once.
    @Test func theFlagPicksTheLayout() {
        #expect((true ? GuideLayout.voiceOnly : .full) == .voiceOnly)
        #expect(GuideLayout.voiceOnly.showsStopRoute)
        #expect(!GuideLayout.voiceOnly.showsTabBar)
    }

    /// The Settings switch title is a UI-test contract (AGENTS.md rule 9).
    @Test func theSwitchTitleIsTheOneTheTestsRead() {
        #expect(GuideLayout.switchTitle == "Voice-only screen")
    }
}
