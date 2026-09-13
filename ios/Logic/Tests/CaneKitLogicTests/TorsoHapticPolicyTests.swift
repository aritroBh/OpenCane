//
//  TorsoHapticPolicyTests.swift
//  CaneKitLogicTests
//
//  Pins TorsoHapticPolicy.swift (cue design v2, Step 41): what the cane does for torso (centre /
//  left / right) obstacles at each Cue detail level × place, on top of `CueDecider`'s decisions.
//  Quiet: no torso haptics. Standard: two onset taps for the centre lane (one tap < 1.5 m and
//  closing, a strong triple < 0.6 m and closing; each once per approach, re-armed by 1.5 s of
//  clear) and no side taps. Detailed: today's loop and side taps, minus a side tap while the side
//  distance has held within ±0.1 m for 2 s (shorelining). Indoors, and a crossing settle, hold every
//  torso cue at every level. The head cue passes through unconditionally (the safety floor,
//  AGENTS.md hard rule 8).
//
//  Fixtures: `report(head:torso:trusted:)` is the CueDeciderTests helper; `Rig` drives one
//  `CueDecider` and one `TorsoHapticPolicy` together with the same `now`, exactly as
//  `AppModel.handle` does, so every expectation here is about the pair the walker feels.
//  Distances metres, times seconds (the AR clock).
//
//  Breaks these catch: Quiet still buzzing for a wall the cane already found; Standard repeating a
//  tap while the walker stands at a post, or tapping for an obstacle that is not getting closer;
//  a shoreline hedge re-tapping every second in Detailed; a curb wait interrupted by torso taps; a
//  level or place change leaving a Geiger loop running; and — worst — any level, place or hold
//  swallowing a head cue.
//

import CaneKitLogic
import Foundation
import Testing

/// A `LaneReport` with the given head / torso lane depths (metres, [left, centre, right];
/// `.infinity` = no return), `depthAvailable` true and `isTrusted` as given.
private func report(head: [Float] = [.infinity, .infinity, .infinity],
                    torso: [Float] = [.infinity, .infinity, .infinity],
                    trusted: Bool = true) -> LaneReport {
    LaneReport(grid: LaneGrid(head: head, torso: torso, centerDepth: .infinity),
               isTrusted: trusted, depthAvailable: true)
}

/// One decider + one policy, stepped together (the app's cue router in miniature).
private struct Rig {
    var decider = CueDecider()
    var policy = TorsoHapticPolicy()
    var rules: CueRules
    var crossing = false

    init(_ rules: CueRules = .default) { self.rules = rules }

    /// Feed one frame at `now`: decider first, then the policy over its output.
    mutating func step(_ r: LaneReport, at now: TimeInterval) -> TorsoHapticAction? {
        let out = decider.update(r, now: now)
        return policy.update(out, report: r, rules: rules, crossingSettle: crossing, now: now)
    }

    /// Walk the centre lane through `distances`, one frame every `dt` seconds from `start`.
    /// Returns the actions in order.
    mutating func centre(_ distances: [Float], from start: TimeInterval = 0, dt: TimeInterval = 0.5) -> [TorsoHapticAction?] {
        distances.enumerated().map { i, d in step(report(torso: [4, d, 4]), at: start + Double(i) * dt) }
    }
}

private let quiet = CueRules(level: .quiet, place: .outdoors)
private let standard = CueRules(level: .standard, place: .outdoors)

@Suite("Torso haptics by level")
struct TorsoHapticPolicyTests {

    // MARK: Quiet

    @Test("Quiet renders no torso haptics: centre, left and right are all suppressed")
    func quietRendersNoTorsoHaptics() {
        var c = Rig(quiet)
        #expect(c.step(report(torso: [4, 1.5, 4]), at: 0) == .suppressed(.centerApproach(distance: 1.5), reason: .quiet))
        #expect(c.step(report(torso: [4, 1.4, 4]), at: 0.1) == nil)          // a held loop update logs nothing
        #expect(c.step(report(torso: [4, 1.0, 4]), at: 1.0) == nil)
        #expect(c.step(report(), at: 1.5) == .stop)                         // the decider's stop still lands
        var l = Rig(quiet)
        #expect(l.step(report(torso: [1.0, 4, 4]), at: 0) == .suppressed(.left, reason: .quiet))
        var r = Rig(quiet)
        #expect(r.step(report(torso: [4, 4, 1.0]), at: 0) == .suppressed(.right, reason: .quiet))
    }

    /// Step 52: the torso cells moved from 1.0 m to 1.6 m. With the overhang signature (ON by
    /// default) a head cell whose torso cell is as near is a wall, not head height; 1.6 m keeps the
    /// centre zone busy (< 2.0 m) while the head cell stays an overhang (≥ 0.5 m nearer). The 1.6 s
    /// fire is the decider's 0.6 m band re-fire (1.0 m onset → 0.5 m, ≥ 1.5 s later), no longer a
    /// 1 Hz repeat.
    @Test("Quiet still renders the head cue, every time the decider fires it")
    func quietStillRendersHead() {
        var rig = Rig(quiet)
        #expect(rig.step(report(head: [4, 1.0, 4], torso: [1.6, 1.6, 1.6]), at: 0) == .render(.head(distance: 1.0, onset: true)))
        #expect(rig.step(report(head: [4, 0.5, 4], torso: [1.6, 1.6, 1.6]), at: 1.6) == .render(.head(distance: 0.5, onset: false)))
    }

    // MARK: Standard — centre onsets

    @Test("Standard taps once when the centre distance is under 1.5 m and closing")
    func standardCenterTapsOnceOnClosingOnset() {
        var rig = Rig(standard)
        // 1.9 m: in the decider's zone, but not under 1.5 m — held, logged once.
        #expect(rig.step(report(torso: [4, 1.9, 4]), at: 0) == .suppressed(.centerApproach(distance: 1.9), reason: .standardCenterHold))
        #expect(rig.step(report(torso: [4, 1.7, 4]), at: 0.5) == nil)
        // 1.45 m, 0.45 m closer than a second ago → the single onset tap.
        #expect(rig.step(report(torso: [4, 1.45, 4]), at: 1.0) == .centerOnset(strong: false, distance: 1.45))
        #expect(rig.step(report(torso: [4, 1.3, 4]), at: 1.5) == nil)
    }

    @Test("Standard does not tap for a centre obstacle that is not getting closer")
    func standardNeedsClosing() {
        var rig = Rig(standard)
        // Standing 1.4 m from a post: under 1.5 m the whole time, never closing.
        let actions = rig.centre([1.4, 1.4, 1.4, 1.4, 1.4, 1.4])
        #expect(actions[0] == .suppressed(.centerApproach(distance: 1.4), reason: .standardCenterHold))
        #expect(actions.dropFirst().allSatisfy { $0 == nil })
        // Creeping in by less than 0.1 m a second is not closing either.
        var slow = Rig(standard)
        let creep = slow.centre([1.45, 1.42, 1.40, 1.38, 1.36, 1.34], dt: 0.5)
        #expect(!creep.contains { if case .centerOnset = $0 { return true } else { return false } })
    }

    @Test("Standard gives the strong triple to a walker inching in slower than the closing test can see")
    func standardStrongTripleFiresOnASlowCreep() {
        // 0.02 m per half second = 0.04 m/s: never "closing" (< 0.1 m over 1 s), yet the post ends
        // up 0.55 m from the torso. Muse (Step 47 review): the slowest approaches are the careful
        // ones, and they must not be the silent ones. The 1.5 m tap still needs closing.
        var rig = Rig(standard)
        let creep = rig.centre([0.70, 0.68, 0.66, 0.64, 0.62, 0.60, 0.58, 0.56], dt: 0.5)
        #expect(!creep.contains { $0 == .centerOnset(strong: false, distance: 0.70) })
        #expect(creep[6] == .centerOnset(strong: true, distance: 0.58))
        #expect(creep[7] == nil)                                            // once per approach
    }

    @Test("a point-blank held torso cell renders at Quiet, Indoors and during a crossing settle")
    func pointBlankBypassesEveryTorsoHold() {
        let held = LaneReport(grid: LaneGrid(head: [4, 4, 4], torso: [4, 0.1, 4], centerDepth: 0.1,
                                             torsoHeld: [false, true, false]),
                              isTrusted: true, depthAvailable: true)
        var q = Rig(quiet)
        let a = q.step(held, at: 0)
        #expect(a == .render(.centerApproach(distance: 0.5)))          // the decider floors at 0.5
        var i = Rig(CueRules(level: .detailed, place: .indoors))
        #expect(i.step(held, at: 0) == .render(.centerApproach(distance: 0.5)))
        var c = Rig(.default); c.crossing = true
        #expect(c.step(held, at: 0) == .render(.centerApproach(distance: 0.5)))
    }

    @Test("torsoIsHeld names every hold and nothing else")
    func torsoIsHeldNamesEveryHold() {
        let p = TorsoHapticPolicy()
        #expect(p.torsoIsHeld(rules: quiet, crossingSettle: false))
        #expect(p.torsoIsHeld(rules: CueRules(level: .detailed, place: .indoors), crossingSettle: false))
        #expect(p.torsoIsHeld(rules: .default, crossingSettle: true))
        #expect(!p.torsoIsHeld(rules: .default, crossingSettle: false))
        #expect(!p.torsoIsHeld(rules: standard, crossingSettle: false))
    }

    @Test("a Standard onset carries a distance no lower than the decider's 0.5 m floor")
    func standardOnsetDistanceIsFloored() {
        var rig = Rig(standard)
        _ = rig.step(report(torso: [4, 2.4, 4]), at: 0)
        _ = rig.step(report(torso: [4, 2.4, 4]), at: 0.5)
        #expect(rig.step(report(torso: [4, 0.3, 4]), at: 1.0) == .centerOnset(strong: true, distance: 0.5))
    }

    @Test("history older than the longest window is pruned even when every sample is stale")
    func staleHistoryIsPrunedAfterAGap() {
        var rig = Rig(standard)
        _ = rig.centre([1.9, 1.9, 1.9])                                     // t = 0, 0.5, 1.0
        // 100 s later (an AR pause with no reset) the centre reads 1.4 m. With the stale 1.9 m
        // samples still in the history this read as "closing" and tapped; pruned, there is no
        // reference ≥ 1 s old and nothing fires.
        #expect(rig.step(report(torso: [4, 1.4, 4]), at: 100) == nil)
    }

    @Test("Standard gives a strong triple once the centre is under 0.6 m")
    func standardStrongTripleBelowSixtyCentimetres() {
        var rig = Rig(standard)
        let actions = rig.centre([1.9, 1.7, 1.45, 1.0, 0.7, 0.55, 0.5, 0.5])
        #expect(actions[2] == .centerOnset(strong: false, distance: 1.45))
        #expect(actions[3] == nil)
        #expect(actions[4] == nil)
        #expect(actions[5] == .centerOnset(strong: true, distance: 0.55))
        #expect(actions[6] == nil)
        #expect(actions[7] == nil)
    }

    @Test("a walker arriving straight at 0.55 m gets the strong triple only, not a tap and a triple")
    func standardStrongTripleAloneWhenNearIsSkipped() {
        var rig = Rig(standard)
        // Fast approach: 2.4 m of clear history, then straight to 0.55 m within the window.
        _ = rig.step(report(torso: [4, 2.4, 4]), at: 0)
        _ = rig.step(report(torso: [4, 2.4, 4]), at: 0.5)
        #expect(rig.step(report(torso: [4, 0.55, 4]), at: 1.0) == .centerOnset(strong: true, distance: 0.55))
        #expect(rig.step(report(torso: [4, 0.5, 4]), at: 1.5) == nil)
        #expect(rig.step(report(torso: [4, 0.4, 4]), at: 2.0) == nil)
    }

    @Test("Standard does not repeat the tap while the distance holds, backs off or re-closes without clearing")
    func standardDoesNotRepeatWhileDistanceHolds() {
        var rig = Rig(standard)
        _ = rig.centre([1.9, 1.7, 1.45])                                   // onset at t = 1.0
        // Hold at 1.3 m for 3 s, back off to 1.8 m (inside the 2.15 m hysteresis), close in again.
        let later = rig.centre([1.3, 1.3, 1.3, 1.3, 1.3, 1.3, 1.8, 1.8, 1.8, 1.4, 1.2, 1.1], from: 1.5)
        #expect(later.allSatisfy { $0 == nil })
    }

    @Test("Standard re-arms both onsets after 1.5 s of clear, not after a brief flicker")
    func standardRearmsAfterClear() {
        var rig = Rig(standard)
        _ = rig.centre([1.9, 1.7, 1.45])                                   // onset at t = 1.0
        // A 0.5 s flicker to clear and back: the decider stops and re-fires, but no new onset.
        #expect(rig.step(report(), at: 1.5) == .stop)
        #expect(rig.step(report(torso: [4, 1.3, 4]), at: 2.0) == .suppressed(.centerApproach(distance: 1.3), reason: .standardCenterHold))
        #expect(rig.step(report(torso: [4, 1.1, 4]), at: 2.5) == nil)
        #expect(rig.step(report(torso: [4, 1.0, 4]), at: 3.0) == nil)
        // Clear for 2 s: a new approach taps again.
        #expect(rig.step(report(), at: 3.5) == .stop)
        _ = rig.step(report(), at: 4.5)
        _ = rig.step(report(), at: 5.5)
        #expect(rig.step(report(torso: [4, 1.9, 4]), at: 5.6) == .suppressed(.centerApproach(distance: 1.9), reason: .standardCenterHold))
        _ = rig.step(report(torso: [4, 1.7, 4]), at: 6.1)
        #expect(rig.step(report(torso: [4, 1.4, 4]), at: 6.6) == .centerOnset(strong: false, distance: 1.4))
    }

    @Test("Standard renders no side taps")
    func standardSuppressesSideTaps() {
        var l = Rig(standard)
        #expect(l.step(report(torso: [1.0, 4, 4]), at: 0) == .suppressed(.left, reason: .standardSide))
        #expect(l.step(report(torso: [1.0, 4, 4]), at: 1.0) == .suppressed(.left, reason: .standardSide))
        var r = Rig(standard)
        #expect(r.step(report(torso: [4, 4, 1.0]), at: 0) == .suppressed(.right, reason: .standardSide))
    }

    @Test("a sweep frame does not feed the closing history (the decider freezes on it, so does the policy)")
    func untrustedFramesDoNotFeedTheClosingHistory() {
        var rig = Rig(standard)
        _ = rig.step(report(torso: [4, 1.9, 4]), at: 0)
        _ = rig.step(report(torso: [4, 1.2, 4], trusted: false), at: 0.3)   // smeared depth mid-sweep
        // Against the trusted 1.9 m a second ago this is closing; against the sweep's 1.2 m it is not.
        #expect(rig.step(report(torso: [4, 1.45, 4]), at: 1.3) == .centerOnset(strong: false, distance: 1.45))
    }

    // MARK: Detailed

    @Test("Detailed + Outdoors is today's behaviour: the centre loop, its updates, left and right taps")
    func detailedIsTodayForCenterAndSides() {
        var c = Rig()
        #expect(c.step(report(torso: [4, 1.5, 4]), at: 0) == .render(.centerApproach(distance: 1.5)))
        #expect(c.step(report(torso: [4, 1.4, 4]), at: 0.1) == .updateCenter(distance: 1.4))
        #expect(c.step(report(torso: [4, 1.4, 4]), at: 0.2) == .updateCenter(distance: 1.4))   // no closing gate
        #expect(c.step(report(), at: 0.6) == .stop)
        var l = Rig()
        #expect(l.step(report(torso: [1.0, 4, 4]), at: 0) == .render(.left))
        #expect(l.step(report(torso: [1.0, 4, 4]), at: 1.0) == .render(.left))
        var r = Rig()
        #expect(r.step(report(torso: [4, 4, 1.0]), at: 0) == .render(.right))
    }

    @Test("a side distance steady within ±0.1 m for 2 s is a shoreline: the tap is suppressed until it changes")
    func steadySideDistanceIsShoreline() {
        var rig = Rig()
        // Trailing a hedge on the left at 1.0 m (readings jitter ±0.05 m), 4 frames a second.
        var t: TimeInterval = 0
        var seen: [TimeInterval: TorsoHapticAction?] = [:]
        for i in 0..<17 {                                   // t = 0 … 4.0
            let d: Float = [1.0, 1.05, 0.95, 1.0][i % 4]
            seen[t] = rig.step(report(torso: [d, 4, 4]), at: t)
            t += 0.25
        }
        #expect(seen[0.0] == .render(.left))                // first contact: no history yet
        #expect(seen[1.0] == .render(.left))                // only 1 s of history
        #expect(seen[2.0] == .suppressed(.left, reason: .shoreline))
        #expect(seen[3.0] == .suppressed(.left, reason: .shoreline))
        #expect(seen[4.0] == .suppressed(.left, reason: .shoreline))
        // The hedge ends and a post stands closer: the reading changes, so the tap comes back.
        for i in 0..<3 { _ = rig.step(report(torso: [0.8, 4, 4]), at: 4.25 + Double(i) * 0.25) }
        #expect(rig.step(report(torso: [0.8, 4, 4]), at: 5.0) == .render(.left))
    }

    @Test("a side reading that drops out breaks the shoreline: the next tap renders")
    func dropoutBreaksShoreline() {
        var rig = Rig()
        for i in 0..<9 { _ = rig.step(report(torso: [4, 4, 1.0]), at: Double(i) * 0.25) }   // t = 0 … 2.0
        #expect(rig.step(report(torso: [4, 4, 1.0]), at: 3.0) == .suppressed(.right, reason: .shoreline))
        _ = rig.step(report(torso: [4, 4, .infinity]), at: 3.25)   // one missing return
        _ = rig.step(report(torso: [4, 4, 1.0]), at: 3.5)
        #expect(rig.step(report(torso: [4, 4, 1.0]), at: 4.0) == .render(.right))
    }

    // MARK: Place and crossing holds

    @Test("Indoors renders no torso haptics at any level; head still renders")
    func indoorsSuppressesTorsoAtEveryLevel() {
        for level in CueLevel.allCases {
            let rules = CueRules(level: level, place: .indoors)
            // Quiet is the walker's standing choice and names itself first; the place otherwise.
            let reason: TorsoSuppressReason = level == .quiet ? .quiet : .indoors
            var c = Rig(rules)
            #expect(c.step(report(torso: [4, 1.0, 4]), at: 0) == .suppressed(.centerApproach(distance: 1.0), reason: reason))
            #expect(c.step(report(torso: [4, 0.5, 4]), at: 1.0) == nil)
            var l = Rig(rules)
            #expect(l.step(report(torso: [1.0, 4, 4]), at: 0) == .suppressed(.left, reason: reason))
            var r = Rig(rules)
            #expect(r.step(report(torso: [4, 4, 1.0]), at: 0) == .suppressed(.right, reason: reason))
            var h = Rig(rules)
            #expect(h.step(report(head: [4, 1.0, 4]), at: 0) == .render(.head(distance: 1.0, onset: true)))
        }
    }

    @Test("a crossing settle holds torso taps in Standard and Detailed, and releases them after")
    func crossingSettleHoldsTorsoTaps() {
        var d = Rig()
        d.crossing = true
        #expect(d.step(report(torso: [4, 1.0, 4]), at: 0) == .suppressed(.centerApproach(distance: 1.0), reason: .crossingSettle))
        #expect(d.step(report(torso: [4, 0.9, 4]), at: 0.5) == nil)
        #expect(d.step(report(), at: 1.0) == .stop)
        #expect(d.step(report(torso: [1.0, 4, 4]), at: 1.5) == .suppressed(.left, reason: .crossingSettle))
        d.crossing = false                                       // the walker crossed
        #expect(d.step(report(torso: [1.0, 4, 4]), at: 2.5) == .render(.left))

        var s = Rig(standard)
        s.crossing = true
        let held = s.centre([1.9, 1.7, 1.45, 1.0])               // would tap at t = 1.0 outdoors
        #expect(held[0] == .suppressed(.centerApproach(distance: 1.9), reason: .crossingSettle))
        #expect(held.dropFirst().allSatisfy { $0 == nil })
        var sh = Rig(standard)
        sh.crossing = true
        #expect(sh.step(report(head: [4, 1.0, 4]), at: 0) == .render(.head(distance: 1.0, onset: true)))
    }

    @Test("a Geiger loop the walker is feeling stops the moment torso cues become held")
    func aRunningLoopStopsWhenTorsoBecomesHeld() {
        var rig = Rig()
        #expect(rig.step(report(torso: [4, 1.5, 4]), at: 0) == .render(.centerApproach(distance: 1.5)))
        rig.rules = quiet                                        // Settings → Cues mid-approach
        #expect(rig.step(report(torso: [4, 1.4, 4]), at: 0.1) == .suppressed(.centerApproach(distance: 1.4), reason: .quiet))
        #expect(rig.step(report(torso: [4, 1.3, 4]), at: 0.2) == nil)
        var curb = Rig()
        _ = curb.step(report(torso: [4, 1.5, 4]), at: 0)
        curb.crossing = true                                     // reached the crossing fence
        #expect(curb.step(report(torso: [4, 1.4, 4]), at: 0.1) == .suppressed(.centerApproach(distance: 1.4), reason: .crossingSettle))
        #expect(curb.step(report(torso: [4, 1.3, 4]), at: 0.2) == nil)
    }

    // MARK: The safety floor

    /// Step 52: torso 1.0 → 1.6 m (see `quietStillRendersHead`), and the second fire is the 0.6 m
    /// band re-fire with its payload.
    @Test("the head cue is rendered at every level, place and hold")
    func headIsNeverSuppressed() {
        for level in CueLevel.allCases {
            for place in CuePlace.allCases {
                for crossing in [false, true] {
                    var rig = Rig(CueRules(level: level, place: place))
                    rig.crossing = crossing
                    #expect(rig.step(report(head: [1.0, 4, 4], torso: [1.6, 1.6, 1.6]), at: 0) == .render(.head(distance: 1.0, onset: true)))
                    #expect(rig.step(report(head: [0.5, 4, 4], torso: [1.6, 1.6, 1.6]), at: 1.6) == .render(.head(distance: 0.5, onset: false)))
                }
            }
        }
    }

    // MARK: Bookkeeping

    @Test("reset forgets the history and re-arms the onsets")
    func resetForgetsHistoryAndArming() {
        var rig = Rig(standard)
        _ = rig.centre([1.9, 1.7, 1.45])                                   // onset at t = 1.0
        rig.policy.reset()
        rig.decider.reset()
        // No history: the first frames are not "closing" whatever they read.
        #expect(rig.step(report(torso: [4, 1.2, 4]), at: 10) == .suppressed(.centerApproach(distance: 1.2), reason: .standardCenterHold))
        _ = rig.step(report(torso: [4, 1.1, 4]), at: 10.5)
        #expect(rig.step(report(torso: [4, 1.0, 4]), at: 11) == .centerOnset(strong: false, distance: 1.0))
    }

    @Test("the numbers are the design's, and the reasons are the trip log's strings")
    func thresholdDefaultsAreTheDesign() {
        let t = TorsoHapticThresholds()
        #expect(t.onsetNearM == 1.5)
        #expect(t.onsetStrongM == 0.6)
        #expect(t.closingDeltaM == 0.1)
        #expect(t.closingWindowS == 1.0)
        #expect(t.rearmClearS == 1.5)
        #expect(t.shorelineBandM == 0.1)
        #expect(t.shorelineWindowS == 2.0)
        #expect(TorsoSuppressReason.allCases.map(\.rawValue) ==
                ["quiet", "indoors", "crossing_settle", "standard_side", "standard_center_hold", "shoreline"])
    }
}
