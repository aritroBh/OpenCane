//
//  DepthReadinessTests.swift
//  CaneKitLogicTests
//
//  Pins the route-start ARKit/LiDAR interlock without requiring a camera or device.
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
    #expect(continuity.accepts(11))
    #expect(!continuity.accepts(13))
    #expect(continuity.accepts(14))
}

/// A transition boundary rejects buffered pre-transition reports even when their sequence is
/// otherwise valid, then accepts a contiguous post-boundary run.
@Test func publishedFrameContinuityHonorsTransitionBoundary() {
    var continuity = DepthFrameContinuity()
    continuity.begin(after: 20)
    #expect(!continuity.accepts(20))
    #expect(continuity.accepts(21))
    #expect(continuity.accepts(22))
}
