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
        didSet { Settings.set(hapticsSilenced, "hapticsSilenced") }
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
    }

    /// Called once from the root view's `.task`. Starts the engines that exist at this step.
    func start() {
        guard !started else { return }
        started = true
        observeThermalAndBattery()
        depth.onReport = { [weak self] report in
            self?.handle(report)
        }
        depth.start()
    }

    /// Foreground/background transitions. ARKit pauses itself in the background; we pause the
    /// engine explicitly so the gyro stops too, and resume without resetting tracking.
    func scenePhaseChanged(_ phase: ScenePhase) {
        guard started else { return }
        switch phase {
        case .active: depth.resume()
        case .inactive: break
        case .background: depth.pause()
        @unknown default: break
        }
    }

    // MARK: Report routing

    /// Every depth report lands here (~15 Hz). Step 3 feeds the CueDecider → HapticPlayer,
    /// step 4 the ObstacleNamer, step 5 the watch mirror.
    private func handle(_ report: LaneReport) {
        // Step 2: nothing beyond publishing (the UI observes `depth.report`).
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
