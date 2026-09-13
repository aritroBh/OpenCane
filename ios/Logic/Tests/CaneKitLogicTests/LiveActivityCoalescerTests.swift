//
//  LiveActivityCoalescerTests.swift
//  CaneKitLogicTests
//
//  Unit tests for LiveActivityCoalescer and LiveActivitySnapshot decoding compatibility.
//

import Foundation
import Testing
@testable import CaneKitLogic

@Suite("LiveActivityCoalescer tests")
struct LiveActivityCoalescerTests {

    /// The stale deadline must outlive a normal crossing wait (≤ 2 min of no GPS fixes while
    /// standing still) and still catch a dead app inside the demo's attention span (≤ 10 min).
    @Test("staleAfter outlives a crossing wait and catches a dead app within ten minutes")
    func staleAfterOutlivesACrossingWait() {
        #expect(LiveActivityCoalescer.staleAfter >= 120)
        #expect(LiveActivityCoalescer.staleAfter <= 600)
    }

    @Test("First snapshot always emits")
    func firstSnapshotAlwaysEmits() {
        var coalescer = LiveActivityCoalescer()
        let snap = LiveActivitySnapshot(instruction: "Turn left", distanceM: 100, kind: "turnLeft")
        let emits = coalescer.shouldEmit(snapshot: snap, now: 10.0)
        #expect(emits == true)
        #expect(coalescer.lastEmitted == snap)
    }

    @Test("Hazard safety transition fires immediately, even sub-second before minInterval")
    func hazardTransitionBypassesMinInterval() {
        var coalescer = LiveActivityCoalescer(minIntervalSec: 1.0, minEmergencyIntervalSec: 0.2)
        let clearSnap = LiveActivitySnapshot(instruction: "Straight", distanceM: 100, kind: "straight", obstacleStatus: .clear)
        _ = coalescer.shouldEmit(snapshot: clearSnap, now: 10.0)

        // 0.25s later (well before 1.0s minInterval): head obstacle detected!
        let headSnap = LiveActivitySnapshot(instruction: "Straight", distanceM: 100, kind: "straight", obstacleStatus: .head, headClearanceM: 1.2)
        let emitted = coalescer.shouldEmit(snapshot: headSnap, now: 10.25)
        #expect(emitted == true)
        #expect(coalescer.lastEmitted?.obstacleStatus == .head)
    }

    @Test("Sensor flap oscillation faster than 0.2s is suppressed by emergency flap guard")
    func sensorFlapIsSuppressed() {
        var coalescer = LiveActivityCoalescer(minIntervalSec: 1.0, minEmergencyIntervalSec: 0.2)
        let clearSnap = LiveActivitySnapshot(instruction: "Straight", distanceM: 100, kind: "straight", obstacleStatus: .clear)
        _ = coalescer.shouldEmit(snapshot: clearSnap, now: 10.0)

        // Only 0.05s later (flap): should be suppressed
        let flapSnap = LiveActivitySnapshot(instruction: "Straight", distanceM: 100, kind: "straight", obstacleStatus: .warning, obstacleDistanceM: 1.0)
        let emitted = coalescer.shouldEmit(snapshot: flapSnap, now: 10.05)
        #expect(emitted == false)
    }

    @Test("Clearing hazard fires immediately to reassure spotter")
    func clearingHazardFiresImmediately() {
        var coalescer = LiveActivityCoalescer(minIntervalSec: 1.0, minEmergencyIntervalSec: 0.2)
        let warnSnap = LiveActivitySnapshot(instruction: "Straight", distanceM: 50, kind: "straight", obstacleStatus: .warning, obstacleDistanceM: 1.1)
        _ = coalescer.shouldEmit(snapshot: warnSnap, now: 10.0)

        // 0.25s later: obstacle is cleared!
        let clearSnap = LiveActivitySnapshot(instruction: "Straight", distanceM: 50, kind: "straight", obstacleStatus: .clear)
        let emitted = coalescer.shouldEmit(snapshot: clearSnap, now: 10.25)
        #expect(emitted == true)
        #expect(coalescer.lastEmitted?.obstacleStatus == .clear)
    }

    @Test("Sub-second non-emergency updates are rate-limited")
    func subSecondUpdatesSuppressed() {
        var coalescer = LiveActivityCoalescer(minIntervalSec: 0.8)
        let snap1 = LiveActivitySnapshot(instruction: "Straight", distanceM: 100, kind: "straight")
        _ = coalescer.shouldEmit(snapshot: snap1, now: 10.0)

        // Instruction changed 0.3s later (below 0.8s minInterval)
        let snap2 = LiveActivitySnapshot(instruction: "Turn right", distanceM: 95, kind: "turnRight")
        let emittedTooFast = coalescer.shouldEmit(snapshot: snap2, now: 10.3)
        #expect(emittedTooFast == false)

        // At 10.9s (0.9s elapsed > 0.8s): should emit
        let emittedAfterInterval = coalescer.shouldEmit(snapshot: snap2, now: 10.9)
        #expect(emittedAfterInterval == true)
    }

    @Test("Non-linear distance bands: 2m threshold near turns (<30m)")
    func distanceBandsNearTurn() {
        var coalescer = LiveActivityCoalescer(minIntervalSec: 0.5)
        let snap1 = LiveActivitySnapshot(instruction: "Turn left", distanceM: 20, kind: "turnLeft")
        _ = coalescer.shouldEmit(snapshot: snap1, now: 10.0)

        // 1m change at 20m -> should NOT emit
        let snap2 = LiveActivitySnapshot(instruction: "Turn left", distanceM: 19, kind: "turnLeft")
        let emitted1m = coalescer.shouldEmit(snapshot: snap2, now: 11.0)
        #expect(emitted1m == false)

        // 2m change (from 20m to 18m) -> SHOULD emit
        let snap3 = LiveActivitySnapshot(instruction: "Turn left", distanceM: 18, kind: "turnLeft")
        let emitted2m = coalescer.shouldEmit(snapshot: snap3, now: 12.0)
        #expect(emitted2m == true)
    }

    @Test("Non-linear distance bands: 10m threshold far away (>100m)")
    func distanceBandsAtRange() {
        var coalescer = LiveActivityCoalescer(minIntervalSec: 0.5)
        let snap1 = LiveActivitySnapshot(instruction: "Straight", distanceM: 200, kind: "straight")
        _ = coalescer.shouldEmit(snapshot: snap1, now: 10.0)

        // 7m change at 200m -> should NOT emit (threshold is 10m)
        let snap2 = LiveActivitySnapshot(instruction: "Straight", distanceM: 193, kind: "straight")
        let emitted7m = coalescer.shouldEmit(snapshot: snap2, now: 11.0)
        #expect(emitted7m == false)

        // 10m change -> SHOULD emit
        let snap3 = LiveActivitySnapshot(instruction: "Straight", distanceM: 190, kind: "straight")
        let emitted10m = coalescer.shouldEmit(snapshot: snap3, now: 12.0)
        #expect(emitted10m == true)
    }

    @Test("Status detail text jitter alone does not trigger ActivityKit emissions")
    func statusDetailJitterSuppressed() {
        var coalescer = LiveActivityCoalescer(minIntervalSec: 0.5)
        let snap1 = LiveActivitySnapshot(instruction: "Straight", distanceM: 150, kind: "straight", statusDetail: "±3m")
        _ = coalescer.shouldEmit(snapshot: snap1, now: 10.0)

        // Only statusDetail jittered to "±4m", distance unchanged, obstacle unchanged
        let snap2 = LiveActivitySnapshot(instruction: "Straight", distanceM: 150, kind: "straight", statusDetail: "±4m")
        let emitted = coalescer.shouldEmit(snapshot: snap2, now: 11.0)
        #expect(emitted == false)
    }

    @Test("Legacy JSON without new obstacle keys decodes gracefully")
    func legacyJsonDecodesGracefully() throws {
        // Simulates old serialized ContentState from a previous build
        let oldJson = """
        {
            "instruction": "Green Street. Turn right.",
            "distanceM": 45,
            "kind": "turnRight"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        // If Decodable fails when keys are missing, this throws
        let decoded = try decoder.decode(LiveActivitySnapshot.self, from: oldJson)
        #expect(decoded.instruction == "Green Street. Turn right.")
        #expect(decoded.distanceM == 45)
        #expect(decoded.kind == "turnRight")
        #expect(decoded.obstacleStatus == .clear)
        #expect(decoded.obstacleDistanceM == 0.0)
        #expect(decoded.headClearanceM == 0.0)
        #expect(decoded.statusDetail == "")
        // Step 64 fields: an old payload is walking with unknown sensing — never "live".
        #expect(decoded.phase == "walking")
        #expect(decoded.sensing == "none")
    }

    /// Step 64: a locked screen must reach the island at once ("Obstacles paused"), not wait for
    /// the next distance band, so a sensing change skips the 0.8 s floor.
    @Test("A sensing change bypasses the rate-limit floor")
    func sensingChangeBypassesFloor() {
        var coalescer = LiveActivityCoalescer(minIntervalSec: 1.0)
        let live = LiveActivitySnapshot(instruction: "Straight", distanceM: 100, kind: "straight",
                                        phase: "walking", sensing: "live")
        _ = coalescer.shouldEmit(snapshot: live, now: 10.0)
        var paused = live
        paused.sensing = "paused"
        do { let r = coalescer.shouldEmit(snapshot: paused, now: 10.1); #expect(r == true) }
        // And no second emit for the same sensing inside the floor.
        do { let r = coalescer.shouldEmit(snapshot: paused, now: 10.2); #expect(r == false) }
    }

    /// Step 64: listening / thinking / indoor steps are what the walker is doing now.
    @Test("A phase change bypasses the rate-limit floor")
    func phaseChangeBypassesFloor() {
        var coalescer = LiveActivityCoalescer(minIntervalSec: 1.0)
        let walking = LiveActivitySnapshot(instruction: "Straight", distanceM: 100, kind: "straight",
                                           phase: "walking", sensing: "live")
        _ = coalescer.shouldEmit(snapshot: walking, now: 10.0)
        var listening = walking
        listening.phase = "listening"
        do { let r = coalescer.shouldEmit(snapshot: listening, now: 10.05); #expect(r == true) }
    }
}
