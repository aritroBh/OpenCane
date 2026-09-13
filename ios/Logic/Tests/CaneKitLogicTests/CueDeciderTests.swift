//
//  CueDeciderTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins CueDecider.swift and HeadGate.swift — the obstacle haptic grammar: centre
//  approach loop with a 0.5 m floor, 0.15 m hysteresis, 400 ms between cue changes, 1 s per-cue
//  repeat floor for side cues (also across a clear or a change), head > centre > left > right
//  priority, freeze on untrusted (sweeping) frames, the 2–8 Hz Geiger rate, and (Step 52) the head
//  episode: the overhang signature (`HeadGate`), onset at once, re-fire only on crossing the
//  1.0 / 0.6 m bands ≥ 1.5 s apart, episode end after 2 s of trusted clear.
//
//  Key invariants / fixtures: `report(head:torso:trusted:headCoverage:torsoCoverage:)` builds a
//  depth-available report; 4 m means "clear" for every lane used here. Distances metres, times
//  seconds.
//
//  Caller of the pinned code: `AppModel` (one `CueDecider`, fed every `LaneReport` with
//  `now = report.timestamp`, the AR clock) → `TorsoHapticPolicy` → `HapticPlayer` /
//  `CueSpeechPolicy`. These numbers are the spec'd haptic grammar: re-run all of them plus a cane
//  walk before changing any (CODE_REFERENCE `CueDecider.swift` ⚠). Breaks these catch: a
//  flickering centre loop at the 2 m edge, the hand being hit by rapid cue changes, a doorway edge
//  re-tapping inside 1 s, the wrong cue winning when several lanes are blocked, a sweep frame firing
//  or stopping a cue, a cue before the first LiDAR frame — and the first cane walk's "head height,
//  head height": a wall called head height, a 1 Hz head buzz under a sign, an episode split by one
//  clear frame, a cell the camera cannot see alarming.
//

import Testing
@testable import CaneKitLogic

/// A `LaneReport` with the given head / torso lane depths (metres, [left, centre, right];
/// `.infinity` = no return), `centerDepth` infinite, `depthAvailable` true and `isTrusted` as given
/// (false = a mid-sweep frame the decider must freeze on).
/// `headCoverage` / `torsoCoverage` default to all true (a band the camera can see, Step 51).
private func report(head: [Float] = [.infinity, .infinity, .infinity],
                    torso: [Float] = [.infinity, .infinity, .infinity],
                    trusted: Bool = true,
                    headCoverage: [Bool] = [true, true, true],
                    torsoCoverage: [Bool] = [true, true, true]) -> LaneReport {
    LaneReport(grid: LaneGrid(head: head, torso: torso, centerDepth: .infinity,
                              headCoverage: headCoverage, torsoCoverage: torsoCoverage),
               isTrusted: trusted, depthAvailable: true)
}

/// Walking toward a post: the centre loop starts once, then only its distance updates.
@Test func centerApproachFiresThenUpdatesDistance() {
    let d = CueDecider()
    #expect(d.update(report(torso: [4, 1.5, 4]), now: 0) == .fire(.centerApproach(distance: 1.5)))
    #expect(d.update(report(torso: [4, 1.4, 4]), now: 0.1) == .updateCenter(distance: 1.4))
    #expect(d.active == .center)
}

/// Right up against an obstacle the approach cue reports the 0.5 m floor (max pulse rate).
@Test func centerDistanceIsClampedToNearFloor() {
    let d = CueDecider()
    #expect(d.update(report(torso: [4, 0.3, 4]), now: 0) == .fire(.centerApproach(distance: 0.5)))
}

/// An obstacle hovering at the 2 m edge does not flicker the centre cue on and off.
@Test func hysteresisHoldsUntilPlusFifteenCentimetres() {
    let d = CueDecider()
    #expect(d.update(report(torso: [4, 1.95, 4]), now: 0) == .fire(.centerApproach(distance: 1.95)))
    #expect(d.update(report(torso: [4, 2.05, 4]), now: 0.1) == .updateCenter(distance: 2.05))
    #expect(d.update(report(torso: [4, 2.14, 4]), now: 0.2) == .updateCenter(distance: 2.14))
    #expect(d.update(report(torso: [4, 2.2, 4]), now: 0.3) == .stop)
    #expect(d.active == .clear)
    #expect(d.update(report(torso: [4, 2.2, 4]), now: 0.4) == nil)
}

/// A cue switch (left → head) waits 400 ms so the hand is not hit by rapid changes.
@Test func cueChangeNeeds400ms() {
    let d = CueDecider()
    #expect(d.update(report(torso: [1.0, 4, 4]), now: 0) == .fire(.left))
    #expect(d.update(report(head: [4, 1.0, 4], torso: [1.0, 4, 4]), now: 0.2) == nil)
    #expect(d.active == .left)
    #expect(d.update(report(head: [4, 1.0, 4], torso: [1.0, 4, 4]), now: 0.5) == .fire(.head(distance: 1.0, onset: true)))
}

/// A wall on the right re-taps at most once per second.
@Test func sameDiscreteCueRepeatsAtMostOncePerSecond() {
    let d = CueDecider()
    let r = report(torso: [4, 4, 1.0])
    #expect(d.update(r, now: 0) == .fire(.right))
    #expect(d.update(r, now: 0.5) == nil)
    #expect(d.update(r, now: 0.99) == nil)
    #expect(d.update(r, now: 1.0) == .fire(.right))
    #expect(d.update(r, now: 1.5) == nil)
    #expect(d.update(r, now: 2.0) == .fire(.right))
}

/// A doorway edge blinking in and out does not re-tap left inside 1 s.
@Test func sameCueDoesNotRefireWithinOneSecondAcrossAClear() {
    let d = CueDecider()
    #expect(d.update(report(torso: [1.0, 4, 4]), now: 0) == .fire(.left))
    #expect(d.update(report(torso: [4, 4, 4]), now: 0.5) == .stop)
    #expect(d.update(report(torso: [1.0, 4, 4]), now: 0.8) == nil)      // 0.8 s since last left
    #expect(d.update(report(torso: [1.0, 4, 4]), now: 1.0) == .fire(.left))
}

/// Flickering left ↔ right stops the old cue and waits out the 1 s floor before left again.
@Test func sameCueDoesNotRefireWithinOneSecondAcrossAChange() {
    let d = CueDecider()
    #expect(d.update(report(torso: [1.0, 4, 4]), now: 0) == .fire(.left))
    #expect(d.update(report(torso: [4, 4, 1.0]), now: 0.4) == .fire(.right))
    // Left is back only 0.8 s after it last fired: stop the right cue, wait out the floor.
    #expect(d.update(report(torso: [1.0, 4, 4]), now: 0.8) == .stop)
    #expect(d.active == .clear)
    #expect(d.update(report(torso: [1.0, 4, 4]), now: 1.0) == nil)      // 400 ms change gate
    #expect(d.update(report(torso: [1.0, 4, 4]), now: 1.25) == .fire(.left))
}

/// A sign flapping across the head exit line is one episode: the zone clears (`.stop`, the
/// hysteresis is unchanged) but a return inside 2 s is silent; only after 2 s of trusted clear is
/// the next entry a new onset.
/// History: pre-Step 52 this was `headReturningAfterClearWaitsOutTheFloor` (the return re-fired
/// once the 1 s repeat floor passed, and the speech episode ended on the `.stop`); the Gemini first
/// pass held the `.stop` for 2 s instead, which left a stale cue "active" on the hand.
@Test func headFlappingAcrossTheExitLineIsOneEpisode() {
    let d = CueDecider()
    #expect(d.update(report(head: [4, 1.0, 4]), now: 0) == .fire(.head(distance: 1.0, onset: true)))
    #expect(d.update(report(), now: 0.4) == .stop)
    #expect(d.update(report(head: [4, 1.0, 4]), now: 0.8) == nil)      // same episode: silent
    #expect(d.update(report(head: [4, 1.0, 4]), now: 1.0) == nil)
    #expect(d.update(report(), now: 1.2) == .stop)
    #expect(d.update(report(), now: 3.1) == nil)                       // 1.9 s of clear
    #expect(d.headEpisodeActive)
    #expect(d.update(report(head: [4, 1.0, 4]), now: 3.3) == .fire(.head(distance: 1.0, onset: true)))
}

/// The continuous centre loop may restart right after a stop (it is not a discrete tap).
@Test func centerLoopIsExemptFromTheFloor() {
    let d = CueDecider()
    #expect(d.update(report(torso: [4, 1.5, 4]), now: 0) == .fire(.centerApproach(distance: 1.5)))
    #expect(d.update(report(torso: [4, 4, 4]), now: 0.5) == .stop)
    #expect(d.update(report(torso: [4, 1.5, 4]), now: 0.9) == .fire(.centerApproach(distance: 1.5)))
}

/// Under a sign the head haptic fires at the onset and then only when the walker crosses 1.0 m and
/// 0.6 m, each once, ≥ 1.5 s after the previous fire — never on time alone.
/// History: pre-Step 52 this was `headCueKeepsRefiringWhileObstaclePersists` (a 1 Hz re-fire for as
/// long as the sign was in range: 137 head cues in 12 minutes on the first cane walk).
@Test func headFiresAtOnsetThenOnlyOnCloserBands() {
    let d = CueDecider()
    #expect(d.update(report(head: [4, 1.2, 4]), now: 0) == .fire(.head(distance: 1.2, onset: true)))
    #expect(d.update(report(head: [4, 1.2, 4]), now: 1) == nil)
    #expect(d.update(report(head: [4, 1.2, 4]), now: 2) == nil)
    #expect(d.update(report(head: [4, 1.2, 4]), now: 3) == nil)
    #expect(d.update(report(head: [4, 0.95, 4]), now: 4) == .fire(.head(distance: 0.95, onset: false)))
    #expect(d.update(report(head: [4, 0.55, 4]), now: 5.0) == nil)     // < 1.5 s since the last fire
    #expect(d.update(report(head: [4, 0.55, 4]), now: 5.6) == .fire(.head(distance: 0.55, onset: false)))
    #expect(d.update(report(head: [4, 0.3, 4]), now: 8) == nil)        // both bands used
}

/// A 1.2 m sign that jumps to 0.5 m (a step and a lean) crosses both bands at once: one fire.
@Test func aJumpAcrossBothBandsFiresOnce() {
    let d = CueDecider()
    #expect(d.update(report(head: [1.2, 4, 4]), now: 0) == .fire(.head(distance: 1.2, onset: true)))
    #expect(d.update(report(head: [0.5, 4, 4]), now: 2) == .fire(.head(distance: 0.5, onset: false)))
    #expect(d.update(report(head: [0.3, 4, 4]), now: 4) == nil)
}

/// Hard rule 8: a head onset is never delayed by a repeat floor. Even with a 10 s
/// `repeatInterval`, the first head cue of a new episode fires on its first frame.
/// (Plan name: `firstHeadCueIsNeverDelayed`.)
@Test func headOnsetIsNeverHeldByTheRepeatFloor() {
    var t = CueThresholds()
    t.repeatInterval = 10
    let d = CueDecider(thresholds: t)
    #expect(d.update(report(head: [4, 1.0, 4]), now: 0) == .fire(.head(distance: 1.0, onset: true)))
    #expect(d.update(report(), now: 0.5) == .stop)
    #expect(d.update(report(), now: 2.5) == nil)                       // episode ends here
    #expect(!d.headEpisodeActive)
    #expect(d.update(report(head: [4, 1.0, 4]), now: 2.6) == .fire(.head(distance: 1.0, onset: true)))
}

/// The episode ends after exactly 2 s of trusted clear, not on the first clear frame.
/// (Plan name: `headEpisodeEndsAfterTwoSecondsTrustedClear`.)
@Test func headEpisodeEndsOnlyAfterTwoSecondsOfTrustedClear() {
    let d = CueDecider()
    #expect(d.update(report(head: [4, 1.0, 4]), now: 0) == .fire(.head(distance: 1.0, onset: true)))
    #expect(d.update(report(), now: 0.5) == .stop)
    #expect(d.update(report(), now: 1.5) == nil)
    #expect(d.update(report(), now: 2.4) == nil)
    #expect(d.headEpisodeActive)
    #expect(d.update(report(), now: 2.5) == nil)
    #expect(!d.headEpisodeActive)
    #expect(d.update(report(head: [4, 1.0, 4]), now: 2.6) == .fire(.head(distance: 1.0, onset: true)))
}

/// A sweep (untrusted frames) in the middle of the clear restarts the 2 s clock: the smeared
/// frames are no evidence that the overhang is gone. (Plan name: `untrustedFramesDoNotEndAnEpisode`.)
@Test func aSweepRestartsTheClearClock() {
    let d = CueDecider()
    #expect(d.update(report(head: [4, 1.0, 4]), now: 0) == .fire(.head(distance: 1.0, onset: true)))
    #expect(d.update(report(), now: 0.5) == .stop)
    #expect(d.update(report(trusted: false), now: 1.5) == nil)         // clock restarts
    #expect(d.update(report(), now: 2.0) == nil)                       // clear run starts again
    #expect(d.update(report(), now: 2.6) == nil)
    #expect(d.headEpisodeActive)                                       // 2.6 s since 0.5, but 0.6 s since the sweep
    #expect(d.update(report(head: [4, 1.0, 4]), now: 3.0) == nil)      // still the same episode
}

/// With obstacles everywhere the head cue wins, then centre, then left — but a head cell with an
/// equally near torso cell is a wall (centre), not head height.
/// History: pre-Step 52 the first case (head 1.0 over torso 1.0 everywhere) fired `.head`; with the
/// overhang signature ON (owner decision 2026-09-13) it is the centre approach, and the head case
/// needs a clear torso under the head cell.
@Test func headBeatsCenterBeatsSides() {
    let d = CueDecider()
    #expect(d.update(report(head: [4, 1.0, 4], torso: [1.0, 1.0, 1.0]), now: 0) == .fire(.centerApproach(distance: 1.0)))
    let h = CueDecider()
    #expect(h.update(report(head: [4, 1.0, 4], torso: [1.0, .infinity, 1.0]), now: 0) == .fire(.head(distance: 1.0, onset: true)))
    let e = CueDecider()
    #expect(e.update(report(torso: [1.0, 1.0, 1.0]), now: 0) == .fire(.centerApproach(distance: 1.0)))
    let f = CueDecider()
    #expect(f.update(report(torso: [1.0, 4, 1.0]), now: 0) == .fire(.left))
}

/// Sweeping the cane (smeared depth) neither fires nor stops cues until a steady frame.
@Test func untrustedFramesFreezeState() {
    let d = CueDecider()
    #expect(d.update(report(torso: [1.0, 4, 4]), now: 0) == .fire(.left))
    #expect(d.update(report(torso: [4, 4, 4], trusted: false), now: 1.5) == nil)
    #expect(d.active == .left)
    #expect(d.update(report(torso: [4, 4, 4]), now: 1.6) == .stop)
}

/// Walking point-blank into a wall (< 0.7 m): when LiDAR saturates and drops to .infinity (dropout),
/// the urgent cue latches active for nearDropoutHoldSeconds rather than clearing.
@Test func nearDropoutHoldsUrgentObstacleAcrossBlindZone() {
    let d = CueDecider()
    // Approach a wall: at 0.5 m, centre approach fires.
    #expect(d.update(report(torso: [4, 0.5, 4]), now: 0) == .fire(.centerApproach(distance: 0.5)))
    #expect(d.active == .center)
    // Walk into point-blank wall: LiDAR drops out completely to .infinity.
    // Proximity latch holds the cue active at maximum rate!
    #expect(d.update(report(torso: [4, .infinity, 4]), now: 0.5) == .updateCenter(distance: 0.5))
    #expect(d.active == .center)
    #expect(d.update(report(torso: [4, .infinity, 4]), now: 1.0) == .updateCenter(distance: 0.5))
    #expect(d.active == .center)
    // After nearDropoutHoldSeconds (1.5 s since last finite near reading), it stops if still empty.
    #expect(d.update(report(torso: [4, .infinity, 4]), now: 1.6) == .stop)
    #expect(d.active == .clear)
}

/// Before the first LiDAR frame (or on a non-LiDAR phone) no cue is ever emitted.
@Test func noDepthMeansNothing() {
    let d = CueDecider()
    var r = report(torso: [1.0, 4, 4])
    r.depthAvailable = false
    #expect(d.update(r, now: 0) == nil)
}

// MARK: Step 52 — the overhang signature (HeadGate)

/// A wall (or a person, a door) is near in both bands: it goes to the torso logic, not "Head height."
/// History: the Gemini first pass named this `overhangSignatureRequiresTorsoFarther` and set the flag
/// by hand; the signature is the default now.
@Test func wallNearInBothBandsIsNotHead() {
    let d = CueDecider()
    #expect(d.update(report(head: [4, 1.0, 4], torso: [4, 1.0, 4]), now: 0) == .fire(.centerApproach(distance: 1.0)))
    #expect(HeadGate.candidate(in: report(head: [1.0, 1.0, 1.0], torso: [1.0, 1.0, 1.0]).grid,
                               enter: 1.5, overhangGap: 0.5) == nil)
}

/// A sign or branch with nothing under it (torso far) is head height.
@Test func hangingSignWithClearTorsoIsHead() {
    let d = CueDecider()
    #expect(d.update(report(head: [4, 1.0, 4], torso: [4, 2.5, 4]), now: 0) == .fire(.head(distance: 1.0, onset: true)))
    #expect(HeadGate.candidate(in: report(head: [4, 1.0, 4], torso: [4, 2.5, 4]).grid, enter: 1.5, overhangGap: 0.5)
            == HeadGate.Candidate(lane: 1, distance: 1.0))
}

/// The gap is inclusive: torso exactly 0.5 m farther is an overhang, 1 cm less is a wall.
@Test func torsoHalfAMetreFartherIsHead() {
    let d = CueDecider()
    #expect(d.update(report(head: [4, 1.0, 4], torso: [4, 1.5, 4]), now: 0) == .fire(.head(distance: 1.0, onset: true)))
    let e = CueDecider()
    #expect(e.update(report(head: [4, 1.0, 4], torso: [4, 1.49, 4]), now: 0) == .fire(.centerApproach(distance: 1.49)))
}

/// Fail-safe: a torso dropout (no return — glass, sunlight) under a near head cell keeps the warning.
@Test func torsoNoDataFailsSafeToHead() {
    let d = CueDecider()
    #expect(d.update(report(head: [4, 1.0, 4], torso: [4, .infinity, 4]), now: 0) == .fire(.head(distance: 1.0, onset: true)))
}

/// The valve: `requireOverhangSignature = false` restores the pre-Step 52 rule (any covered head
/// cell under 1.5 m is head height).
@Test func overhangSignatureCanBeSwitchedOff() {
    var t = CueThresholds()
    t.requireOverhangSignature = false
    let d = CueDecider(thresholds: t)
    #expect(d.update(report(head: [4, 1.0, 4], torso: [4, 1.0, 4]), now: 0) == .fire(.head(distance: 1.0, onset: true)))
}

/// Step 51: a head cell the camera cannot see (`headCoverage` false) never alarms, and the nearest
/// *covered* lane wins.
@Test func headIgnoresLanesWithoutCoverage() {
    let d = CueDecider()
    #expect(d.update(report(head: [1.0, 4, 4], headCoverage: [false, true, true]), now: 0) == nil)
    let e = CueDecider()
    #expect(e.update(report(head: [1.0, 1.2, 4], headCoverage: [false, true, true]), now: 0)
            == .fire(.head(distance: 1.2, onset: true)))
}

/// Fail-safe: an uncovered torso cell cannot prove the head cell is a wall, so the head warning
/// stays (the torso value here is a hand-built 1.0 m to show the flag, not the value, decides).
@Test func torsoWithoutCoverageFailsSafeToHead() {
    let d = CueDecider()
    #expect(d.update(report(head: [4, 1.0, 4], torso: [4, 1.0, 4], torsoCoverage: [true, false, true]), now: 0)
            == .fire(.head(distance: 1.0, onset: true)))
}

/// Approach pulses go 2 Hz at 2 m to 8 Hz at 0.5 m and stay clamped outside that range.
@Test func geigerRateScalesWithInverseDistance() {
    #expect(GeigerRate.hertz(distance: 2.0) == 2)
    #expect(GeigerRate.hertz(distance: 1.0) == 4)
    #expect(GeigerRate.hertz(distance: 0.5) == 8)
    #expect(GeigerRate.hertz(distance: 0.1) == 8)
    #expect(GeigerRate.hertz(distance: 10) == 2)
    #expect(GeigerRate.hertz(distance: .infinity) == 2)
}
