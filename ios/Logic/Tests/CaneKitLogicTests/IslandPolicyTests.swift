//
//  IslandPolicyTests.swift
//  CaneKitLogicTests
//
//  Pins the Dynamic Island's decisions (Step 64): which phase the Live Activity shows, whether its
//  obstacle glance may claim anything ("Path clear" only while depth is live), how relevant the
//  activity is to the system, and when an obstacle escalation may light the lock screen.
//
//  Why: the Step 64 audit found the island saying "Path clear" with the screen locked and depth
//  paused (`AppModel.scenePhaseChanged(.background)` → `depth.pause()`), because nothing in the
//  payload said whether the sensors were running. These tests are the fence around that bug.
//
//  Owner: module `navigation-trip`. Code under test: ios/Logic/Sources/CaneKitLogic/IslandPolicy.swift.
//

import Foundation
import Testing
@testable import CaneKitLogic

@Suite("Island phase and sensing policy")
struct IslandPhasePolicyTests {

    /// A walking, foreground, trusted-depth LiDAR phone: the baseline every test varies.
    private func walking() -> IslandInputs {
        IslandInputs(navigating: true, routeStartWaiting: false, voiceListening: false,
                     voiceThinking: false, indoorStepIndex: nil, indoorStepCount: 0,
                     appActive: true, depthTrusted: true, hasLiDAR: true)
    }

    @Test("Walking in the foreground with trusted depth is walking and live")
    func walkingForegroundIsLive() {
        let s = IslandPhasePolicy.decide(walking())
        #expect(s.phase == .walking)
        #expect(s.sensing == .live)
    }

    @Test("Background with a route running is paused, never live — the Step 64 safety bug")
    func backgroundWithRouteIsPaused() {
        var i = walking()
        i.appActive = false
        // Even if the last depth report was trusted, a backgrounded app has paused ARKit.
        i.depthTrusted = true
        #expect(IslandPhasePolicy.decide(i).sensing == .paused)
        #expect(IslandPhasePolicy.showsClear(sensing: .paused, isStale: false) == false)
    }

    @Test("Background while warming up is paused too")
    func backgroundWhileWarmingIsPaused() {
        var i = walking()
        i.navigating = false
        i.routeStartWaiting = true
        i.appActive = false
        #expect(IslandPhasePolicy.decide(i) == IslandState(phase: .warming, sensing: .paused))
    }

    /// Step 62/63: an indoor step script keeps going with the screen locked (GPS stays on for the
    /// outdoor handover) but depth does not — the island must say paused, not unknown or live.
    @Test("Background during an indoor script (no outdoor route) is paused")
    func backgroundIndoorIsPaused() {
        var i = walking()
        i.navigating = false
        i.indoorStepIndex = 1; i.indoorStepCount = 4
        i.appActive = false
        #expect(IslandPhasePolicy.decide(i) == IslandState(phase: .indoor, sensing: .paused))
    }

    @Test("No LiDAR is none in every scene phase")
    func noLidarIsNone() {
        var i = walking()
        i.hasLiDAR = false
        #expect(IslandPhasePolicy.decide(i).sensing == .none)
        i.appActive = false
        #expect(IslandPhasePolicy.decide(i).sensing == .none)
    }

    @Test("Untrusted depth in the foreground is none")
    func untrustedDepthIsNone() {
        var i = walking()
        i.depthTrusted = false
        #expect(IslandPhasePolicy.decide(i).sensing == .none)
    }

    @Test("Warming up is none even if a report happens to be trusted: the gate has not passed")
    func warmingIsNone() {
        var i = walking()
        i.navigating = false
        i.routeStartWaiting = true
        #expect(IslandPhasePolicy.decide(i) == IslandState(phase: .warming, sensing: .none))
    }

    @Test("Priority: listening > thinking > warming > indoor > walking")
    func phasePriority() {
        var i = walking()
        i.indoorStepIndex = 2; i.indoorStepCount = 5
        #expect(IslandPhasePolicy.decide(i).phase == .indoor)
        i.routeStartWaiting = true
        #expect(IslandPhasePolicy.decide(i).phase == .warming)
        i.voiceThinking = true
        #expect(IslandPhasePolicy.decide(i).phase == .thinking)
        i.voiceListening = true
        #expect(IslandPhasePolicy.decide(i).phase == .listening)
    }

    @Test("Indoor needs a valid step: an index outside the count is walking")
    func indoorNeedsAValidStep() {
        var i = walking()
        i.indoorStepIndex = 5; i.indoorStepCount = 5
        #expect(IslandPhasePolicy.decide(i).phase == .walking)
        i.indoorStepIndex = 0; i.indoorStepCount = 0
        #expect(IslandPhasePolicy.decide(i).phase == .walking)
        i.indoorStepIndex = 4; i.indoorStepCount = 5
        #expect(IslandPhasePolicy.decide(i).phase == .indoor)
    }

    @Test("Voice phases keep the sensing fact: listening in the foreground with live depth is live")
    func voiceKeepsSensing() {
        var i = walking()
        i.voiceListening = true
        #expect(IslandPhasePolicy.decide(i) == IslandState(phase: .listening, sensing: .live))
    }

    @Test("Path clear is shown only when sensing is live and the activity is not stale")
    func showsClearOnlyWhenLive() {
        #expect(IslandPhasePolicy.showsClear(sensing: .live, isStale: false))
        #expect(!IslandPhasePolicy.showsClear(sensing: .live, isStale: true))
        #expect(!IslandPhasePolicy.showsClear(sensing: .none, isStale: false))
        #expect(!IslandPhasePolicy.showsClear(sensing: .paused, isStale: false))
    }

    @Test("Relevance: alert 100 > walking 75 > voice 50 > arrived / stopped 10")
    func relevanceOrder() {
        #expect(IslandPhasePolicy.relevance(phase: .walking, alert: .head) == 100)
        #expect(IslandPhasePolicy.relevance(phase: .walking, alert: .near) == 100)
        #expect(IslandPhasePolicy.relevance(phase: .walking, alert: .none) == 75)
        #expect(IslandPhasePolicy.relevance(phase: .indoor, alert: .none) == 75)
        #expect(IslandPhasePolicy.relevance(phase: .warming, alert: .none) == 75)
        #expect(IslandPhasePolicy.relevance(phase: .listening, alert: .none) == 50)
        #expect(IslandPhasePolicy.relevance(phase: .thinking, alert: .none) == 50)
        #expect(IslandPhasePolicy.relevance(phase: .arrived, alert: .none) == 10)
        #expect(IslandPhasePolicy.relevance(phase: .stopped, alert: .head) == 10)
    }

    @Test("Unknown raw phase / sensing strings fall back to walking / none")
    func unknownRawFallbacks() {
        #expect(IslandPhase(lenient: "flying") == .walking)
        #expect(IslandSensing(lenient: "maybe") == .none)
        #expect(IslandPhase(lenient: "indoor") == .indoor)
    }
}

@Suite("Island alert level")
struct IslandAlertLevelTests {

    @Test("Obstacle glance maps to a level; a torso obstacle within 0.6 m is stop")
    func levelFromGlance() {
        #expect(IslandAlertLevel.from(obstacle: .clear, distanceM: 0) == .none)
        #expect(IslandAlertLevel.from(obstacle: .warning, distanceM: 1.2) == .near)
        #expect(IslandAlertLevel.from(obstacle: .warning, distanceM: 0.6) == .stop)
        #expect(IslandAlertLevel.from(obstacle: .warning, distanceM: 0.3) == .stop)
        // 0 means "unknown distance" in the payload, not "touching": near, not stop.
        #expect(IslandAlertLevel.from(obstacle: .warning, distanceM: 0) == .near)
        #expect(IslandAlertLevel.from(obstacle: .head, distanceM: 1.5) == .head)
        #expect(IslandAlertLevel.from(obstacle: .dropOff, distanceM: 1.0) == .curb)
        #expect(IslandAlertLevel.stopWithinM == 0.6)
    }

    @Test("Ranks: none 0, near and curb 1, stop and head 2")
    func ranks() {
        #expect(IslandAlertLevel.none.rank == 0)
        #expect(IslandAlertLevel.near.rank == 1)
        #expect(IslandAlertLevel.curb.rank == 1)
        #expect(IslandAlertLevel.stop.rank == 2)
        #expect(IslandAlertLevel.head.rank == 2)
    }
}

@Suite("Island alert throttle")
struct IslandAlertThrottleTests {

    @Test("clear → near alerts in the background")
    func clearToNearAlerts() {
        var t = IslandAlertThrottle()
        do { let r = t.shouldAlert(level: .near, appActive: false, now: 10); #expect(r) }
    }

    @Test("near → head escalation alerts even a second after the near alert")
    func escalationInsideWindowAlerts() {
        var t = IslandAlertThrottle()
        do { let r = t.shouldAlert(level: .near, appActive: false, now: 10); #expect(r) }
        do { let r = t.shouldAlert(level: .head, appActive: false, now: 11); #expect(r) }
    }

    @Test("De-escalation never alerts, and the same level does not re-alert")
    func deEscalationSilent() {
        var t = IslandAlertThrottle()
        do { let r = t.shouldAlert(level: .head, appActive: false, now: 10); #expect(r) }
        do { let r = t.shouldAlert(level: .near, appActive: false, now: 50); #expect(!r) }
        do { let r = t.shouldAlert(level: .none, appActive: false, now: 51); #expect(!r) }
        do { let r = t.shouldAlert(level: .none, appActive: false, now: 52); #expect(!r) }
    }

    @Test("Flapping clear ↔ near alerts at most once per 30 s")
    func flappingIsThrottled() {
        var t = IslandAlertThrottle()
        do { let r = t.shouldAlert(level: .near, appActive: false, now: 0); #expect(r) }
        do { let r = t.shouldAlert(level: .none, appActive: false, now: 1); #expect(!r) }
        do { let r = t.shouldAlert(level: .near, appActive: false, now: 2); #expect(!r) }
        do { let r = t.shouldAlert(level: .none, appActive: false, now: 3); #expect(!r) }
        do { let r = t.shouldAlert(level: .near, appActive: false, now: 29.9); #expect(!r) }
        do { let r = t.shouldAlert(level: .none, appActive: false, now: 30); #expect(!r) }
        do { let r = t.shouldAlert(level: .near, appActive: false, now: 30.5); #expect(r) }
        #expect(IslandAlertThrottle.perLevelInterval == 30)
    }

    @Test("Never in the foreground, but the level is still tracked")
    func foregroundNeverAlerts() {
        var t = IslandAlertThrottle()
        do { let r = t.shouldAlert(level: .near, appActive: true, now: 0); #expect(!r) }
        // Locked while already near: staying near is not an escalation.
        do { let r = t.shouldAlert(level: .near, appActive: false, now: 5); #expect(!r) }
        do { let r = t.shouldAlert(level: .stop, appActive: false, now: 6); #expect(r) }
    }

    @Test("A throttled escalation is not remembered: the same escalation alerts once the window has passed")
    func throttledEscalationAlertsAfterTheWindow() {
        var t = IslandAlertThrottle()
        do { let r = t.shouldAlert(level: .stop, appActive: false, now: 0); #expect(r) }
        do { let r = t.shouldAlert(level: .none, appActive: false, now: 5); #expect(!r) }
        do { let r = t.shouldAlert(level: .stop, appActive: false, now: 10); #expect(!r) }
        #expect(t.lastLevel == .none)
        do { let r = t.shouldAlert(level: .stop, appActive: false, now: 35); #expect(r) }
        #expect(t.lastLevel == .stop)
    }

    @Test("De-escalation still updates the level")
    func deEscalationUpdatesTheLevel() {
        var t = IslandAlertThrottle()
        do { let r = t.shouldAlert(level: .head, appActive: false, now: 0); #expect(r) }
        do { let r = t.shouldAlert(level: .near, appActive: false, now: 1); #expect(!r) }
        #expect(t.lastLevel == .near)
    }

    @Test("reset forgets the level and the windows (new route)")
    func resetPerRoute() {
        var t = IslandAlertThrottle()
        do { let r = t.shouldAlert(level: .head, appActive: false, now: 0); #expect(r) }
        t.reset()
        do { let r = t.shouldAlert(level: .head, appActive: false, now: 1); #expect(r) }
    }
}
