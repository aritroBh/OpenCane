//
//  LowLightTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins LowLight.swift — when the app decides it is dark, when it decides it is light
//  again, and what it does about it (Step 49).
//
//  Why these are the tests: a blind walker cannot tell that it is dark, and every camera-based
//  feature (ARKit visual tracking, sign reading, scene words, "Where am I", the hazard watch)
//  degrades silently in the dark while LiDAR, the gyro gate, GPS, the compass and haptics keep
//  working. The failure modes to pin are therefore: flipping on a passing shadow or a headlight
//  (`flickerDoesNotToggle`), claiming a light level before ARKit has given one
//  (`unknownUntilFirstEstimate`), lighting a torch in a pocket with no route running
//  (`adviceTurnsTorchOnOnlyOnARoute`), and nagging every frame (`adviceSpeaksOncePerEpisode`).
//  The numbers (40 lux, 120 lux, 3 s, 5 s, 0.3 s EMA) are research hypotheses [H] until a dark-room
//  walk measures them; `defaultsAreTheDesign` pins them so a change is a decision, not drift.
//
//  Source pinned: `ios/Logic/Sources/CaneKitLogic/LowLight.swift` (`LowLightPolicy`,
//  `LowLightPolicy.Configuration` / `State` / `Step`, `LowLightAdvice`). Callers:
//  `AppModel.handle(_:)` steps the policy with `LaneReport.ambientLux`; `AppModel.lowLightChanged`
//  applies the advice (torch through `setTorch`, the spoken line at `.nav`).
//

import Testing
@testable import CaneKitLogic

/// The low-light policy driven with explicit ARKit-clock times, exactly as `AppModel.handle`
/// drives it: one `update` per published `LaneReport` (30 Hz here).
@Suite("Low light")
struct LowLightTests {

    /// Feed `lux` at 30 Hz from `from` until `until` (exclusive) and return the last step.
    @discardableResult
    private func feed(_ policy: inout LowLightPolicy, lux: Float, from: Double, until: Double) -> LowLightPolicy.Step {
        var t = from
        var last = policy.update(lux: lux, now: t)
        while t + 1.0 / 30 < until {
            t += 1.0 / 30
            last = policy.update(lux: lux, now: t)
        }
        return last
    }

    @Test("dark needs the smoothed lux under 40 for 3 s, not one dark frame")
    func darkNeedsThreeSecondsUnderForty() {
        var p = LowLightPolicy()
        feed(&p, lux: 600, from: 0, until: 2)            // a lit room first
        #expect(p.state == .lit)
        feed(&p, lux: 10, from: 2, until: 2 + 2.9)       // 2.9 s of dark: still lit
        #expect(p.state == .lit)
        // The 0.3 s EMA needs ~0.9 s to fall from 600 to under 40; the dwell starts only then, so
        // the flip lands a little after 3 s of dark frames — and well under 4.5 s.
        let step = feed(&p, lux: 10, from: 2 + 2.9, until: 2 + 4.5)
        #expect(p.state == .dark)
        #expect(step.state == .dark)
    }

    @Test("dark → lit needs the smoothed lux over 120 for 5 s")
    func litNeedsFiveSecondsOverOneTwenty() {
        var p = LowLightPolicy()
        feed(&p, lux: 5, from: 0, until: 4)              // from unknown: 3 s under 40 → dark
        #expect(p.state == .dark)
        feed(&p, lux: 80, from: 4, until: 14)            // 80 lux is over 40 but not over 120: stays dark
        #expect(p.state == .dark)
        feed(&p, lux: 600, from: 14, until: 14 + 4.9)    // 4.9 s over 120: still dark
        #expect(p.state == .dark)
        feed(&p, lux: 600, from: 14 + 4.9, until: 14 + 6.0)
        #expect(p.state == .lit)
    }

    @Test("a headlight in the dark or a shadow in the light does not toggle the state")
    func flickerDoesNotToggle() {
        // Dark, then a 1 s car headlight at 2000 lux: over 120 briefly, never for 5 s.
        var dark = LowLightPolicy()
        feed(&dark, lux: 5, from: 0, until: 4)
        #expect(dark.state == .dark)
        var edges = 0
        var t = 4.0
        while t < 5.0 { if dark.update(lux: 2000, now: t).didExitDark { edges += 1 }; t += 1.0 / 30 }
        while t < 9.0 { if dark.update(lux: 5, now: t).didExitDark { edges += 1 }; t += 1.0 / 30 }
        #expect(dark.state == .dark)
        #expect(edges == 0)

        // Lit, then a 1 s shadow at 5 lux: the EMA dips under 40 for the last ~0.1 s of it, the
        // 3 s dwell never completes, and the light coming back resets it.
        var lit = LowLightPolicy()
        feed(&lit, lux: 600, from: 0, until: 2)
        var entered = 0
        t = 2.0
        while t < 3.0 { if lit.update(lux: 5, now: t).didEnterDark { entered += 1 }; t += 1.0 / 30 }
        while t < 6.0 { if lit.update(lux: 600, now: t).didEnterDark { entered += 1 }; t += 1.0 / 30 }
        #expect(lit.state == .lit)
        #expect(entered == 0)
    }

    @Test("unknown until ARKit gives a first estimate; nil estimates never change anything")
    func unknownUntilFirstEstimate() {
        var p = LowLightPolicy()
        #expect(p.state == .unknown)
        #expect(p.smoothedLux == nil)
        let none = p.update(lux: nil, now: 0)
        #expect(none.state == .unknown)
        #expect(!none.didEnterDark && !none.didExitDark)
        // The first real estimate resolves at once when it is not dark …
        let first = p.update(lux: 500, now: 0.1)
        #expect(first.state == .lit)
        #expect(!first.didEnterDark && !first.didExitDark)
        #expect(p.smoothedLux == 500)
        // … while a dark first estimate waits the full 3 s dwell, so one odd first frame cannot
        // light the torch.
        var q = LowLightPolicy()
        _ = q.update(lux: 3, now: 0)
        #expect(q.state == .unknown)
        feed(&q, lux: 3, from: 1.0 / 30, until: 3.2)
        #expect(q.state == .dark)
        // A nil estimate mid-stream keeps the last state and reports no edge.
        let hold = q.update(lux: nil, now: 3.3)
        #expect(hold.state == .dark && !hold.didEnterDark)
    }

    @Test("the torch is lit only on a route, only when available, only if the setting is on")
    func adviceTurnsTorchOnOnlyOnARoute() {
        // Dark, on a route, torch available and off, setting on → light it and say so.
        let onRoute = LowLightAdvice.decide(state: .dark, entered: true, torchOn: false,
                                            torchAvailable: true, navigating: true, autoTorch: true)
        #expect(onRoute.turnTorchOn)
        #expect(onRoute.spokenLine == LowLightAdvice.darkLineWithTorch)
        #expect(onRoute.visionCaveat == false)     // the torch is going on: the cameras get light
        // No route: a flashlight in a pocket is a burn risk and a dead battery.
        let idle = LowLightAdvice.decide(state: .dark, entered: true, torchOn: false,
                                         torchAvailable: true, navigating: false, autoTorch: true)
        #expect(!idle.turnTorchOn)
        #expect(idle.spokenLine == LowLightAdvice.darkLine)
        #expect(idle.visionCaveat)
        // Setting off, or no torch on this phone: never.
        #expect(!LowLightAdvice.decide(state: .dark, entered: true, torchOn: false,
                                       torchAvailable: true, navigating: true, autoTorch: false).turnTorchOn)
        #expect(!LowLightAdvice.decide(state: .dark, entered: true, torchOn: false,
                                       torchAvailable: false, navigating: true, autoTorch: true).turnTorchOn)
        // The walker already lit it: nothing to do, and the line does not claim the app did.
        let theirs = LowLightAdvice.decide(state: .dark, entered: true, torchOn: true,
                                           torchAvailable: true, navigating: true, autoTorch: true)
        #expect(!theirs.turnTorchOn)
        #expect(theirs.spokenLine == LowLightAdvice.darkLine)
        #expect(!theirs.visionCaveat)
        // Lit: nothing at all.
        let lit = LowLightAdvice.decide(state: .lit, entered: false, torchOn: false,
                                        torchAvailable: true, navigating: true, autoTorch: true)
        #expect(!lit.turnTorchOn && lit.spokenLine == nil && !lit.visionCaveat)
    }

    @Test("the low-light line is spoken once per darkness episode, on the edge only")
    func adviceSpeaksOncePerEpisode() {
        var p = LowLightPolicy()
        var lines: [String] = []
        var t = 0.0
        while t < 20 {
            let step = p.update(lux: 5, now: t)
            let advice = LowLightAdvice.decide(state: step.state, entered: step.didEnterDark,
                                               torchOn: false, torchAvailable: true,
                                               navigating: false, autoTorch: true)
            if let line = advice.spokenLine { lines.append(line) }
            t += 1.0 / 30
        }
        #expect(lines == [LowLightAdvice.darkLine])
        // Light for long enough to exit, then dark again: a second episode, a second line.
        feed(&p, lux: 800, from: 20, until: 27)
        #expect(p.state == .lit)
        t = 27
        while t < 32 {
            let step = p.update(lux: 5, now: t)
            if let line = LowLightAdvice.decide(state: step.state, entered: step.didEnterDark,
                                                torchOn: false, torchAvailable: true,
                                                navigating: false, autoTorch: true).spokenLine {
                lines.append(line)
            }
            t += 1.0 / 30
        }
        #expect(lines.count == 2)
        // Both spellings are exactly the prefetched strings.
        #expect(LowLightAdvice.darkLine == "Low light. Obstacle detection still works.")
        #expect(LowLightAdvice.darkLineWithTorch == "Low light. Obstacle detection still works. Flashlight on.")
        #expect(LowLightAdvice.allSpokenLines == [LowLightAdvice.darkLine, LowLightAdvice.darkLineWithTorch])
    }

    @Test("the defaults are the design: 40 lux / 3 s in, 120 lux / 5 s out, 0.3 s EMA")
    func defaultsAreTheDesign() {
        let c = LowLightPolicy.Configuration()
        #expect(c.darkLux == 40)
        #expect(c.litLux == 120)
        #expect(c.enterSeconds == 3)
        #expect(c.exitSeconds == 5)
        #expect(c.smoothingSeconds == 0.3)
        #expect(c.minTorchOnSeconds == 60)
        #expect(c.torchBackoffSeconds == 60)
        // Hysteresis is real: the exit threshold sits above the entry threshold.
        #expect(c.litLux > c.darkLux)
        // Bad numbers are repaired rather than trusted.
        let bad = LowLightPolicy.Configuration(darkLux: -5, litLux: -1, enterSeconds: -1,
                                               exitSeconds: .nan, smoothingSeconds: 0,
                                               minTorchOnSeconds: -1, torchBackoffSeconds: .infinity)
        #expect(bad.darkLux == 0 && bad.litLux > bad.darkLux)
        #expect(bad.enterSeconds == 0 && bad.exitSeconds == 5 && bad.smoothingSeconds > 0)
        #expect(bad.minTorchOnSeconds == 0 && bad.torchBackoffSeconds == 60)
        #expect(c.litWithTorchLux == 400)
        #expect(c.litWithTorchLux > c.litLux)
        #expect(c.probeIntervalSeconds == 60 && c.probeSeconds == 1.0)
    }

    @Test("an app-lit torch: even real light (800 lux) does not end the episode inside the 60 s minimum on-time")
    func appTorchStaysOnAMinute() {
        var p = LowLightPolicy()
        feed(&p, lux: 5, from: 0, until: 4)
        #expect(p.state == .dark)
        // The app lights the torch at t = 4 and the walker steps into a lit lobby (800 lux — above
        // `litWithTorchLux`, so it is not the torch's own glow); the minimum on-time still holds.
        var t = 4.0
        var exits = 0
        while t < 4 + 59 {
            if p.update(lux: 800, now: t, torchByApp: true).didExitDark { exits += 1 }
            t += 1.0 / 30
        }
        #expect(p.state == .dark)
        #expect(exits == 0)
        // Past the minimum on-time, with the reading still over 400 for the 5 s dwell, it exits.
        while t < 4 + 61.5 {
            if p.update(lux: 800, now: t, torchByApp: true).didExitDark { exits += 1 }
            t += 1.0 / 30
        }
        #expect(p.state == .lit)
        #expect(exits == 1)
        // A torch the WALKER lit (torchByApp false) holds nothing: 5 s over 120 is enough.
        var q = LowLightPolicy()
        feed(&q, lux: 5, from: 0, until: 4)
        feed(&q, lux: 300, from: 4, until: 10)
        #expect(q.state == .lit)
    }

    @Test("an app-lit torch's own glow (250 lux) never ends the episode; real light (800 lux) does after the minimum on-time")
    func appLitTorchGlowDoesNotEndTheEpisode() {
        var p = LowLightPolicy()
        var t: Double = 0
        // Into the dark, then the app lights the torch and the scene reads 250 lux for two minutes.
        while t < 4 { _ = p.update(lux: 10, now: t); t += 1.0 / 30 }
        #expect(p.state == .dark)
        while t < 124 { _ = p.update(lux: 250, now: t, torchByApp: true); t += 1.0 / 30 }
        #expect(p.state == .dark)                                  // 250 < 400: the torch's glow
        // A lit building: 800 lux for the exit dwell ends it.
        var exited = false
        while t < 131 { if p.update(lux: 800, now: t, torchByApp: true).didExitDark { exited = true }; t += 1.0 / 30 }
        #expect(exited && p.state == .lit)
    }

    @Test("dead zone: a probe is due after the minimum on-time; it ends the episode only on real light")
    func deadZoneProbeEndsEpisodeOnlyOnRealLight() {
        var p = LowLightPolicy()
        var t: Double = 0
        while t < 4 { _ = p.update(lux: 10, now: t); t += 1.0 / 30 }
        #expect(p.state == .dark)
        // Torch on, the room reads 250 lux (dead zone). No probe inside the minimum on-time.
        while t < 30 { _ = p.update(lux: 250, now: t, torchByApp: true); t += 1.0 / 30 }
        #expect(!p.probeDue(now: t))
        while t < 66 { _ = p.update(lux: 250, now: t, torchByApp: true); t += 1.0 / 30 }
        #expect(p.probeDue(now: t))
        // Probe 1: torch off, the room is really dark (15 lux) → not lit, the episode continues.
        p.beginProbe(now: t)
        while t < 67.2 { _ = p.update(lux: 15, now: t, torchByApp: false); t += 1.0 / 30 }
        #expect(p.endProbe(now: t) == false && p.state == .dark)
        #expect(!p.probeDue(now: t))                                // not again for 60 s
        while t < 130 { _ = p.update(lux: 250, now: t, torchByApp: true); t += 1.0 / 30 }
        #expect(p.probeDue(now: t))
        // Probe 2: torch off, the room reads 200 lux on its own → lit, the episode ends.
        p.beginProbe(now: t)
        while t < 131.2 { _ = p.update(lux: 200, now: t, torchByApp: false); t += 1.0 / 30 }
        #expect(p.endProbe(now: t) == true && p.state == .lit)
    }

    @Test("a device cut-out backs the auto-torch off for 60 s; the state stays dark")
    func thermalCutOutBacksOffAMinute() {
        var p = LowLightPolicy()
        feed(&p, lux: 5, from: 0, until: 4)
        #expect(p.canAutoLight(now: 4, batteryPct: 80))
        p.torchCutByDevice(now: 4)
        #expect(p.state == .dark)
        #expect(!p.canAutoLight(now: 4, batteryPct: 80))
        #expect(!p.canAutoLight(now: 63.9, batteryPct: 80))
        #expect(p.canAutoLight(now: 64, batteryPct: 80))
        // The advice follows the answer: backed off → no torch, the plain line.
        let backedOff = LowLightAdvice.decide(state: .dark, entered: true, torchOn: false,
                                              torchAvailable: true, navigating: true, autoTorch: true,
                                              autoTorchAllowed: false)
        #expect(!backedOff.turnTorchOn)
        #expect(backedOff.spokenLine == LowLightAdvice.darkLine)
        #expect(backedOff.visionCaveat)
    }

    @Test("at or under 20 % battery the torch is never lit by the app")
    func lowBatteryNeverAutoLights() {
        let p = LowLightPolicy()
        #expect(LowLightPolicy.minBatteryPct == 20)
        #expect(LowLightPolicy.minBatteryPct == FamilyAlertLimits().lowBatteryPct)
        #expect(!p.canAutoLight(now: 0, batteryPct: 20))
        #expect(!p.canAutoLight(now: 0, batteryPct: 5))
        #expect(p.canAutoLight(now: 0, batteryPct: 21))
        // Unknown battery (nil, or the app's −1 before the first reading) is not a reason to sit
        // in the dark.
        #expect(p.canAutoLight(now: 0, batteryPct: nil))
        #expect(p.canAutoLight(now: 0, batteryPct: -1))
    }

    @Test("a clock that jumps back resets the dwell timers, never the state")
    func clockJumpBackResetsDwellOnly() {
        var p = LowLightPolicy()
        feed(&p, lux: 5, from: 0, until: 4)
        #expect(p.state == .dark)
        let step = p.update(lux: 5, now: 1)          // a new AR session's clock
        #expect(step.state == .dark)
        #expect(!step.didEnterDark && !step.didExitDark)
        feed(&p, lux: 800, from: 1, until: 5.9)      // 4.9 s over 120 since the jump: not yet
        #expect(p.state == .dark)
        feed(&p, lux: 800, from: 5.9, until: 7)
        #expect(p.state == .lit)
    }
}
