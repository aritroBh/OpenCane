//
//  EmergencyConfirmTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins EmergencyConfirm.swift — the two-utterance, confirmation-gated emergency call
//  (Step 59). "emergency" prompts; only a "yes" inside 8 s dials; nothing is ever dialled on one
//  word, and nothing is dialled after the window.
//
//  Why these are the tests: this is the one voice command that leaves the app and rings a real
//  person. A false positive is a phone call to the founder's emergency contact from a cane; a
//  false negative is a walker who needed help and got "Nothing to confirm.". So: the window, the
//  restart, the empty-profile case and the number filter are each pinned.
//
//  Source pinned: `ios/Logic/Sources/CaneKitLogic/EmergencyConfirm.swift` (`confirmWindow` 8,
//  `promptLine(name:number:)`, `fixedLines`, `telDigits(_:)`, `Outcome`, `emergency(now:name:number:)`,
//  `confirm(_:now:)`, `expire(now:)`). Callers: `ConversationCoordinator.executeAction`
//  (`.emergency` / `.confirm`), `ProfilePage` (`telDigits` for its Call link),
//  `SpokenPhrases.shellLines` (`fixedLines`).
//

import Testing
@testable import CaneKitLogic

@Suite("Emergency — confirmation gated")
struct EmergencyConfirmTests {

    /// The prompt names the contact and reads the number exactly as the profile stores it.
    @Test func promptLineHasNameAndNumber() {
        let line = EmergencyConfirm.promptLine(name: "Priya", number: "+1 (925) 791-8082")
        #expect(line == "Say yes to call Priya at +1 (925) 791-8082.")
        #expect(EmergencyConfirm.promptLine(name: "", number: "555").hasPrefix("Say yes to call your emergency contact at "))
        #expect(EmergencyConfirm.confirmWindow == 8)
    }

    /// "emergency" then "yes" 7.9 s later dials the filtered number.
    @Test func yesWithinEightSecondsCalls() {
        var e = EmergencyConfirm()
        let first = e.emergency(now: 100, name: "Priya", number: "+1 (925) 791-8082")
        #expect(first == .prompt(EmergencyConfirm.promptLine(name: "Priya", number: "+1 (925) 791-8082")))
        #expect(e.isPending(now: 105))
        let outcome = e.confirm(true, now: 107.9)
        #expect(outcome == .call(tel: "+19257918082"))
        #expect(!e.isPending(now: 108))
    }

    /// "yes" 8.1 s after the prompt is ignored: nothing to confirm, nothing dialled.
    @Test func yesAfterEightSecondsIsIgnored() {
        var e = EmergencyConfirm()
        _ = e.emergency(now: 0, name: "Priya", number: "5551234")
        let late = e.confirm(true, now: 8.1)
        #expect(late == .none)
        #expect(!e.isPending(now: 8.1))
    }

    /// "no" inside the window cancels; a bare "yes" with no prompt pending is `.none`.
    @Test func noCancels() {
        var e = EmergencyConfirm()
        _ = e.emergency(now: 0, name: "Priya", number: "5551234")
        let no = e.confirm(false, now: 2)
        #expect(no == .cancel)
        let yes = e.confirm(true, now: 3)
        #expect(yes == .none)
        var fresh = EmergencyConfirm()
        let bare = fresh.confirm(true, now: 0)
        #expect(bare == .none)
    }

    /// A second "emergency" restarts the window from the second prompt.
    @Test func aSecondEmergencyWordRestartsThePrompt() {
        var e = EmergencyConfirm()
        _ = e.emergency(now: 0, name: "Priya", number: "5551234")
        _ = e.emergency(now: 6, name: "Priya", number: "5551234")
        let outcome = e.confirm(true, now: 13)   // 13 s after the first, 7 s after the second
        #expect(outcome == .call(tel: "5551234"))
    }

    /// No contact on the profile: say so, never prompt, nothing pending.
    @Test func noContactSaysSo() {
        var e = EmergencyConfirm()
        #expect(e.emergency(now: 0, name: "Priya", number: "") == .noContact)
        #expect(e.emergency(now: 0, name: nil, number: nil) == .noContact)
        #expect(e.emergency(now: 0, name: "Priya", number: " - ") == .noContact)
        #expect(!e.isPending(now: 1))
        let yes = e.confirm(true, now: 1)
        #expect(yes == .none)
    }

    /// The tel: filter keeps digits and a leading plus, drops spaces, brackets and dashes — the
    /// same filter ProfilePage used inline before it moved here.
    @Test func digitsForTelKeepPlusAndNumbers() {
        #expect(EmergencyConfirm.telDigits("+1 (925) 791-8082") == "+19257918082")
        #expect(EmergencyConfirm.telDigits("555-0100 ext. 9") == "5550100" + "9")
        #expect(EmergencyConfirm.telDigits("") == "")
        #expect(EmergencyConfirm.telDigits("no number") == "")
    }

    /// The window lapsing with no answer is reported once (the app speaks "Emergency canceled.").
    @Test func expiryIsReportedOnce() {
        var e = EmergencyConfirm()
        _ = e.emergency(now: 0, name: "Priya", number: "5551234")
        var lapsed = e.expire(now: 7.9)
        #expect(lapsed == false)
        lapsed = e.expire(now: 8.0)
        #expect(lapsed == true)
        lapsed = e.expire(now: 9.0)
        #expect(lapsed == false)
    }

    /// The fixed lines are the four the shell can speak besides the prompt; each ends in a full stop.
    @Test func fixedLinesAreTheFourSpokenOnes() {
        #expect(EmergencyConfirm.fixedLines.count == 4)
        #expect(EmergencyConfirm.fixedLines.contains(EmergencyConfirm.canceledLine))
        #expect(EmergencyConfirm.fixedLines.contains(EmergencyConfirm.callingLine))
        #expect(EmergencyConfirm.fixedLines.contains(EmergencyConfirm.noContactLine))
        #expect(EmergencyConfirm.fixedLines.contains(EmergencyConfirm.nothingPendingLine))
        #expect(EmergencyConfirm.fixedLines.allSatisfy { $0.hasSuffix(".") })
    }
}
