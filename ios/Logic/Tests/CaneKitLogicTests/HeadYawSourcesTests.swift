//
//  HeadYawSourcesTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins HeadYawSources.swift — the front camera's face anchor as a second source of head
//  yaw for the audio beacon, so the AirPods become optional.
//
//  Key invariants under test:
//    · The face anchor's forward axis maps to a yaw that is **positive to the walker's right**,
//      the same sign convention as `HeadPoseTracker.headYawDeg`, so `BeaconEngine` needs no
//      second code path. Getting this sign wrong would pan the beacon the wrong way, which is
//      the single most dangerous bug this file can have.
//    · A yaw is always *relative* to a recentred reference, and nil until one exists.
//    · A stale face reports nil, never an old direction.
//    · AirPods beat the camera; with neither, the beacon gets 0 (compass only) — the behaviour
//      that shipped before either source existed.
//

import Testing
@testable import CaneKitLogic

// MARK: - Geometry

/// Looking along the world's −Z (ARKit's "forward" at session start) is 0°.
@Test func faceYawIsZeroLookingAlongWorldForward() {
    let yaw = FaceYawGeometry.worldYawDegrees(forwardX: 0, forwardZ: -1)
    #expect(yaw != nil)
    #expect(abs(yaw! - 0) < 0.001)
}

/// The sign convention, which the beacon depends on: +X in ARKit's world is the walker's right at
/// session start, so a head facing +X reads +90°, and −X reads −90°.
/// ⚠ Do not "fix" these signs without a device test of the beacon's left/right after Recenter.
@Test func faceYawIsPositiveToTheRight() {
    #expect(abs(FaceYawGeometry.worldYawDegrees(forwardX: 1, forwardZ: 0)! - 90) < 0.001)
    #expect(abs(FaceYawGeometry.worldYawDegrees(forwardX: -1, forwardZ: 0)! + 90) < 0.001)
}

/// Looking back along +Z is ±180°, and the wrap keeps it inside (−180, 180].
@Test func faceYawWrapsAtTheBack() {
    let yaw = FaceYawGeometry.worldYawDegrees(forwardX: 0, forwardZ: 1)!
    #expect(abs(abs(yaw) - 180) < 0.001)
}

/// A head tipped far enough back that the forward axis is nearly vertical carries no yaw: the
/// horizontal projection is noise, and returning a number there would jerk the beacon.
@Test func faceYawIsNilWhenTheForwardAxisIsNearlyVertical() {
    #expect(FaceYawGeometry.worldYawDegrees(forwardX: 0, forwardZ: 0) == nil)
    #expect(FaceYawGeometry.worldYawDegrees(forwardX: 0.05, forwardZ: -0.05) == nil)
    // Just above the threshold is fine.
    #expect(FaceYawGeometry.worldYawDegrees(forwardX: 0.2, forwardZ: 0) != nil)
}

// MARK: - Tracker

/// Without a reference there is no relative yaw: the world frame's own yaw origin is arbitrary,
/// so publishing it would point the beacon in a random direction.
@Test func faceYawNeedsAReferenceBeforeItReportsAnything() {
    var tracker = FaceYawTracker()
    tracker.ingest(worldYawDeg: 30, now: 0)
    #expect(tracker.yawDeg(now: 0) == nil)
    tracker.recenter()
    #expect(tracker.yawDeg(now: 0) == 0)
}

/// Recentring makes the current head direction "straight ahead", and a later turn is measured
/// from it, positive to the right.
/// Two trackers rather than one turn in each direction: 30° right then 30° left is a 60° step
/// between consecutive samples, which `maxJump` correctly rejects as an anchor glitch.
@Test func faceYawIsMeasuredFromTheRecentredDirection() {
    var right = FaceYawTracker()
    right.smoothing = 1                        // no smoothing, so the arithmetic is visible
    right.ingest(worldYawDeg: 100, now: 0)
    right.recenter()
    right.ingest(worldYawDeg: 130, now: 0.1)
    #expect(abs(right.yawDeg(now: 0.1)! - 30) < 0.001)

    var left = FaceYawTracker()
    left.smoothing = 1
    left.ingest(worldYawDeg: 100, now: 0)
    left.recenter()
    left.ingest(worldYawDeg: 70, now: 0.1)
    #expect(abs(left.yawDeg(now: 0.1)! + 30) < 0.001)
}

/// The relative yaw wraps the short way round, so a head at 170° and a reference at −170° is a
/// 20° turn and not a 340° one.
@Test func faceYawTakesTheShortWayRound() {
    var tracker = FaceYawTracker()
    tracker.smoothing = 1
    tracker.ingest(worldYawDeg: -170, now: 0)
    tracker.recenter()
    tracker.ingest(worldYawDeg: 170, now: 0.1)
    #expect(abs(tracker.yawDeg(now: 0.1)! + 20) < 0.001)
}

/// Smoothing pulls toward the new sample without reaching it, so the beacon follows a head turn
/// rather than jittering with the anchor.
@Test func faceYawSmoothsTowardTheNewSample() {
    var tracker = FaceYawTracker()
    tracker.smoothing = 0.35
    tracker.ingest(worldYawDeg: 0, now: 0)
    tracker.recenter()
    tracker.ingest(worldYawDeg: 40, now: 0.1)
    let first = tracker.yawDeg(now: 0.1)!
    #expect(abs(first - 14) < 0.001)           // 0 + 0.35 × 40
    tracker.ingest(worldYawDeg: 40, now: 0.2)
    let second = tracker.yawDeg(now: 0.2)!
    #expect(second > first && second < 40)     // converging, never overshooting
}

/// A single wild sample (a re-acquired anchor) is dropped, but a *sustained* fast turn is
/// eventually accepted — otherwise the walker would be pinned to a stale direction forever.
@Test func faceYawRejectsAGlitchButNotARealFastTurn() {
    var tracker = FaceYawTracker()
    tracker.smoothing = 1
    tracker.ingest(worldYawDeg: 0, now: 0)
    tracker.recenter()
    tracker.ingest(worldYawDeg: 120, now: 0.1)          // 120° in one frame: not a neck
    #expect(tracker.yawDeg(now: 0.1)! == 0)
    for i in 2...4 { tracker.ingest(worldYawDeg: 120, now: Double(i) / 10) }
    #expect(abs(tracker.yawDeg(now: 0.4)! - 120) < 0.001)
}

/// No face for longer than `maxAge` reports nil. A head pose from a second ago must never steer
/// the beacon: the walker may have turned their head away entirely.
@Test func faceYawGoesNilWhenTheFaceIsStale() {
    var tracker = FaceYawTracker()
    tracker.ingest(worldYawDeg: 10, now: 0)
    tracker.recenter()
    #expect(tracker.isFresh(now: 0.6))
    #expect(tracker.yawDeg(now: 0.6) != nil)
    #expect(!tracker.isFresh(now: 1.0))
    #expect(tracker.yawDeg(now: 1.0) == nil)
}

/// `reset()` forgets the pose *and* the reference, so a new walk never inherits the last one's
/// forward direction.
@Test func faceYawResetForgetsEverything() {
    var tracker = FaceYawTracker()
    tracker.ingest(worldYawDeg: 42, now: 0)
    tracker.recenter()
    tracker.reset()
    #expect(tracker.smoothedWorldYaw == nil)
    #expect(tracker.referenceYaw == nil)
    #expect(tracker.yawDeg(now: 0) == nil)
}

/// `recenterWhenReady` seeds the reference from a fresh sample (so the walker has a forward
/// direction before they ever press Recenter) and refuses to seed from a stale one.
@Test func faceYawSeedsTheReferenceOnlyFromAFreshSample() {
    var tracker = FaceYawTracker()
    tracker.ingest(worldYawDeg: 55, now: 0)
    tracker.recenterWhenReady(now: 0.1)
    #expect(tracker.referenceYaw != nil)

    var stale = FaceYawTracker()
    stale.ingest(worldYawDeg: 55, now: 0)
    stale.recenterWhenReady(now: 5)
    #expect(stale.referenceYaw == nil)
}

/// The hop rate `DepthEngine`'s anchor relay throttles to: the depth pipeline publishes at 30 Hz
/// normally, but the beacon renders at 10 Hz, so a 15 Hz relay cap avoids needless main-actor work.
@Test func faceYawPublishIntervalKeepsRelayBounded() {
    #expect(abs(FaceYawTracker.publishInterval - 1.0 / 15) < 1e-9)
}

// MARK: - Selector

/// AirPods win whenever they have a value: they are on the head, they work in the dark, and they
/// do not need the walker's face inside the front camera's cone.
@Test func headYawPrefersAirPodsOverTheCamera() {
    let choice = HeadYawSelector.choose(airPodsYaw: 12, faceYaw: -40, recenterPending: false)
    #expect(choice == HeadYawChoice(degrees: 12, source: .airPods))
}

/// No AirPods → the front camera. This is the whole point: head tracking with no AirPods.
@Test func headYawFallsBackToTheCamera() {
    let choice = HeadYawSelector.choose(airPodsYaw: nil, faceYaw: -40, recenterPending: false)
    #expect(choice == HeadYawChoice(degrees: -40, source: .face))
}

/// Neither source → 0 and `.none`: the beacon pans from the compass alone, exactly as it did
/// before either source existed.
@Test func headYawFallsBackToTheCompassAlone() {
    let choice = HeadYawSelector.choose(airPodsYaw: nil, faceYaw: nil, recenterPending: false)
    #expect(choice == HeadYawChoice(degrees: 0, source: .none))
}

/// While a recenter is pending (between a waypoint advance and the next re-zero) both references
/// belong to the previous leg, so the yaw is forced to 0 — adding it to the phone heading would
/// double-count the body turn (AGENTS.md). The *source* is still reported, for the log.
@Test func headYawIsZeroWhileARecenterIsPending() {
    let airPods = HeadYawSelector.choose(airPodsYaw: 35, faceYaw: nil, recenterPending: true)
    #expect(airPods == HeadYawChoice(degrees: 0, source: .airPods))
    let face = HeadYawSelector.choose(airPodsYaw: nil, faceYaw: 35, recenterPending: true)
    #expect(face == HeadYawChoice(degrees: 0, source: .face))
}

/// A non-finite yaw can never reach the beacon: `AVAudioEnvironmentNode` with a NaN listener yaw
/// silences the graph, which would take the beacon away without a word.
@Test func headYawNeverPassesANonFiniteValue() {
    let choice = HeadYawSelector.choose(airPodsYaw: .nan, faceYaw: nil, recenterPending: false)
    #expect(choice.degrees == 0)
    #expect(choice.source == .airPods)
}
