//
//  DepthReadinessTests.swift
//  CaneKitLogicTests
//
//  Pins the route-start ARKit/LiDAR interlock without requiring a camera or device.
//
//  Source pinned: `ios/Logic/Sources/CaneKitLogic/DepthReadiness.swift` (`DepthReadiness`: 3
//  consecutive trusted frames with normal tracking and scene depth, frames ≤ `maxFrameGap` apart,
//  a 5 s request bound; `DepthFrameContinuity`: exact sequence increments after a transition
//  boundary). Callers: `DepthEngine` and `AppModel` (app), which hold a route start until `.ready`
//  (Step 22, hardened in Step 25).
//  Breaks these catch: a route starting on a cold session whose first frames are missing,
//  untrusted or limited-tracking (obstacle warnings silently absent for the first steps); a
//  previously-ready run surviving an interruption; a wait that never times out; a healthy 30 Hz
//  start being delayed; and the newest-only frame stream counting reports across a dropped
//  sequence or from before a reconfiguration as fresh evidence.
//  ⚠ `accepts(_:)` is `mutating`: call it into a local before `#expect` (AGENTS.md; inlining it
//  breaks the build, Step 27).
//

import Testing
@testable import CaneKitLogic

/// A cold session cannot become ready from a missing, untrusted or limited-tracking report.
@Test func coldStartNeedsConsecutiveTrustedDepthFrames() {
    var gate = DepthReadiness()
    #expect(gate.begin(at: 10) == .warming)
    #expect(gate.frame(at: 10.01, trackingNormal: false,
                       sceneDepthAvailable: true, reportTrusted: true) == .warming)
    #expect(gate.frame(at: 10.04, trackingNormal: true,
                       sceneDepthAvailable: false, reportTrusted: true) == .warming)
    #expect(gate.frame(at: 10.07, trackingNormal: true,
                       sceneDepthAvailable: true, reportTrusted: false) == .warming)
    #expect(gate.consecutiveFrames == 0)
    #expect(gate.frame(at: 10.10, trackingNormal: true,
                       sceneDepthAvailable: true, reportTrusted: true) == .warming)
    #expect(gate.frame(at: 10.14, trackingNormal: true,
                       sceneDepthAvailable: true, reportTrusted: true) == .warming)
    #expect(gate.frame(at: 10.18, trackingNormal: true,
                       sceneDepthAvailable: true, reportTrusted: true) == .ready)
}

/// An interruption or reconfiguration invalidates a previously-ready run; recovery must earn a
/// fresh consecutive sequence after ARKit resumes.
@Test func interruptionAndResumeRequireFreshEvidence() {
    var gate = DepthReadiness()
    gate.begin(at: 0)
    for t in [0.01, 0.04, 0.07] {
        _ = gate.frame(at: t, trackingNormal: true,
                       sceneDepthAvailable: true, reportTrusted: true)
    }
    #expect(gate.state == .ready)

    #expect(gate.invalidate(at: 2) == .warming)
    #expect(gate.consecutiveFrames == 0)
    #expect(gate.frame(at: 2.01, trackingNormal: true,
                       sceneDepthAvailable: true, reportTrusted: true) == .warming)
    #expect(gate.frame(at: 2.04, trackingNormal: true,
                       sceneDepthAvailable: true, reportTrusted: true) == .warming)
    #expect(gate.frame(at: 2.07, trackingNormal: true,
                       sceneDepthAvailable: true, reportTrusted: true) == .ready)

    // The interruption resets evidence, not the overall five-second request bound.
    gate.cancel()
    gate.begin(at: 0)
    #expect(gate.invalidate(at: 2) == .warming)
    #expect(gate.poll(at: 4.99) == .warming)
    #expect(gate.poll(at: 5) == .timedOut)
}

/// No frames / no recovery ends the wait at the configured bound instead of leaving a route
/// request pending forever.
@Test func warmupTimesOutWithoutRecovery() {
    var gate = DepthReadiness(configuration: .init(requiredFrames: 3,
                                                   maxFrameGap: 0.5,
                                                   timeout: 2))
    gate.begin(at: 100)
    #expect(gate.poll(at: 101.99) == .warming)
    #expect(gate.poll(at: 102) == .timedOut)
    #expect(gate.frame(at: 102.1, trackingNormal: true,
                       sceneDepthAvailable: true, reportTrusted: true) == .timedOut)
}

/// At the normal 30 Hz report cadence, the three-frame bar clears in well under a quarter second;
/// it adds no perceptible delay to a healthy cold start.
@Test func normalFastWarmupClearsImmediately() {
    var gate = DepthReadiness()
    gate.begin(at: 50)
    #expect(gate.frame(at: 50.001, trackingNormal: true,
                       sceneDepthAvailable: true, reportTrusted: true) == .warming)
    #expect(gate.frame(at: 50.034, trackingNormal: true,
                       sceneDepthAvailable: true, reportTrusted: true) == .warming)
    #expect(gate.frame(at: 50.067, trackingNormal: true,
                       sceneDepthAvailable: true, reportTrusted: true) == .ready)
    #expect(gate.consecutiveFrames == 3)
}

/// A long gap is not consecutive freshness, even when both reports are individually valid.
@Test func staleGapRestartsTheRun() {
    var gate = DepthReadiness()
    gate.begin(at: 0)
    _ = gate.frame(at: 0.01, trackingNormal: true,
                   sceneDepthAvailable: true, reportTrusted: true)
    _ = gate.frame(at: 0.04, trackingNormal: true,
                   sceneDepthAvailable: true, reportTrusted: true)
    #expect(gate.consecutiveFrames == 2)
    _ = gate.frame(at: 0.6, trackingNormal: true,
                   sceneDepthAvailable: true, reportTrusted: true)
    #expect(gate.state == .warming)
    #expect(gate.consecutiveFrames == 1)
}

/// The newest-only adapter must not treat reports on either side of a dropped sequence as
/// consecutive freshness evidence.
@Test func publishedFrameContinuityRejectsGapsAndRecovers() {
    var continuity = DepthFrameContinuity()
    continuity.begin(after: 10)
    // `accepts` is `mutating`, and `#expect` expands its argument into a closure that captures the
    // value immutably, so the calls have to happen here. Order matters: each one advances the anchor.
    let next = continuity.accepts(11)
    let afterGap = continuity.accepts(13)
    let resumed = continuity.accepts(14)
    #expect(next)
    #expect(!afterGap)
    #expect(resumed)
}

/// A transition boundary rejects buffered pre-transition reports even when their sequence is
/// otherwise valid, then accepts a contiguous post-boundary run.
@Test func publishedFrameContinuityHonorsTransitionBoundary() {
    var continuity = DepthFrameContinuity()
    continuity.begin(after: 20)
    // Hoisted for the same reason as above: `accepts` mutates, `#expect` cannot call it.
    let atBoundary = continuity.accepts(20)
    let firstAfter = continuity.accepts(21)
    let secondAfter = continuity.accepts(22)
    #expect(!atBoundary)
    #expect(firstAfter)
    #expect(secondAfter)
}
