//
//  StatusSummaryTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins StatusSummary.swift — the spoken answer to "is this thing working?".
//
//  Why these are the tests: the walker cannot see a single one of the cards this answer replaces,
//  so the failure mode is not a crash, it is a *reassuring* answer. Every test below is therefore
//  about a state where something is wrong and the wording has to make that unmissable:
//    · a depth session that is up but delivering no frames — the state that is indistinguishable
//      from a clear path;
//    · GPS accuracy over the same 20 m at which the waypoint fences stop firing;
//    · haptics silenced, where the answer must also say where the obstacle cues went;
//    · an unknown battery (the simulator), which must be omitted rather than spoken as −1.
//  Plus the shape invariants the caller depends on: fixed clause order, every clause present, one
//  sentence per element (`AppModel.speakStatus` speaks them separately so a warning can interrupt
//  one clause instead of the whole report).
//
//  Source pinned: `ios/Logic/Sources/CaneKitLogic/StatusSummary.swift` (`StatusFacts`,
//  `StatusSummary.lines` / `sentence` and the per-clause `obstacleLine`, `gpsLine`, `audioLine`,
//  `hapticsLine`, `routeLine`, `batteryLine`; `weakGPSAccuracyM` 20). Callers: `AppModel.speakStatus`
//  (HandsFreeIntents.swift; `StatusIntent`, one `.scene` line per clause, logs `status_spoken`) and
//  `ConversationCoordinator` (answers a status question with `sentence`). `hapticsLine` is also
//  spoken on its own by `AppModel.setHapticsSilenced` and `ConversationCoordinator` ("silence the
//  cane"), so one fact has one sentence.
//

import Testing
@testable import CaneKitLogic

/// Everything healthy, mid-route: the baseline the other tests mutate one field at a time.
/// Every parameter is a `StatusFacts` field; −1 for `gpsAccuracyM` / `batteryPercent` means
/// unknown (CoreLocation / the simulator), `metresToNext: nil` means no distance yet.
private func healthy(
    lidarSupported: Bool = true, obstacleDetectionRunning: Bool = true, depthFps: Double = 9,
    gpsFix: Bool = true, gpsAccuracyM: Double = 8, locationDenied: Bool = false,
    headphonesConnected: Bool = true, headphoneName: String = "AirPods Pro", headTracking: Bool = true,
    hapticsHealthy: Bool = true, hapticsSilenced: Bool = false, watchReachable: Bool = true,
    routeRunning: Bool = true, routeInstruction: String = "turn right on Springfield",
    metresToNext: Int? = 40, batteryPercent: Int = 72
) -> StatusFacts {
    StatusFacts(lidarSupported: lidarSupported, obstacleDetectionRunning: obstacleDetectionRunning,
                depthFps: depthFps, gpsFix: gpsFix, gpsAccuracyM: gpsAccuracyM,
                locationDenied: locationDenied, headphonesConnected: headphonesConnected,
                headphoneName: headphoneName, headTracking: headTracking,
                hapticsHealthy: hapticsHealthy, hapticsSilenced: hapticsSilenced,
                watchReachable: watchReachable, routeRunning: routeRunning,
                routeInstruction: routeInstruction, metresToNext: metresToNext,
                batteryPercent: batteryPercent)
}

/// The order is the contract: a walker learns the shape of the answer and stops listening once the
/// clause they asked about has gone by. Re-ordering by severity would break that.
@Test func statusClausesAlwaysComeInTheSameOrder() {
    let lines = StatusSummary.lines(healthy())
    #expect(lines.count == 6)
    #expect(lines[0].hasPrefix("Obstacle detection"))
    #expect(lines[1].hasPrefix("GPS"))
    #expect(lines[2].contains("AirPods Pro"))
    #expect(lines[3].hasPrefix("Cane haptics"))
    #expect(lines[4].hasPrefix("Route running"))
    #expect(lines[5].hasPrefix("Battery"))
}

/// One sentence per element, because the caller speaks them as separate lines.
@Test func everyStatusClauseIsOneFinishedSentence() {
    for line in StatusSummary.lines(healthy()) {
        #expect(line.hasSuffix("."))
        #expect(!line.isEmpty)
        #expect(line.first?.isUppercase == true)
    }
}

/// The good case still says every channel out loud. A clause left out because it was fine would be
/// indistinguishable from a clause the walker missed.
@Test func healthyStatusStillNamesEveryChannel() {
    let said = StatusSummary.sentence(healthy())
    #expect(said.contains("Obstacle detection on, 9 frames per second."))
    #expect(said.contains("GPS good, within 8 meters."))
    #expect(said.contains("AirPods Pro connected, head tracking on."))
    #expect(said.contains("Cane haptics on."))
    #expect(said.contains("Route running: Turn right on Springfield. 40 meters to the next point."))
    #expect(said.contains("Battery 72 percent."))
}

/// The worst state in the app: ARKit is running and no depth frames are arriving. From the outside
/// that is silence, which is exactly what a clear path sounds like. It must never read as "on".
@Test func aRunningDepthSessionWithNoFramesIsNotReportedAsOn() {
    let line = StatusSummary.obstacleLine(healthy(depthFps: 0))
    #expect(line == "Obstacle detection is running but no depth frames are arriving.")
    #expect(!line.contains("on,"))
}

/// Off, and no sensor at all, are different facts: one the walker can fix, one they cannot.
@Test func obstacleDetectionOffAndNoSensorReadDifferently() {
    #expect(StatusSummary.obstacleLine(healthy(obstacleDetectionRunning: false))
            == "Obstacle detection is off.")
    #expect(StatusSummary.obstacleLine(healthy(lidarSupported: false))
            == "This phone has no depth sensor, so there are no obstacle warnings.")
}

/// ⚠ The status answer calls GPS weak at exactly the accuracy where `GeofenceTracker` stops
/// accepting fixes and the route engine speaks "GPS weak. Waypoint cues paused." Two different
/// thresholds would have the app promise the fences work while they are paused.
@Test func gpsWeakThresholdMatchesTheGeofenceGate() {
    #expect(StatusSummary.weakGPSAccuracyM == GeofenceTracker(waypoints: []).maxAccuracy)
    #expect(StatusSummary.gpsLine(healthy(gpsAccuracyM: 20)) == "GPS good, within 20 meters.")
    #expect(StatusSummary.gpsLine(healthy(gpsAccuracyM: 34))
            == "GPS weak, 34 meters. Waypoint cues are paused.")
}

/// No fix, unknown accuracy and a denied permission are three different problems with three
/// different fixes; a single "GPS not working" would send the walker to the wrong one.
@Test func gpsClauseSeparatesDeniedFromNoFix() {
    #expect(StatusSummary.gpsLine(healthy(locationDenied: true))
            == "Location permission is denied, so no route can run.")
    #expect(StatusSummary.gpsLine(healthy(gpsFix: false)) == "No GPS fix yet.")
    #expect(StatusSummary.gpsLine(healthy(gpsAccuracyM: -1)) == "GPS fix with unknown accuracy.")
}

/// Losing the AirPods moves speech to the speaker under the walker's arm and pauses the beacon —
/// the least visible failure on a walk. The clause has to say both consequences, not just "no
/// headphones".
@Test func losingHeadphonesSaysWhatStoppedWorking() {
    #expect(StatusSummary.audioLine(healthy(headphonesConnected: false))
            == "No headphones. Speech is on the phone speaker and the beacon is paused.")
    #expect(StatusSummary.audioLine(healthy(headTracking: false))
            == "AirPods Pro connected, no head tracking.")
    #expect(StatusSummary.audioLine(healthy(headphoneName: "   "))
            == "Headphones connected, head tracking on.")
}

/// Silenced haptics must always be followed by where the obstacle cues went. Saying only
/// "silenced" leaves the walker unsure whether the cues still exist at all — the same promise
/// `announceChannels` makes at route start.
@Test func silencedHapticsAlwaysSayWhereTheCuesWent() {
    #expect(StatusSummary.hapticsLine(healthy(hapticsSilenced: true, watchReachable: true))
            == "Cane haptics silenced. Obstacle cues go to the watch.")
    #expect(StatusSummary.hapticsLine(healthy(hapticsSilenced: true, watchReachable: false))
            == "Cane haptics silenced. Obstacle cues will be spoken.")
    #expect(StatusSummary.hapticsLine(healthy(hapticsHealthy: false, watchReachable: false))
            == "Cane haptics unavailable. Obstacle cues will be spoken.")
}

/// Idle is a legitimate answer and has to be spoken, not omitted.
@Test func noRouteIsStillAnAnswer() {
    #expect(StatusSummary.routeLine(healthy(routeRunning: false)) == "No route running.")
    #expect(StatusSummary.routeLine(healthy(metresToNext: nil))
            == "Route running: Turn right on Springfield.")
}

/// A walk that ends because the phone died is a safety failure, so "low" is said in words.
/// An unknown battery (the simulator reports −1) is omitted rather than spoken as a wrong number.
@Test func lowBatteryIsWordedAndUnknownBatteryIsOmitted() {
    #expect(StatusSummary.batteryLine(healthy(batteryPercent: 14)) == "Battery low, 14 percent.")
    #expect(StatusSummary.batteryLine(healthy(batteryPercent: 21)) == "Battery 21 percent.")
    #expect(StatusSummary.batteryLine(healthy(batteryPercent: -1)) == nil)
    #expect(StatusSummary.lines(healthy(batteryPercent: -1)).count == 5)
}

/// No clause may ever promise the path is clear — the rule `CloudSceneGate` enforces on the model
/// applies to the app's own words too. This sweeps every failure state the answer can reach.
@Test func noStatusClauseEverPromisesAClearPath() {
    let states: [StatusFacts] = [
        healthy(), healthy(lidarSupported: false), healthy(obstacleDetectionRunning: false),
        healthy(depthFps: 0), healthy(gpsFix: false), healthy(gpsAccuracyM: -1),
        healthy(gpsAccuracyM: 90), healthy(locationDenied: true), healthy(headphonesConnected: false),
        healthy(headTracking: false), healthy(hapticsHealthy: false), healthy(hapticsSilenced: true),
        healthy(watchReachable: false), healthy(routeRunning: false), healthy(metresToNext: nil),
        healthy(batteryPercent: -1), healthy(batteryPercent: 5),
    ]
    for facts in states {
        let said = StatusSummary.sentence(facts)
        for word in ["clear", "safe", "unobstructed", "nothing ahead", "all good"] {
            #expect(!said.lowercased().contains(word), "status said \"\(word)\": \(said)")
        }
    }
}
