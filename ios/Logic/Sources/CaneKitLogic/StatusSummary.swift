//
//  StatusSummary.swift
//  CaneKitLogic
//
//  The spoken version of the whole screen: "is this thing working?" in one answer.
//
//  Why this exists: every card in the app reports its own health visually — the depth pill and its
//  fps, the GPS pill, the AirPods row, the haptics row, the watch row, the Guide card's route
//  state. A walker with the phone clamped to a cane can see none of it, and there was no spoken
//  equivalent of any of it. Before this, the only way to learn that obstacle detection had stopped,
//  or that the AirPods had dropped to the phone speaker, was to hear nothing happen — and "nothing
//  happened" is exactly what a working system sounds like too. That ambiguity is the bug this
//  file closes: silence must never be the only evidence that a safety channel is alive.
//
//  Why it is pure, and here: every clause has a threshold in it (20 m of GPS accuracy, 1 depth
//  frame per second, 20 % battery), and AGENTS.md hard rule 3 puts any rule with a number in it in
//  CaneKitLogic with a test. The app only collects the facts; the wording and the thresholds are
//  decided here and pinned by `StatusSummaryTests`.
//
//  Key invariants:
//    · **Fixed order, always.** Obstacle detection, GPS, audio, haptics, route, battery — in that
//      order, every time, whether or not anything is wrong. A blind user learns the shape of the
//      answer and can stop listening once they have heard the clause they asked about; re-ordering
//      by severity would make the same question answer differently each time.
//    · **Every clause is always spoken**, including the good news ("Obstacle detection on"). An
//      omitted clause would be indistinguishable from a clause the walker missed.
//    · **One clause per element of `lines`**, not one long sentence, because the caller speaks each
//      one separately: an obstacle warning then interrupts a single clause instead of the whole
//      report, and the remaining clauses stay queued behind it (`SpeechQueue.say`).
//    · **Numbers come from sensors only.** Every number here is measured (fps, metres of GPS
//      accuracy, metres to the next waypoint, battery percent). Nothing is estimated, and no
//      clause promises the path is clear — the same rule `CloudSceneGate` enforces on the model.
//
//  Owner: `AppModel.speakStatus()` (app, HandsFreeIntents.swift) fills `StatusFacts` from the live
//  engines, speaks each of `lines(_:)` at `.scene` (the lowest priority, TTL 20 s) so a status
//  answer can never delay a warning, and logs `status_spoken` with `sentence(_:)`.
//  Callers: `StatusIntent` (Siri "How is OpenCane doing" / Shortcuts / Action button) →
//  `speakStatus()`; `AppModel.setHapticsSilenced` (`hapticsLine(healthy:silenced:watchReachable:)`
//  as the voice confirmation); `ConversationCoordinator` (the conversational assistant answers a
//  status question with one clause — `gpsLine`, `audioLine`, `routeLine`, `batteryLine`,
//  `hapticsLine` — or `sentence`, from its own `currentStatusFacts()`).
//  Isolation: stateless and nonisolated; `StatusFacts` is a plain `Sendable` value.
//  Tests: StatusSummaryTests.swift (12).
//

import Foundation

/// Everything the spoken status answer is allowed to know, gathered by the app from the live
/// engines. Plain data on purpose: no engine types reach this package.
public struct StatusFacts: Sendable, Equatable {

    /// `DepthEngine.supportsDepth` — false on a phone with no LiDAR (and in the simulator), where
    /// there are no obstacle warnings at all and saying "detection off" would understate it.
    public var lidarSupported: Bool
    /// `DepthEngine.isRunning` — the ARKit session is up.
    public var obstacleDetectionRunning: Bool
    /// `DepthEngine.fps` — depth frames per second actually arriving. A running session with no
    /// frames is the failure that looks exactly like a clear path.
    public var depthFps: Double

    /// True once CoreLocation has ever delivered a fix.
    public var gpsFix: Bool
    /// Horizontal accuracy of the last fix, metres; negative when unknown.
    public var gpsAccuracyM: Double
    /// `LocationService.denied` — permission refused, so no route can run at all.
    public var locationDenied: Bool

    /// `AudioRouteMonitor.headphonesConnected`.
    public var headphonesConnected: Bool
    /// The route name to say ("AirPods Pro"); ignored when nothing is connected.
    public var headphoneName: String
    /// A head-yaw source is live (AirPods motion or the front-camera face tracker), which is what
    /// makes the audio beacon point where the walker is looking. `speakStatus` passes
    /// `head.isConnected || faceHead.isTracking`.
    public var headTracking: Bool

    /// `HapticPlayer.isHealthy` — the engine started and can buzz.
    public var hapticsHealthy: Bool
    /// `AppModel.hapticsSilenced` — the walker turned the cane buzz off.
    public var hapticsSilenced: Bool
    /// `PhoneWatchLink.isReachable` — where obstacle cues go when the cane cannot buzz.
    public var watchReachable: Bool

    /// `NavigationEngine.isNavigating`.
    public var routeRunning: Bool
    /// `NavigationEngine.instruction`, the line the walker is currently following; ignored when
    /// no route is running.
    public var routeInstruction: String
    /// `NavigationEngine.distanceToNext`, metres; nil when there is no estimate yet.
    public var metresToNext: Int?

    /// `AppModel.batteryPercent`, 0–100, or negative when unknown (simulator) — then omitted.
    /// (`ConversationCoordinator` says "Battery level unknown." itself in that case.)
    public var batteryPercent: Int

    /// Memberwise, with every field required: a new fact must be decided at every call site rather
    /// than silently defaulting to "fine".
    public init(lidarSupported: Bool, obstacleDetectionRunning: Bool, depthFps: Double,
                gpsFix: Bool, gpsAccuracyM: Double, locationDenied: Bool,
                headphonesConnected: Bool, headphoneName: String, headTracking: Bool,
                hapticsHealthy: Bool, hapticsSilenced: Bool, watchReachable: Bool,
                routeRunning: Bool, routeInstruction: String, metresToNext: Int?,
                batteryPercent: Int) {
        self.lidarSupported = lidarSupported
        self.obstacleDetectionRunning = obstacleDetectionRunning
        self.depthFps = depthFps
        self.gpsFix = gpsFix
        self.gpsAccuracyM = gpsAccuracyM
        self.locationDenied = locationDenied
        self.headphonesConnected = headphonesConnected
        self.headphoneName = headphoneName
        self.headTracking = headTracking
        self.hapticsHealthy = hapticsHealthy
        self.hapticsSilenced = hapticsSilenced
        self.watchReachable = watchReachable
        self.routeRunning = routeRunning
        self.routeInstruction = routeInstruction
        self.metresToNext = metresToNext
        self.batteryPercent = batteryPercent
    }
}

/// Turns `StatusFacts` into the clauses the app speaks. Pure: no clock, no I/O.
public enum StatusSummary {

    // MARK: Thresholds (AGENTS.md hard rule 3: numbers live here, with tests)

    /// Above this horizontal accuracy the waypoint fences stop firing and the app says "GPS weak"
    /// while walking, so the status answer must call the same accuracy weak.
    /// ⚠ Pinned to `GeofenceTracker.maxAccuracy` by `gpsWeakThresholdMatchesTheGeofenceGate`; if
    /// the gate moves, this moves with it or the status answer starts lying about the fences.
    public static let weakGPSAccuracyM: Double = 20

    /// Fewer depth frames per second than this and the session is up but blind. Any real ARKit
    /// session delivers 10–60; below one frame per second nothing can be warned about in time, so
    /// it is reported as a fault rather than as "on".
    public static let minDepthFps: Double = 1

    /// At or below this battery percent the walk is at risk of ending early, so the clause says
    /// "low" instead of only the number. 20 % is iOS's own low-power prompt.
    public static let lowBatteryPercent: Int = 20

    // MARK: The answer

    /// The clauses to speak, in the fixed order described in the file header. Each is a complete
    /// sentence ending in a full stop, so the caller can speak them as separate lines and let a
    /// warning interrupt one clause rather than the whole report.
    /// - Parameter f: what the app measured, right now.
    /// - Returns: five or six clauses (battery is omitted when unknown), each ending in a full stop;
    ///   one clause may hold two short sentences ("GPS weak, 25 meters. Waypoint cues are paused.").
    ///   Never empty. Pinned by `statusClausesAlwaysComeInTheSameOrder`,
    ///   `healthyStatusStillNamesEveryChannel`, `noStatusClauseEverPromisesAClearPath`.
    public static func lines(_ f: StatusFacts) -> [String] {
        var out = [obstacleLine(f), gpsLine(f), audioLine(f), hapticsLine(f), routeLine(f)]
        if let battery = batteryLine(f) { out.append(battery) }
        return out
    }

    /// The same answer as one string, for the trip log and for tests that care about the whole
    /// report rather than a clause. Not what the app speaks (see `lines`).
    /// - Parameter f: what the app measured, right now.
    /// - Returns: the clauses joined with single spaces.
    public static func sentence(_ f: StatusFacts) -> String {
        lines(f).joined(separator: " ")
    }

    // MARK: Clauses

    /// Obstacle detection: the channel that stops the walker hitting things, so it is spoken first.
    /// A running session with no frames arriving gets its own wording — that state looks exactly
    /// like a clear path from the outside and must never be reported as "on".
    /// Pinned by `aRunningDepthSessionWithNoFramesIsNotReportedAsOn`,
    /// `obstacleDetectionOffAndNoSensorReadDifferently`.
    public static func obstacleLine(_ f: StatusFacts) -> String {
        guard f.lidarSupported else { return "This phone has no depth sensor, so there are no obstacle warnings." }
        guard f.obstacleDetectionRunning else { return "Obstacle detection is off." }
        guard f.depthFps >= minDepthFps else { return "Obstacle detection is running but no depth frames are arriving." }
        return "Obstacle detection on, \(Int(f.depthFps.rounded())) frames per second."
    }

    /// GPS: whether a route can be followed at all, and how well. The accuracy number is
    /// CoreLocation's own; `weakGPSAccuracyM` is the same threshold at which the waypoint fences
    /// stop firing, so "GPS good" and "the fences are working" mean the same thing.
    /// Order: denied beats everything, then no fix, then unknown (negative) accuracy, then
    /// good (≤ 20 m, inclusive) / weak. Pinned by `gpsClauseSeparatesDeniedFromNoFix`,
    /// `gpsWeakThresholdMatchesTheGeofenceGate`.
    public static func gpsLine(_ f: StatusFacts) -> String {
        if f.locationDenied { return "Location permission is denied, so no route can run." }
        guard f.gpsFix else { return "No GPS fix yet." }
        guard f.gpsAccuracyM >= 0 else { return "GPS fix with unknown accuracy." }
        let metres = Int(f.gpsAccuracyM.rounded())
        return f.gpsAccuracyM <= weakGPSAccuracyM
            ? "GPS good, within \(metres) meters."
            : "GPS weak, \(metres) meters. Waypoint cues are paused."
    }

    /// Audio: where speech is coming out, and whether the beacon can use head direction.
    /// Losing the AirPods is the most common real failure on a walk and the least visible one —
    /// speech simply moves to the phone speaker under the walker's arm.
    /// A blank route name reads "Headphones". Pinned by `losingHeadphonesSaysWhatStoppedWorking`.
    public static func audioLine(_ f: StatusFacts) -> String {
        guard f.headphonesConnected else {
            return "No headphones. Speech is on the phone speaker and the beacon is paused."
        }
        let name = f.headphoneName.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = name.isEmpty ? "Headphones" : name
        return f.headTracking
            ? "\(who) connected, head tracking on."
            : "\(who) connected, no head tracking."
    }

    /// Haptics: whether the cane can buzz, and — when it cannot — where the obstacle cues went
    /// instead. Saying only "silenced" would leave the walker unsure whether cues still exist;
    /// `AppModel.announceChannels` makes the same promise at route start (in its own wording — it
    /// does not call this, and it only speaks for an unhealthy engine) and this keeps it.
    public static func hapticsLine(_ f: StatusFacts) -> String {
        hapticsLine(healthy: f.hapticsHealthy, silenced: f.hapticsSilenced,
                    watchReachable: f.watchReachable)
    }

    /// The haptics clause on its own, because it is also the confirmation spoken when the walker
    /// silences or un-silences the cane by voice (`AppModel.setHapticsSilenced`, at `.nav`, TTL
    /// 10 s) and the assistant's haptics answer (`ConversationCoordinator`). One function so the
    /// status report and the confirmation cannot drift into saying different things about the
    /// same switch. An unhealthy engine wins over the switch (the cane cannot buzz either way).
    /// Pinned by `silencedHapticsAlwaysSayWhereTheCuesWent`.
    /// - Parameters:
    ///   - healthy: `HapticPlayer.isHealthy` — the engine can actually buzz.
    ///   - silenced: the walker's switch.
    ///   - watchReachable: whether the watch is there to take the cues instead.
    /// - Returns: the sentence, always naming where obstacle cues go when the cane cannot buzz.
    public static func hapticsLine(healthy: Bool, silenced: Bool, watchReachable: Bool) -> String {
        let elsewhere = watchReachable ? "Obstacle cues go to the watch."
                                       : "Obstacle cues will be spoken."
        guard healthy else { return "Cane haptics unavailable. " + elsewhere }
        guard silenced else { return "Cane haptics on." }
        return "Cane haptics silenced. " + elsewhere
    }

    /// Route: whether guidance is running, and if so the line the walker is following. The
    /// instruction is repeated here on purpose — "is a route running" and "which one" are the same
    /// question when you cannot see the card.
    /// Pinned by `noRouteIsStillAnAnswer`, `everyStatusClauseIsOneFinishedSentence`.
    public static func routeLine(_ f: StatusFacts) -> String {
        guard f.routeRunning else { return "No route running." }
        let instruction = f.routeInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        var line = instruction.isEmpty ? "Route running." : "Route running: \(sentenceCased(instruction))"
        if !line.hasSuffix(".") { line += "." }
        // The distance is CoreLocation's, measured to the next waypoint; nil means no estimate yet
        // and is left out rather than spoken as a zero.
        if let metres = f.metresToNext { line += " \(metres) meters to the next point." }
        return line
    }

    /// Battery: omitted entirely when unknown (the simulator reports −1) rather than spoken as a
    /// wrong number. A walk that ends because the phone died is a safety failure, so the low case
    /// says so in words and not only in digits. Pinned by `lowBatteryIsWordedAndUnknownBatteryIsOmitted`.
    public static func batteryLine(_ f: StatusFacts) -> String? {
        guard f.batteryPercent >= 0 else { return nil }
        return f.batteryPercent <= lowBatteryPercent
            ? "Battery low, \(f.batteryPercent) percent."
            : "Battery \(f.batteryPercent) percent."
    }

    /// Capitalises the first letter of an instruction so it reads as a sentence after the colon
    /// ("Route running: Turn right on Springfield"). Leaves the rest alone — street names and
    /// building names are already cased the way they should be spoken.
    private static func sentenceCased(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst()
    }
}
