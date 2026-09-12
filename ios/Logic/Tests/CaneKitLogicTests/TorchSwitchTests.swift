//
//  TorchSwitchTests.swift
//  CaneKitLogicTests
//
//  Tests for the flashlight switch state machine. The break these catch was measured on the phone
//  (trip log canekit-2026-09-12T20-57-17Z, t = 106–120 s): every press logged `torch on, active:
//  false` and then, on the NEXT press, `on, active: true` — the app read `isTorchActive` in the
//  same instant it set the torch, before iOS updated it, so the switch snapped back, said the
//  flashlight had failed, and the walker had to press twice for every change.
//

import CaneKitLogic
import Testing

@Suite("Torch switch")
struct TorchSwitchTests {

    @Test("a request shows on the switch at once, before the device reports")
    func requestIsShownOptimistically() {
        var torch = TorchSwitch()
        torch.request(true, now: 100)

        #expect(torch.displayed == true)
        #expect(torch.isSettling)
    }

    @Test("a stale report read in the same instant as the request does not snap the switch back")
    func staleReportDoesNotSnapBack() {
        var torch = TorchSwitch()
        torch.request(true, now: 100)
        let outcome = torch.report(active: false, now: 100)

        #expect(outcome == .none)
        #expect(torch.displayed == true)
        #expect(torch.isSettling)
    }

    @Test("the device reporting the requested state confirms it once")
    func matchingReportConfirms() {
        var torch = TorchSwitch()
        torch.request(true, now: 100)
        _ = torch.report(active: false, now: 100)
        let first = torch.report(active: true, now: 100.3)
        let again = torch.report(active: true, now: 100.4)

        #expect(first == .confirmed(on: true))
        #expect(again == .none)
        #expect(torch.displayed == true)
        // The window stays open to its deadline (see `inFlightReportsInsideTheWindowAreSilent`);
        // the deadline then has nothing new to say.
        #expect(torch.isSettling)
        #expect(torch.tick(active: true, now: .infinity) == .none)
        #expect(!torch.isSettling)
    }

    @Test("no matching report by the settle deadline fails and shows what the device did")
    func deadlineFailsWithTheMeasuredState() {
        var torch = TorchSwitch()
        torch.request(true, now: 100)
        let early = torch.tick(active: false, now: 100 + TorchSwitch.Configuration().settleSeconds - 0.01)
        let late = torch.tick(active: false, now: 100 + TorchSwitch.Configuration().settleSeconds)

        #expect(early == .none)
        #expect(late == .failed(requested: true))
        #expect(torch.displayed == false)
        #expect(!torch.isSettling)
    }

    @Test("a deadline reached with the device already in the requested state confirms instead")
    func deadlineWithMatchingStateConfirms() {
        var torch = TorchSwitch()
        torch.request(false, now: 10)
        #expect(torch.tick(active: false, now: 20) == .confirmed(on: false))
    }

    @Test("a newer request supersedes a pending one; the old request's report is ignored")
    func newerRequestSupersedes() {
        var torch = TorchSwitch()
        torch.request(true, now: 100)
        torch.request(false, now: 100.2)
        // The first request's torch coming on arrives late: not what is pending now.
        let late = torch.report(active: true, now: 100.3)
        let settled = torch.report(active: false, now: 100.5)

        #expect(late == .none)
        #expect(torch.displayed == false)
        #expect(settled == .confirmed(on: false))
    }

    @Test("with nothing pending, a change the walker did not ask for is reported (thermal cut-out)")
    func externalChangeIsReported() {
        var torch = TorchSwitch()
        torch.request(true, now: 0)
        _ = torch.report(active: true, now: 0.2)
        #expect(torch.tick(active: true, now: .infinity) == .none)   // window closes, already confirmed
        let cut = torch.report(active: false, now: 300)
        let repeated = torch.report(active: false, now: 301)

        #expect(cut == .changedByDevice(on: false))
        #expect(repeated == .none)
        #expect(torch.displayed == false)
    }

    /// ⚠ Found by the Step 34 review (agents, Muse and Antigravity independently): torch confirmed
    /// ON, the walker taps OFF then ON within ~300 ms. The first version confirmed from a stale
    /// same-instant read and then announced the OFF request's own late KVO as "The flashlight
    /// turned off." / "turned on." — a switch that flickers and a phone that says it acted alone.
    /// Every report inside the latest request's window is the walker's own requests landing.
    @Test("a quick reversal speaks one confirmation and never a device change")
    func quickReversalSpeaksOnce() {
        var torch = TorchSwitch()
        torch.request(true, now: 0)
        _ = torch.report(active: true, now: 0.2)
        _ = torch.tick(active: true, now: .infinity)

        torch.request(false, now: 100)
        torch.request(true, now: 100.1)
        var spoken: [TorchSwitch.Outcome] = []
        for active in [true, false, true] {             // stale, OFF landing, ON landing
            let o = torch.report(active: active, now: 100.3)
            if o != .none { spoken.append(o) }
            #expect(torch.displayed == true)            // the switch never flickers
        }
        let end = torch.tick(active: true, now: .infinity)
        if end != .none { spoken.append(end) }

        #expect(spoken == [.confirmed(on: true)])
    }

    @Test("reports inside the window that do not match are recorded silently")
    func inFlightReportsInsideTheWindowAreSilent() {
        var torch = TorchSwitch()
        torch.request(true, now: 0)
        #expect(torch.report(active: false, now: 0.1) == .none)
        #expect(torch.report(active: false, now: 0.2) == .none)
        #expect(torch.displayed == true)
        #expect(torch.isSettling)
    }

    @Test("confirmed, then off again before the deadline: the deadline says the device turned it off")
    func confirmedThenLostInsideTheWindow() {
        var torch = TorchSwitch()
        torch.request(true, now: 0)
        #expect(torch.report(active: true, now: 0.2) == .confirmed(on: true))
        #expect(torch.report(active: false, now: 1.0) == .none)      // thermal cut-out, still in window
        #expect(torch.tick(active: false, now: .infinity) == .changedByDevice(on: false))
        #expect(torch.displayed == false)
    }

    /// ⚠ Found by the Step 34 review: the deadline task slept on `ContinuousClock` (runs during
    /// system sleep) and compared against `systemUptime` (stops), so a window could never close.
    /// The task *is* the deadline; it ticks with `now: .infinity`, which must always resolve.
    @Test("a tick at infinity always closes the window")
    func infiniteTickAlwaysResolves() {
        var torch = TorchSwitch()
        torch.request(true, now: 1_000_000)
        #expect(torch.tick(active: false, now: .infinity) == .failed(requested: true))
        #expect(!torch.isSettling)
    }

    @Test("ticks with nothing pending are silent")
    func idleTickIsSilent() {
        var torch = TorchSwitch()
        #expect(torch.tick(active: false, now: 5) == .none)
        #expect(torch.displayed == false)
    }

    @Test("the settle window is a generous two seconds and clamps nonsense")
    func settleWindowDefaultAndClamp() {
        #expect(TorchSwitch.Configuration().settleSeconds == 2.0)
        #expect(TorchSwitch.Configuration(settleSeconds: -1).settleSeconds == 0)
        #expect(TorchSwitch.Configuration(settleSeconds: .nan).settleSeconds == 2.0)
    }

    @Test("each outcome has one fixed spoken line, and a stale report speaks nothing")
    func spokenLines() {
        #expect(TorchSwitch.Outcome.confirmed(on: true).spokenLine == "Flashlight on.")
        #expect(TorchSwitch.Outcome.confirmed(on: false).spokenLine == "Flashlight off.")
        #expect(TorchSwitch.Outcome.failed(requested: true).spokenLine == "The flashlight did not switch on.")
        #expect(TorchSwitch.Outcome.failed(requested: false).spokenLine == "The flashlight did not switch off.")
        #expect(TorchSwitch.Outcome.changedByDevice(on: false).spokenLine == "The flashlight turned off.")
        #expect(TorchSwitch.Outcome.changedByDevice(on: true).spokenLine == "The flashlight turned on.")
        #expect(TorchSwitch.Outcome.none.spokenLine == nil)
    }

    /// `AppModel.commonLines` prefetches `TorchSwitch.allSpokenLines`, so no flashlight line ever
    /// waits on a voice fetch (a cache miss holds the queue and ducks the beacon for up to 2.5 s —
    /// Antigravity, Step 34 review). This pins the list to the outcomes, byte for byte.
    @Test("allSpokenLines is exactly the set of outcome lines")
    func allSpokenLinesMatchOutcomes() {
        let outcomes: [TorchSwitch.Outcome] = [.confirmed(on: true), .confirmed(on: false),
                                               .failed(requested: true), .failed(requested: false),
                                               .changedByDevice(on: true), .changedByDevice(on: false)]
        #expect(Set(TorchSwitch.allSpokenLines) == Set(outcomes.compactMap(\.spokenLine)))
        #expect(TorchSwitch.allSpokenLines.count == 6)
    }

    @Test("unexpected outcomes wait longer in the queue than a confirmation")
    func queueLifetimes() {
        #expect(TorchSwitch.Outcome.confirmed(on: true).queueSeconds == 4)
        #expect(TorchSwitch.Outcome.failed(requested: true).queueSeconds == 12)
        #expect(TorchSwitch.Outcome.changedByDevice(on: false).queueSeconds == 12)
    }
}
