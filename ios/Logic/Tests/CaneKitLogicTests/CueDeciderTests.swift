import Testing
@testable import CaneKitLogic

private func report(head: [Float] = [.infinity, .infinity, .infinity],
                    torso: [Float] = [.infinity, .infinity, .infinity],
                    trusted: Bool = true) -> LaneReport {
    LaneReport(grid: LaneGrid(head: head, torso: torso, centerDepth: .infinity),
               isTrusted: trusted, depthAvailable: true)
}

@Test func centerApproachFiresThenUpdatesDistance() {
    let d = CueDecider()
    #expect(d.update(report(torso: [4, 1.5, 4]), now: 0) == .fire(.centerApproach(distance: 1.5)))
    #expect(d.update(report(torso: [4, 1.4, 4]), now: 0.1) == .updateCenter(distance: 1.4))
    #expect(d.active == .center)
}

@Test func centerDistanceIsClampedToNearFloor() {
    let d = CueDecider()
    #expect(d.update(report(torso: [4, 0.3, 4]), now: 0) == .fire(.centerApproach(distance: 0.5)))
}

@Test func hysteresisHoldsUntilPlusFifteenCentimetres() {
    let d = CueDecider()
    #expect(d.update(report(torso: [4, 1.95, 4]), now: 0) == .fire(.centerApproach(distance: 1.95)))
    #expect(d.update(report(torso: [4, 2.05, 4]), now: 0.1) == .updateCenter(distance: 2.05))
    #expect(d.update(report(torso: [4, 2.14, 4]), now: 0.2) == .updateCenter(distance: 2.14))
    #expect(d.update(report(torso: [4, 2.2, 4]), now: 0.3) == .stop)
    #expect(d.active == .clear)
    #expect(d.update(report(torso: [4, 2.2, 4]), now: 0.4) == nil)
}

@Test func cueChangeNeeds400ms() {
    let d = CueDecider()
    #expect(d.update(report(torso: [1.0, 4, 4]), now: 0) == .fire(.left))
    #expect(d.update(report(head: [4, 1.0, 4], torso: [1.0, 4, 4]), now: 0.2) == nil)
    #expect(d.active == .left)
    #expect(d.update(report(head: [4, 1.0, 4], torso: [1.0, 4, 4]), now: 0.5) == .fire(.head))
}

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

@Test func sameCueDoesNotRefireWithinOneSecondAcrossAClear() {
    let d = CueDecider()
    #expect(d.update(report(torso: [1.0, 4, 4]), now: 0) == .fire(.left))
    #expect(d.update(report(torso: [4, 4, 4]), now: 0.5) == .stop)
    #expect(d.update(report(torso: [1.0, 4, 4]), now: 0.8) == nil)      // 0.8 s since last left
    #expect(d.update(report(torso: [1.0, 4, 4]), now: 1.0) == .fire(.left))
}

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

@Test func headReturningAfterClearWaitsOutTheFloor() {
    let d = CueDecider()
    #expect(d.update(report(head: [4, 1.0, 4]), now: 0) == .fire(.head))
    #expect(d.update(report(), now: 0.4) == .stop)
    #expect(d.update(report(head: [4, 1.0, 4]), now: 0.8) == nil)
    #expect(d.update(report(head: [4, 1.0, 4]), now: 1.0) == .fire(.head))
}

@Test func centerLoopIsExemptFromTheFloor() {
    let d = CueDecider()
    #expect(d.update(report(torso: [4, 1.5, 4]), now: 0) == .fire(.centerApproach(distance: 1.5)))
    #expect(d.update(report(torso: [4, 4, 4]), now: 0.5) == .stop)
    #expect(d.update(report(torso: [4, 1.5, 4]), now: 0.9) == .fire(.centerApproach(distance: 1.5)))
}

@Test func headCueKeepsRefiringWhileObstaclePersists() {
    let d = CueDecider()
    let r = report(head: [1.2, 4, 4])
    #expect(d.update(r, now: 0) == .fire(.head))
    #expect(d.update(r, now: 1.0) == .fire(.head))
    #expect(d.update(r, now: 2.0) == .fire(.head))
    #expect(d.update(r, now: 3.0) == .fire(.head))
}

@Test func headBeatsCenterBeatsSides() {
    let d = CueDecider()
    #expect(d.update(report(head: [4, 1.0, 4], torso: [1.0, 1.0, 1.0]), now: 0) == .fire(.head))
    let e = CueDecider()
    #expect(e.update(report(torso: [1.0, 1.0, 1.0]), now: 0) == .fire(.centerApproach(distance: 1.0)))
    let f = CueDecider()
    #expect(f.update(report(torso: [1.0, 4, 1.0]), now: 0) == .fire(.left))
}

@Test func untrustedFramesFreezeState() {
    let d = CueDecider()
    #expect(d.update(report(torso: [1.0, 4, 4]), now: 0) == .fire(.left))
    #expect(d.update(report(torso: [4, 4, 4], trusted: false), now: 1.5) == nil)
    #expect(d.active == .left)
    #expect(d.update(report(torso: [4, 4, 4]), now: 1.6) == .stop)
}

@Test func noDepthMeansNothing() {
    let d = CueDecider()
    var r = report(torso: [1.0, 4, 4])
    r.depthAvailable = false
    #expect(d.update(r, now: 0) == nil)
}

@Test func geigerRateScalesWithInverseDistance() {
    #expect(GeigerRate.hertz(distance: 2.0) == 2)
    #expect(GeigerRate.hertz(distance: 1.0) == 4)
    #expect(GeigerRate.hertz(distance: 0.5) == 8)
    #expect(GeigerRate.hertz(distance: 0.1) == 8)
    #expect(GeigerRate.hertz(distance: 10) == 2)
    #expect(GeigerRate.hertz(distance: .infinity) == 2)
}
