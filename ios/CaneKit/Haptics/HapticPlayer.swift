//
//  HapticPlayer.swift
//  CaneKit
//
//  Plays obstacle cues on the phone's Taptic Engine. The phone is clamped to the cane shaft, so
//  these transients are what the user feels in the hand. `CueDecider` (CaneKitLogic) decides
//  what/when; this file only renders.
//
//  Patterns (docs/design.md §5):
//    centre approach   Geiger loop: one sharp tap repeated at 2 Hz (2 m) … 8 Hz (0.5 m)
//    left              2 taps, 120 ms apart
//    right             3 taps, 100 ms apart
//    head              2 hard, sharp hits 80 ms apart
//
//  Engine care: Core Haptics stops the engine on backgrounding and on media-server resets. We
//  restart on foreground, rebuild players on reset, and publish `isHealthy` so the cue router
//  can mirror cues to the watch when the phone cannot buzz.
//

import CaneKitLogic
import CoreHaptics
import Foundation
import Observation

@MainActor
@Observable
final class HapticPlayer {

    // MARK: Published

    /// True while the engine is running and players exist. False → watch fallback.
    private(set) var isHealthy = false
    private(set) var lastError: String?
    /// Kind currently being rendered (for the UI). `.clear` when idle.
    private(set) var rendering: CueKind = .clear
    /// Master silence: cues are decided but not rendered.
    var silenced = false {
        didSet { if silenced { stopAll() } }
    }

    static let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    // MARK: Private

    @ObservationIgnored private var engine: CHHapticEngine?
    @ObservationIgnored private var leftPlayer: CHHapticPatternPlayer?
    @ObservationIgnored private var rightPlayer: CHHapticPatternPlayer?
    @ObservationIgnored private var headPlayer: CHHapticPatternPlayer?
    @ObservationIgnored private var tapPlayer: CHHapticPatternPlayer?
    @ObservationIgnored private var approachTask: Task<Void, Never>?
    @ObservationIgnored private var approachDistance: Float = 2
    @ObservationIgnored private var wantsRunning = false

    init() {}

    // MARK: Lifecycle

    /// Create (or re-create) the engine and the four players. Safe to call repeatedly.
    func start() {
        wantsRunning = true
        guard Self.supported else {
            lastError = "This device has no Taptic Engine"
            isHealthy = false
            return
        }
        do {
            if engine == nil {
                // Haptics-only engine, independent of the app's audio session so speech/beacon
                // route changes never stop the buzz.
                let e = try CHHapticEngine(audioSession: nil)
                e.playsHapticsOnly = true
                e.isAutoShutdownEnabled = false
                e.resetHandler = { [weak self] in
                    // Media server reset: the engine must be restarted and players rebuilt.
                    Task { @MainActor [weak self] in self?.rebuildAfterReset() }
                }
                e.stoppedHandler = { [weak self] reason in
                    let code = reason.rawValue
                    Task { @MainActor [weak self] in self?.engineStopped(reasonCode: code) }
                }
                engine = e
            }
            try engine?.start()
            try buildPlayers()
            isHealthy = true
            lastError = nil
        } catch {
            isHealthy = false
            lastError = "Haptic engine: \(error.localizedDescription)"
        }
    }

    /// Foreground hook: Core Haptics stops the engine when the app leaves the foreground.
    func resume() {
        guard wantsRunning, !isHealthy else { return }
        start()
    }

    func stop() {
        wantsRunning = false
        stopAll()
        engine?.stop(completionHandler: nil)
        isHealthy = false
    }

    private func rebuildAfterReset() {
        guard wantsRunning else { return }
        do {
            try engine?.start()
            try buildPlayers()
            isHealthy = true
        } catch {
            isHealthy = false
            lastError = "Haptic reset failed: \(error.localizedDescription)"
        }
    }

    private func engineStopped(reasonCode: Int) {
        isHealthy = false
        stopApproachLoop()
        // .applicationSuspended (2) is expected; anything else is worth showing.
        if reasonCode != CHHapticEngine.StoppedReason.applicationSuspended.rawValue {
            lastError = "Haptic engine stopped (\(reasonCode))"
        }
    }

    // MARK: Patterns

    private func buildPlayers() throws {
        guard let engine else { return }
        leftPlayer = try engine.makePlayer(with: Self.pattern(taps: 2, gap: 0.12, intensity: 0.9, sharpness: 0.5))
        rightPlayer = try engine.makePlayer(with: Self.pattern(taps: 3, gap: 0.10, intensity: 0.9, sharpness: 0.5))
        headPlayer = try engine.makePlayer(with: Self.pattern(taps: 2, gap: 0.08, intensity: 1.0, sharpness: 1.0))
        tapPlayer = try engine.makePlayer(with: Self.pattern(taps: 1, gap: 0, intensity: 1.0, sharpness: 0.6))
    }

    /// `taps` transients `gap` seconds apart.
    private static func pattern(taps: Int, gap: TimeInterval, intensity: Float, sharpness: Float) throws -> CHHapticPattern {
        let events = (0..<taps).map { i in
            CHHapticEvent(eventType: .hapticTransient,
                          parameters: [
                            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                          ],
                          relativeTime: Double(i) * gap)
        }
        return try CHHapticPattern(events: events, parameters: [])
    }

    // MARK: Rendering

    /// Render a decided cue. Discrete cues play once; the centre cue starts the Geiger loop.
    func play(_ cue: HapticCue) {
        rendering = cue.kind
        guard !silenced, isHealthy else { return }
        switch cue {
        case .left: fire(leftPlayer)
        case .right: fire(rightPlayer)
        case .head: fire(headPlayer)
        case .centerApproach(let d):
            approachDistance = d
            startApproachLoopIfNeeded()
        }
    }

    /// Distance update while the centre cue is active: only the loop rate changes.
    func setApproach(distance: Float) {
        approachDistance = distance
        rendering = .center
        if !silenced, isHealthy { startApproachLoopIfNeeded() }
    }

    /// Active cue ended.
    func stopAll() {
        rendering = .clear
        stopApproachLoop()
    }

    private func fire(_ player: CHHapticPatternPlayer?) {
        do { try player?.start(atTime: CHHapticTimeImmediate) } catch {
            lastError = "Haptic play: \(error.localizedDescription)"
        }
    }

    // MARK: Geiger loop

    private func startApproachLoopIfNeeded() {
        guard approachTask == nil else { return }
        approachTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Intensity 0.6 at 2 m → 1.0 at 0.5 m, tracking the rate ramp.
                let d = self.approachDistance
                let hz = GeigerRate.hertz(distance: d)
                let intensity = Float(0.6 + 0.4 * min(1, max(0, (2.0 - Double(d)) / 1.5)))
                self.fireTap(intensity: intensity)
                try? await Task.sleep(for: .seconds(1.0 / hz))
            }
        }
    }

    private func stopApproachLoop() {
        approachTask?.cancel()
        approachTask = nil
    }

    private func fireTap(intensity: Float) {
        guard let tapPlayer else { return }
        do {
            try tapPlayer.sendParameters([
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0),
            ], atTime: CHHapticTimeImmediate)
            try tapPlayer.start(atTime: CHHapticTimeImmediate)
        } catch {
            lastError = "Haptic tap: \(error.localizedDescription)"
        }
    }

    // MARK: Test buttons

    /// Bypasses the decider for the debug screen.
    func test(_ kind: CueKind) {
        switch kind {
        case .left: play(.left)
        case .right: play(.right)
        case .head: play(.head)
        case .center:
            play(.centerApproach(distance: 1.0))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.stopAll()
            }
        case .clear: stopAll()
        }
    }
}
