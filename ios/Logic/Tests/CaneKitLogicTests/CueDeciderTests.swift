//
//  CueDeciderTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins CueDecider.swift — the obstacle haptic grammar: centre approach loop with a
//  0.5 m floor, 0.15 m hysteresis, 400 ms between cue changes, 1 s per-cue repeat floor (also
//  across a clear or a change), head > centre > left > right priority, freeze on untrusted
//  (sweeping) frames, and the 2–8 Hz Geiger rate.
//
//  Key invariants / fixtures: `report(head:torso:trusted:)` builds a depth-available report;
//  4 m means "clear" for every lane used here. Distances metres, times seconds.
//

import Testing
@testable import CaneKitLogic

private func report(head: [Float] = [.infinity, .infinity, .infinity],
                    torso: [Float] = [.infinity, .infinity, .infinity],
                    trusted: Bool = true) -> LaneReport {
    LaneReport(grid: LaneGrid(head: head, torso: torso, centerDepth: .infinity),
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
    #expect(d.update(report(head: [4, 1.0, 4], torso: [1.0, 4, 4]), now: 0.5) == .fire(.head))
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

/// A sign flapping across the head threshold does not double-hit inside 1 s.
@Test func headReturningAfterClearWaitsOutTheFloor() {
    let d = CueDecider()
    #expect(d.update(report(head: [4, 1.0, 4]), now: 0) == .fire(.head))
    #expect(d.update(report(), now: 0.4) == .stop)
    #expect(d.update(report(head: [4, 1.0, 4]), now: 0.8) == nil)
    #expect(d.update(report(head: [4, 1.0, 4]), now: 1.0) == .fire(.head))
}

/// The continuous centre loop may restart right after a stop (it is not a discrete tap).
@Test func centerLoopIsExemptFromTheFloor() {
    let d = CueDecider()
    #expect(d.update(report(torso: [4, 1.5, 4]), now: 0) == .fire(.centerApproach(distance: 1.5)))
    #expect(d.update(report(torso: [4, 4, 4]), now: 0.5) == .stop)
    #expect(d.update(report(torso: [4, 1.5, 4]), now: 0.9) == .fire(.centerApproach(distance: 1.5)))
}

/// Under a long overhang the head hit keeps repeating every second.
@Test func headCueKeepsRefiringWhileObstaclePersists() {
    let d = CueDecider()
    let r = report(head: [1.2, 4, 4])
    #expect(d.update(r, now: 0) == .fire(.head))
    #expect(d.update(r, now: 1.0) == .fire(.head))
    #expect(d.update(r, now: 2.0) == .fire(.head))
    #expect(d.update(r, now: 3.0) == .fire(.head))
}

/// With obstacles everywhere the head cue wins, then centre, then left.
@Test func headBeatsCenterBeatsSides() {
    let d = CueDecider()
    #expect(d.update(report(head: [4, 1.0, 4], torso: [1.0, 1.0, 1.0]), now: 0) == .fire(.head))
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

/// Before the first LiDAR frame (or on a non-LiDAR phone) no cue is ever emitted.
@Test func noDepthMeansNothing() {
    let d = CueDecider()
    var r = report(torso: [1.0, 4, 4])
    r.depthAvailable = false
    #expect(d.update(r, now: 0) == nil)
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
