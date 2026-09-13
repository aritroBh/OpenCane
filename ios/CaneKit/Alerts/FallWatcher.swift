//
//  FallWatcher.swift
//  CaneKit
//
//  Feeds CoreMotion to `FallDetector` (CaneKitLogic) and reports a fall. Effects only: every
//  threshold and the whole free-fall → impact → still-and-tilted decision live in the pure type,
//  with tests.
//
//  ⚠ **Unvalidated.** The thresholds have never been checked against a real cane going over; see
//  FallDetector.swift and docs/todo.md. It is on by default because the owner asked for falls to
//  be reported, but the first job on a real device is to drop a cane a few times with the trip log
//  running and re-derive the numbers.
//
//  Threading / isolation: `@Observable`, main actor by the target default. `CMMotionManager`
//  delivers to `.main`, which is one of the two cases AGENTS.md hard rule 1 allows
//  `MainActor.assumeIsolated` for.
//
//  Owner: `AppModel.fallWatcher`, started with the session when family alerts are on.
//

import CaneKitLogic
import CoreMotion
import Observation

/// Watches for the cane going over. `onFall` fires at most once per episode.
@Observable
final class FallWatcher {

    /// Samples per second handed to the detector. 20 Hz resolves a ~0.1 s free fall with a few
    /// samples to spare; the accelerometer will happily run at 100 Hz, which would only cost
    /// battery on a phone that is already the cane's only computer.
    private static let sampleHz: Double = 20

    /// True while CoreMotion is delivering.
    private(set) var isRunning = false
    /// Last fall seen, for the Settings row and the trip log.
    private(set) var lastFall: Fall?

    /// Called on the main actor when the cane has fallen and stayed down.
    @ObservationIgnored var onFall: ((Fall) -> Void)?

    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var detector = FallDetector()

    /// Which device axis points up the cane, from `AppModel.portraitMode`.
    ///
    /// The mount can hold the phone upright or clamped sideways, and tilt is meaningless without
    /// knowing which. Portrait: gravity is −y when upright. Landscape: −x.
    var portraitMount = true

    /// True when the hardware can do this at all (it cannot in the simulator).
    var isSupported: Bool { motion.isDeviceMotionAvailable }

    /// Starts sampling. Safe to call twice.
    func start() {
        guard !isRunning, motion.isDeviceMotionAvailable else { return }
        detector.reset()
        motion.deviceMotionUpdateInterval = 1.0 / Self.sampleHz
        // `.main`: provably on the main actor, so `assumeIsolated` is legitimate here
        // (AGENTS.md hard rule 1).
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            MainActor.assumeIsolated { self?.ingest(data) }
        }
        isRunning = true
    }

    /// Stops sampling and abandons any episode in progress.
    func stop() {
        guard isRunning else { return }
        motion.stopDeviceMotionUpdates()
        detector.reset()
        isRunning = false
    }

    /// Forgets the episode in progress without stopping (route start / stop).
    func reset() {
        detector.reset()
    }

    /// One motion sample → the detector.
    ///
    /// `gravity + userAcceleration` is total acceleration in g, so it reads ~1.0 at rest and
    /// collapses toward 0 in free fall — exactly what `FallDetector` expects.
    private func ingest(_ data: CMDeviceMotion) {
        let g = data.gravity, a = data.userAcceleration
        let x = g.x + a.x, y = g.y + a.y, z = g.z + a.z
        let magnitude = (x * x + y * y + z * z).squareRoot()

        // Angle of the mount's up-axis from vertical: 0° upright, ~90° lying down.
        let upComponent = portraitMount ? -g.y : -g.x
        let tilt = acos(min(1, max(-1, upComponent))) * 180 / .pi

        if let fall = detector.update(magnitudeG: magnitude, tiltDegrees: tilt,
                                      now: data.timestamp) {
            lastFall = fall
            onFall?(fall)
        }
    }
}
