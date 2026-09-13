//
//  GuideLayout.swift
//  CaneKitLogic
//
//  Which controls the screen shows: today's full layout, or the voice-only screen (docs/UX.md §4.4).
//
//  Why this is a pure type and not a handful of `if` statements in the views: "is this control
//  visible" is a rule, it has a safety exception in it, and a rule this app relies on has to be
//  testable without a simulator. The views ask; they do not decide.
//
//  Why voice-only mode exists at all: the honest end state of docs/UX.md is a screen with nothing on
//  it to find. Eleven controls on the Guide page are eleven things a blind walker must scan past to
//  reach the microphone, and the tab bar is a purely visual metaphor — a blind walker does not
//  "switch to the Sense tab", they ask a question. So the mode strips the page to the microphone,
//  the instruction (which a sighted spotter reads over the walker's shoulder during the demo) and
//  the last answer.
//
//  Key invariants:
//    · **Two things survive voice-only, and both are safety, not compromise:** `showsStopRoute` and
//      `showsEscapeButton`. Ending guidance and leaving the mode must never depend on a recogniser
//      working, because every reason voice fails (wind, traffic, a sore throat, a microphone the OS
//      handed to another app) is a reason the walker wants out. See each one's ⚠.
//    · **Stop route survives voice-only.** ⚠ This is the one deliberate exception to "nothing else
//      on the screen", and it is a safety decision, not a compromise: ending guidance must never
//      depend on a recogniser working. Wind, traffic, a bus, a sore throat — every reason voice
//      fails is a reason a walker might want to stop. `showsStopRoute` is therefore true in both
//      modes, and `showsSituationalButtons` is not. Pinned by `stopRouteSurvivesVoiceOnly`.
//      Do not "simplify" these two into one flag.
//    · **The instruction and the answer always show.** They are text, not targets; they cost the
//      walker nothing to scan past and they are how a sighted helper follows along. A voice-only
//      screen that showed nothing would make the demo unwatchable and debugging blind.
//    · **Ships off** (`AGENTS.md` → "Safety beats features", docs/UX.md rule 9). Not because it is
//      wrong, but because "the walker can no longer reach Recenter with a finger" is exactly the
//      kind of claim that needs a walk on the mounted cane before it is a default. The owner flips
//      it; do not flip it in code.
//    · Pure and nonisolated. No clock, no I/O, no state.
//
//  Owner / callers: `AppModel.guideLayout` (from `Settings.bool("voiceOnlyScreen")`, default false);
//  read by `GuideCard`, `ContentView`'s tab bar and `SettingsPage`'s Voice card.
//  Tests: `GuideLayoutTests.swift`.
//

import Foundation

/// How much of the screen the app draws.
public enum GuideLayout: String, CaseIterable, Sendable, Equatable {

    /// Today's screen: four tabs, every card, every button. The default.
    case full

    /// The microphone, the instruction, the last answer, and — while a route guides — Stop route.
    case voiceOnly

    /// The two or three buttons under the microphone (Where am I / Start route, or Repeat / Next).
    /// ⚠ Stop route is NOT one of these: see `showsStopRoute`.
    public var showsSituationalButtons: Bool { self == .full }

    /// Stop route, while a route guides. **True in both modes** — see the file's first ⚠.
    public var showsStopRoute: Bool { true }

    /// Everything below the fold: Recenter, Simulate walk, Navigate to CIF from here, the
    /// destination field, the beacon and head pills, the arrival Repeat.
    public var showsSecondaryControls: Bool { self == .full }

    /// The GPS / GPS-weak / Dark pills. Spotter information; a walker is told each of these by voice.
    public var showsStatusPills: Bool { self == .full }

    /// The four-tab bar. A blind walker does not switch tabs; they ask a question.
    public var showsTabBar: Bool { self == .full }

    /// "Show buttons" — the way out of voice-only mode **that does not go through the recogniser**.
    /// Drawn last on the page, so it costs nothing on the way to the microphone, and only in
    /// voice-only mode (in full mode there is nothing to escape from).
    ///
    /// ⚠ This is the same argument as `showsStopRoute`, and it is not optional. Voice-only hides the
    /// tab bar and the Settings switch with it, so without this the only exit is the phrase "full
    /// screen" — which means the mode can be entered and not left in exactly the conditions that
    /// made the walker want out: wind, traffic, a failing microphone, a sore throat, a recogniser
    /// that has stopped returning transcripts. A mode whose only escape depends on the component
    /// most likely to have failed is a trap. The spoken phrase stays as the *fast* way out; this is
    /// the one that always works. Pinned by `voiceOnlyModeHasANonVoiceWayOut`.
    public var showsEscapeButton: Bool { self == .voiceOnly }

    /// That button's title. ⚠ UI-test contract (AGENTS.md rule 9) and it must stay plain words a
    /// sighted helper can find at a glance — the helper is often the one flipping the mode back.
    public static let escapeButtonTitle = "Show buttons"

    /// The Settings switch's visible title. ⚠ UI-test contract (AGENTS.md rule 9):
    /// `testVoiceOnlyScreenSwitchExists` reads this string.
    public static let switchTitle = "Voice-only screen"

    /// Spoken once when the walker turns the mode on or off, so the change is never silent
    /// (docs/UX.md rule 2). Names what is left, because the walker cannot see what went away.
    ///
    /// ⚠ The voice-only line **must name the way out**. Voice-only hides the tab bar, so the Settings
    /// switch that turned it on is no longer reachable with a finger and the only exit is the phrase
    /// "full screen". A mode that can be entered and not left is a trap, and a blind walker cannot
    /// discover the exit by looking for it. Pinned by `bothChangeLinesSayWhatIsLeft` and
    /// `theEscapeHatchIsNamedInTheLineThatNeedsIt`.
    public var spokenLine: String {
        switch self {
        case .full:
            return "Full screen. Every button is back."
        case .voiceOnly:
            return "Voice-only screen. The microphone fills the page, and Stop route stays while a "
                + "route is guiding. Say full screen to bring the buttons back."
        }
    }

    /// Both change lines, for the natural-voice prefetch (`SpokenPhrases.shellLines`).
    public static let spokenLines: [String] = GuideLayout.allCases.map(\.spokenLine)

    /// The phrase the voice-only line promises. ⚠ Bytes shared with `VoiceControlGrammar`'s alias
    /// table so the promise and the parser cannot disagree (`theEscapeHatchIsNamedInTheLineThatNeedsIt`).
    public static let escapePhrase = "full screen"
}
