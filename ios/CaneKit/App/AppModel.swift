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
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {

    // MARK: Engines

    /// LiDAR lanes + gyro gate (step 2).
    let depth = DepthEngine()
    /// Taptic Engine renderer (step 3).
    let haptics = HapticPlayer()
    /// JSONL trip log for reproducible test walks.
    let logger = TripLogger()
    /// The app's single voice (step 4).
    let speech = SpeechQueue()

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
    /// Mirror every obstacle cue to the watch even while the phone engine is healthy.
    var fallbackToWatch: Bool = Settings.bool("fallbackToWatch", default: false) {
        didSet { Settings.set(fallbackToWatch, "fallbackToWatch") }
    }

    // MARK: Lifecycle

    @ObservationIgnored private var thermalObserver: NSObjectProtocol?
    @ObservationIgnored private var batteryObserver: NSObjectProtocol?

    init() {
        pushDepthSettings()
        haptics.silenced = hapticsSilenced
        logger.enabled = loggingEnabled
    }

    /// Called once from the root view's `.task`. Starts the engines that exist at this step.
    func start() {
        guard !started else { return }
        started = true
        observeThermalAndBattery()
        logger.start()
        speech.configureAudioSession()       // before ARKit and before the haptic engine
        haptics.start()
        depth.onReport = { [weak self] report in
            self?.handle(report)
        }
        depth.start()
        logger.event("start", ["lidar": lidarSupported, "mesh": meshClassificationSupported,
                               "haptics": haptics.isHealthy])
        speech.say(lidarSupported ? "CaneKit ready." : "CaneKit. This phone has no LiDAR.", .nav)
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

    /// Debug button: prove the audio route (AirPods) and the queue/interrupt behaviour.
    func speechTest() {
        speech.say("Scene test: sidewalk ahead, bike rack at ten o'clock, two meters.", .scene)
        speech.say("Door ahead, one meter.", .obstacle)
    }


    /// Camera Control / volume press reached the app while ARKit owns the camera.
    func cameraControlPressed() {
        cameraControlPresses += 1
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
