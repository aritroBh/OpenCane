//
//  AppModel.swift
//  CaneKit
//
//  Central owner of every engine and of the user settings. Lives on the main actor (the project
//  default); engines that run off-main publish Sendable value types back to it.
//
//  Engines by step:
//    step 2 DepthEngine · step 3 HapticPlayer · step 4 SpeechQueue/ObstacleNamer ·
//    step 5 PhoneWatchLink · step 6 NavigationEngine · step 7 BeaconEngine ·
//    step 8 SceneDescriber · step 9 TripTracker/LiveActivity/ThermalWatchdog.
//

import ARKit
import CaneKitLogic
import CoreLocation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {

    /// The live instance, for App Intents (Action button) that run inside the app process.
    private(set) static weak var shared: AppModel?

    // MARK: Engines

    /// LiDAR lanes + gyro gate (step 2).
    let depth = DepthEngine()
    /// Taptic Engine renderer (step 3).
    let haptics = HapticPlayer()
    /// JSONL trip log for reproducible test walks.
    let logger = TripLogger()
    /// The app's single voice (step 4).
    let speech = SpeechQueue()
    /// WatchConnectivity link (step 5).
    let watch = PhoneWatchLink()
    /// GPS + compass (step 6).
    let location = LocationService()
    /// Waypoint navigation (step 6).
    let nav = NavigationEngine()
    /// Spatial-audio beacon (step 7).
    let beacon = BeaconEngine()
    /// AirPods head yaw (step 7).
    let head = HeadPoseTracker()
    /// "Where am I" (step 8).
    let describer: SceneDescriber
    /// Elapsed / distance / steps for the arrival card (step 9).
    let trip = TripTracker()
    /// Dynamic Island / lock screen (step 9).
    let liveActivity = LiveActivityController()

    /// Route picker state.
    var destinationQuery = ""
    private(set) var routeError: String?
    private(set) var isBuildingRoute = false

    /// Decides which cue fires from each lane report (pure logic, CaneKitLogic).
    @ObservationIgnored private let decider = CueDecider()
    /// "door ahead, two meters" from the mesh classification (step 4).
    @ObservationIgnored private let namer = ObstacleNamer()
    /// Kind currently decided as active (for the UI); `.clear` when nothing is in range.
    private(set) var activeCue: CueKind = .clear
    /// Last discrete cue fired and when (debug footer).
    private(set) var lastCueDescription = "—"

    // MARK: Device capabilities (fixed for the life of the process)

    /// True on LiDAR iPhones: `ARFrame.sceneDepth` will be populated.
    let lidarSupported = DepthEngine.supportsDepth
    /// True when ARKit can build a classified mesh (door / wall / seat …).
    let meshClassificationSupported = DepthEngine.supportsMesh

    // MARK: Runtime state shown in the UI

    /// One-line status for the header ("Depth OK", "No LiDAR", …).
    var status: String { depth.status }
    /// Set once `start()` has run; guards against double starts from `.task` re-entry.
    private(set) var started = false
    /// Thermal state name for the debug footer; the watchdog (step 9) acts on it.
    private(set) var thermalName = "nominal"
    /// 0–100, or -1 when unknown (simulator).
    private(set) var batteryPercent = -1
    /// Camera Control spike counter (step 2): how many `.began` events reached us under ARKit.
    private(set) var cameraControlPresses = 0

    // MARK: Settings (persisted; each `didSet` pushes into the engines that care)

    /// Phone mounted upright (portrait, camera at the top). See ios/README.md §6 for the remap.
    var portraitMode: Bool = Settings.bool("portraitMode", default: true) {
        didSet { Settings.set(portraitMode, "portraitMode"); pushDepthSettings() }
    }
    /// Swap left/right if the mount points the camera the other way.
    var mirrorLeftRight: Bool = Settings.bool("mirrorLeftRight", default: false) {
        didSet { Settings.set(mirrorLeftRight, "mirrorLeftRight"); pushDepthSettings() }
    }
    /// Master haptic silence (state machine keeps running so speech/watch stay in sync).
    var hapticsSilenced: Bool = Settings.bool("hapticsSilenced", default: false) {
        didSet { Settings.set(hapticsSilenced, "hapticsSilenced"); haptics.silenced = hapticsSilenced }
    }
    /// Write the JSONL trip log.
    var loggingEnabled: Bool = Settings.bool("loggingEnabled", default: true) {
        didSet { Settings.set(loggingEnabled, "loggingEnabled"); logger.enabled = loggingEnabled }
    }
    /// Speak obstacle names ("door ahead, two meters"). Off = haptics only.
    var obstacleNamesEnabled: Bool = Settings.bool("obstacleNamesEnabled", default: true) {
        didSet { Settings.set(obstacleNamesEnabled, "obstacleNamesEnabled") }
    }
    /// Spatial click toward the next waypoint while navigating.
    var beaconEnabled: Bool = Settings.bool("beaconEnabled", default: true) {
        didSet { Settings.set(beaconEnabled, "beaconEnabled"); beacon.enabled = beaconEnabled }
    }
    /// Mirror every obstacle cue to the watch even while the phone engine is healthy.
    var fallbackToWatch: Bool = Settings.bool("fallbackToWatch", default: false) {
        didSet { Settings.set(fallbackToWatch, "fallbackToWatch") }
    }

    // MARK: Lifecycle

    @ObservationIgnored private var thermalObserver: NSObjectProtocol?
    @ObservationIgnored private var batteryObserver: NSObjectProtocol?

    @ObservationIgnored private var ticker: Task<Void, Never>?

    init() {
        describer = SceneDescriber(processor: depth.processor, speech: speech)
        pushDepthSettings()
        haptics.silenced = hapticsSilenced
        logger.enabled = loggingEnabled
        beacon.enabled = beaconEnabled
        AppModel.shared = self
    }

    /// One call for every trigger: on-screen button, watch, Action button, Camera Control.
    func describeScene() {
        logger.event("describe", ["provider": describer.providerName ?? "none"])
        describer.describe()
    }

    /// 10 Hz sync of the inputs the beacon needs that have no callback of their own
    /// (speech ducking, head yaw). Cheap; runs only while a route is active.
    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.beacon.setSpeaking(self.speech.isSpeaking)
                self.beacon.setHeadYaw(self.head.headYawDeg ?? 0)
                self.beacon.setTarget(bearing: self.nav.isNavigating ? self.nav.targetBearing : nil)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    /// Called once from the root view's `.task`. Starts the engines that exist at this step.
    func start() {
        guard !started else { return }
        started = true
        observeThermalAndBattery()
        logger.start()
        speech.configureAudioSession()       // before ARKit and before the haptic engine
        haptics.start()
        watch.onCommand = { [weak self] cmd in self?.handleWatchCommand(cmd) }
        watch.activate()
        wireNavigation()
        depth.onReport = { [weak self] report in
            self?.handle(report)
        }
        depth.start()
        logger.event("start", ["lidar": lidarSupported, "mesh": meshClassificationSupported,
                               "haptics": haptics.isHealthy])
        speech.prefetch(Self.commonLines)
        speech.say(lidarSupported ? "CaneKit ready." : "CaneKit. This phone has no LiDAR.", .nav)
        // Automation hook (simulator GPS replay, UI tests): `--demo-route` argument or the
        // CANEKIT_DEMO_ROUTE=1 environment variable starts guidance at launch.
        if CommandLine.arguments.contains("--demo-route")
            || ProcessInfo.processInfo.environment["CANEKIT_DEMO_ROUTE"] == "1" {
            startDemoRoute()
        }
    }

    /// Foreground/background transitions. ARKit pauses itself in the background; we pause the
    /// engine explicitly so the gyro stops too, and resume without resetting tracking. Core
    /// Haptics stops its engine on suspend, so it is restarted on `.active`.
    func scenePhaseChanged(_ phase: ScenePhase) {
        guard started else { return }
        switch phase {
        case .active:
            haptics.resume()
            depth.resume()
        case .inactive:
            break
        case .background:
            depth.pause()
            haptics.stopAll()
            decider.reset()
            namer.reset()
            activeCue = .clear
            logger.flush()
        @unknown default:
            break
        }
    }

    // MARK: Report routing (the "cue router")

    /// Every depth report lands here (~15 Hz): decide → render on the phone (step 3);
    /// step 4 adds the ObstacleNamer, step 5 the watch mirror.
    private func handle(_ report: LaneReport) {
        if let output = decider.update(report, now: report.timestamp) {
            switch output {
            case .fire(let cue):
                activeCue = cue.kind
                haptics.play(cue)
                // Wrist mirror: whenever the phone cannot buzz, or the user asked for both.
                if !haptics.isHealthy || fallbackToWatch {
                    watch.send(obstacle: cue.kind, now: report.timestamp)
                }
                lastCueDescription = "\(cue.kind.rawValue) @ \(String(format: "%.1f", report.timestamp))s"
                var fields: [String: Any] = ["kind": cue.kind.rawValue, "ar_t": report.timestamp]
                if case .centerApproach(let d) = cue { fields["distance"] = Double(d) }
                logger.event("cue", fields)
            case .updateCenter(let d):
                activeCue = .center
                haptics.setApproach(distance: d)
            case .stop:
                activeCue = .clear
                haptics.stopAll()
                logger.event("cue", ["kind": "clear"])
            }
        }
        if obstacleNamesEnabled, let line = namer.update(report, now: report.timestamp) {
            speech.say(line, .obstacle, ttl: 4)      // > namer interval + one utterance
            logger.event("speech", ["text": line, "priority": "obstacle"])
        }
        logger.lanes(report, cue: activeCue, thermal: thermalName, battery: batteryPercent)
    }

    // MARK: Navigation (step 6)

    private func wireNavigation() {
        location.onFix = { [weak self] fix in
            guard let self else { return }
            self.nav.update(fix: fix)
            self.trip.ingest(fix)
            if self.nav.isNavigating {
                self.liveActivity.update(instruction: self.nav.instruction,
                                         distanceM: self.nav.distanceToNext ?? 0, kind: self.lastNavKind)
            }
            self.logger.event("gps", ["lat": fix.coordinate.latitude, "lon": fix.coordinate.longitude,
                                      "acc": fix.accuracy, "speed": fix.speed])
        }
        location.onHeading = { [weak self] h in
            guard let self else { return }
            // Gyro gate: a compass reading taken mid-sweep is noise.
            guard self.depth.report.isTrusted || !self.depth.isRunning else { return }
            self.nav.update(heading: h, now: Date().timeIntervalSinceReferenceDate)
            self.beacon.setHeading(h)
        }
        nav.onSpeak = { [weak self] text, priority in
            self?.speech.say(text, priority, ttl: 12)
            self?.logger.event("speech", ["text": text, "priority": "nav"])
        }
        nav.onNavCue = { [weak self] cue in
            self?.watch.send(nav: cue)
            self?.lastNavKind = cue.rawValue
            self?.logger.event("navcue", ["cue": cue.rawValue])
        }
        nav.onWaypointAdvanced = { [weak self] in
            guard let self else { return }
            self.logger.event("waypoint", ["index": self.nav.waypointIndex])
            self.pushStatusToWatch()
            // Auto-recenter once the turn has settled (same window the veer cue waits for):
            // by then the user faces the new leg, so "head straight" = phone heading.
            let settle = self.nav.turnSettleSeconds
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(settle))
                guard let self, self.nav.isNavigating else { return }
                self.head.recenter()
            }
        }
        nav.onArrived = { [weak self] in
            guard let self else { return }
            self.logger.event("arrived")
            self.beacon.stop()
            self.head.stop()
            self.stopTicker()
            self.pushStatusToWatch()
            self.liveActivity.end(final: self.nav.instruction)
            // Arrival card, spoken after the waypoint's own line (same priority → queued),
            // once the step count has been refreshed.
            Task { [weak self] in
                guard let self else { return }
                await self.trip.stop()
                let destination = self.nav.route?.waypoints.last?.say ?? "Arrived"
                let summary = self.trip.spokenSummary(destination: destination)
                self.speech.say(summary, .nav, ttl: 30)
                self.logger.event("speech", ["text": summary, "priority": "nav"])
            }
        }
    }

    /// Last wrist cue kind, for the Live Activity glyph.
    @ObservationIgnored private var lastNavKind = "straight"

    /// The user is facing the way to walk: zero the head yaw there.
    func recenter() {
        head.recenter()
        speech.say("Recentered.", .nav, ttl: 2)
        logger.event("recenter")
    }

    /// Start the bundled demo route (ISR Townsend Hall → CIF).
    func startDemoRoute() {
        do {
            let route = try RouteSource.bundled()
            beginRoute(route)
        } catch {
            routeError = error.localizedDescription
            speech.say("Route file missing.", .nav)
        }
    }

    /// Build a live MapKit walking route to `destinationQuery` from the current fix.
    func startMapKitRoute() {
        let query = destinationQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { routeError = "Type a destination first"; return }
        location.start()
        isBuildingRoute = true
        routeError = nil
        speech.say("Finding a route to \(query).", .nav)
        Task { [weak self] in
            guard let self else { return }
            defer { self.isBuildingRoute = false }
            // Wait briefly for a first fix if we have none yet.
            var tries = 0
            while self.location.fix == nil, tries < 30 {
                try? await Task.sleep(for: .milliseconds(500))
                tries += 1
            }
            guard let fix = self.location.fix else {
                self.routeError = "No GPS fix yet"
                self.speech.say("No GPS fix yet. Try again outside.", .nav)
                return
            }
            do {
                let origin = CLLocationCoordinate2D(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
                let route = try await RouteSource.mapKit(to: query, from: origin)
                self.beginRoute(route)
            } catch {
                self.routeError = error.localizedDescription
                self.speech.say("Could not build a route. \(error.localizedDescription)", .nav)
            }
        }
    }

    func stopRoute() {
        nav.stop()
        location.stop()
        beacon.stop()
        head.stop()
        stopTicker()
        Task { [weak self] in await self?.trip.stop() }
        liveActivity.end()
        speech.stopAll()                     // queued waypoint lines must not play after Stop
        speech.say("Route stopped.", .nav)
        logger.event("route", ["action": "stop"])
        pushStatusToWatch()
    }

    /// Lines the natural voice should have ready before they are needed.
    static let commonLines = [
        "CaneKit ready.", "Route started.", "Route stopped.", "Next.", "Recentered.",
        "Veer left.", "Veer right.", "GPS weak. Cues may be late.", "GPS back.",
        "No route running.", "No GPS fix yet. Try again outside.",
    ]

    private func beginRoute(_ route: Route) {
        routeError = nil
        // Every waypoint line and the route intro, synthesized now so they play instantly.
        speech.prefetch(route.waypoints.map(\.say) + Self.commonLines
                        + ["Route started. \(route.name). First: \(route.waypoints.first?.say ?? "")"])
        location.start()
        nav.start(route)
        beacon.start()
        head.start()
        startTicker()
        trip.start()
        lastNavKind = "straight"
        liveActivity.start(routeName: route.name, instruction: nav.instruction, distanceM: nav.distanceToNext ?? 0)
        logger.event("route", ["action": "start", "name": route.name, "waypoints": route.waypoints.count])
        pushStatusToWatch()
    }

    private func pushStatusToWatch() {
        watch.send(status: nav.instruction, distanceM: nav.distanceToNext ?? -1)
    }

    // MARK: Watch commands

    /// Next / Describe / Recenter from the wrist. The describer (step 8) and the beacon (step 7)
    /// hook in here; until then those two are acknowledged aloud.
    private func handleWatchCommand(_ cmd: WatchToPhone) {
        logger.event("watch", ["command": cmd.rawValue])
        switch cmd {
        case .nextWaypoint:
            if nav.isNavigating { nav.next() } else { speech.say("No route running.", .nav, ttl: 2) }
        case .describe: describeScene()
        case .recenter: recenter()
        }
    }

    /// Debug buttons on the Watch card.
    func watchTest(_ cue: NavCue) {
        watch.send(nav: cue)
        logger.event("watch", ["test": cue.rawValue])
    }

    /// Debug button: prove the audio route (AirPods) and the queue/interrupt behaviour.
    func speechTest() {
        speech.say("Scene test: sidewalk ahead, bike rack at ten o'clock, two meters.", .scene)
        speech.say("Door ahead, one meter.", .obstacle)
    }


    /// Camera Control / volume press reached the app while ARKit owns the camera.
    func cameraControlPressed() {
        cameraControlPresses += 1
        describeScene()
    }

    // MARK: Private

    private func pushDepthSettings() {
        depth.apply(portrait: portraitMode, mirror: mirrorLeftRight)
    }

    private func observeThermalAndBattery() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        updateBattery()
        updateThermal()
        // `.main` queue + assumeIsolated: the closures are @Sendable but provably on main.
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateThermal() }
        }
        batteryObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateBattery() }
        }
    }

    private func updateThermal() {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermalName = "nominal"
        case .fair: thermalName = "fair"
        case .serious: thermalName = "serious"
        case .critical: thermalName = "critical"
        @unknown default: thermalName = "unknown"
        }
        // Step 2 already honours the cheapest downgrade: no mesh at .serious or worse.
        let hot = ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
        depth.setMeshClassification(!hot)
    }

    private func updateBattery() {
        let level = UIDevice.current.batteryLevel
        batteryPercent = level < 0 ? -1 : Int((level * 100).rounded())
    }
}

/// Thin UserDefaults wrapper so settings stay one-liners above.
enum Settings {
    static func bool(_ key: String, default d: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? d
    }
    static func set(_ value: Bool, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
