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
//  Audio-session rule (AGENTS.md hard rule 7): the engine is `CHHapticEngine(audioSession: nil)`
//  with `playsHapticsOnly = true` — it never joins or reconfigures the app's `.playback`
//  session, so speech, the beacon and route changes cannot stop the buzz. If the system stops it
//  anyway for a call / Siri, the interruption's `.ended` notification restarts it.
//
//  Threading / isolation: `@MainActor`. Every public method is called on main by `AppModel`
//  (cue router at ~30 Hz normal / up to 60 Hz high-rate, scene-phase hooks, settings) or the Haptics debug card. Core Haptics
//  invokes `resetHandler` / `stoppedHandler` on its own internal queue, so those closures touch
//  no state: they capture only Sendable values (the stop reason's raw `Int`) and hop with
//  `Task { @MainActor in … }` (hard rule 1). The Geiger loop is an unstructured `Task` that
//  inherits the main actor; its `Task.sleep` yields main between taps.
//
//  Invariants: at most one Geiger loop (`approachTask`); `silenced` and an unhealthy engine
//  suppress rendering but `rendering` still reflects the decided cue (so the UI and the watch
//  mirror stay truthful). Patterns and their numbers mirror docs/design.md §5; the decision
//  numbers (distances, thresholds) live in CaneKitLogic (`CueDecider`, `GeigerRate`).
//

import AVFoundation
import CaneKitLogic
import CoreHaptics
import Foundation
import Observation

/// Renders `HapticCue`s on the phone's Taptic Engine and keeps the engine alive across
/// backgrounding and media-server resets. Owned by `AppModel`.
@MainActor
@Observable
final class HapticPlayer {

    // MARK: Published

    /// True while the engine is running and players exist. False → watch fallback.
    /// AppModel reads it per cue (`phoneCannotBuzz`) to mirror to the watch and speak cues, and
    /// at route start to announce "Haptics unavailable".
    private(set) var isHealthy = false
    /// Last engine / player error for the debug card; nil after a successful `start()`.
    private(set) var lastError: String?
    /// Kind currently being rendered (for the UI). `.clear` when idle.
    /// Updated even while silenced or unhealthy (it is the decided cue, not proof of a buzz).
    private(set) var rendering: CueKind = .clear
    /// Master silence: cues are decided but not rendered.
    /// Setting true stops the Geiger loop at once. Mirrors the persisted "Silence haptics"
    /// setting (`AppModel.hapticsSilenced`); while true AppModel routes cues to the watch and
    /// to speech instead (AGENTS.md).
    var silenced = false {
        didSet { if silenced { stopAll() } }
    }

    /// Hardware has a Taptic Engine (false in the simulator). Evaluated once.
    static let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    // MARK: Private

    /// The haptics-only engine; created once in `start()` and reused across restarts.
    @ObservationIgnored private var engine: CHHapticEngine?
    /// Left obstacle: 2 taps, 120 ms apart, intensity 0.9, sharpness 0.5.
    @ObservationIgnored private var leftPlayer: CHHapticPatternPlayer?
    /// Right obstacle: 3 taps, 100 ms apart, intensity 0.9, sharpness 0.5.
    @ObservationIgnored private var rightPlayer: CHHapticPatternPlayer?
    /// Head height: 2 taps, 80 ms apart, intensity 1.0, sharpness 1.0 (the hardest pattern).
    @ObservationIgnored private var headPlayer: CHHapticPatternPlayer?
    /// Single tap re-fired by the Geiger loop; intensity is modulated per tap via dynamic params.
    @ObservationIgnored private var tapPlayer: CHHapticPatternPlayer?
    /// Route cues felt on the cane (long, soft *continuous* buzzes — never confusable with the
    /// crisp obstacle taps): turn left = 1 long, turn right = 2 long, crossing = 3 long,
    /// arrived = long-short-long. Ground hazard (drop-off / hole / curb) = 4 fast heavy taps.
    @ObservationIgnored private var navPlayers: [NavCue: CHHapticPatternPlayer] = [:]
    @ObservationIgnored private var groundPlayer: CHHapticPatternPlayer?
    /// The running Geiger loop, or nil. Non-nil ⇔ loop active.
    @ObservationIgnored private var approachTask: Task<Void, Never>?
    /// Latest centre-obstacle distance (m) the loop reads each tick to set rate and intensity.
    @ObservationIgnored private var approachDistance: Float = 2
    /// The app wants haptics on (set by `start`, cleared by `stop`). Gates `resume` and the
    /// reset-handler rebuild so an intentionally stopped engine is not revived.
    @ObservationIgnored private var wantsRunning = false
    /// True while a bounded restart loop runs, so repeated stops never stack loops.
    @ObservationIgnored private var retrying = false
    /// Restarts the engine when a call / Siri interruption ends (it was stopped for the call).
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?

    init() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            MainActor.assumeIsolated { if type == .ended { self?.resume() } }
        }
    }

    // MARK: Lifecycle

    /// Create (or re-create) the engine and the four players. Safe to call repeatedly.
    /// Creates the engine once (haptics-only, no audio session, auto-shutdown off so it does not
    /// idle-stop between sparse cues), installs the reset/stopped handlers, starts it and builds
    /// the players. Success → `isHealthy = true`; any failure → `isHealthy = false` + `lastError`.
    /// Callers: `AppModel.start()` (after `configureAudioSession`) and `resume()`.
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
                // ⚠ Both handlers must stay `@Sendable`: `CHHapticEngineResetHandler` /
                // `StoppedHandler` are not `NS_SWIFT_SENDABLE` and CHHapticEngine.h says
                // "callbacks arrive on a non-main thread"; without it they would be inferred
                // `@MainActor` (the isolation trap behind the 2026-09-11 pedometer crash).
                e.resetHandler = { @Sendable [weak self] in
                    // Media server reset: the engine must be restarted and players rebuilt.
                    Task { @MainActor [weak self] in self?.rebuildAfterReset() }
                }
                e.stoppedHandler = { @Sendable [weak self] reason in
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
    /// Restarts only if the app wanted haptics and the engine is currently down. Caller:
    /// `AppModel.scenePhaseChanged(.active)`.
    func resume() {
        guard wantsRunning, !isHealthy else { return }
        start()
    }

    /// Intentional shutdown: clear `wantsRunning` (so resets / foregrounding do not revive it),
    /// stop the Geiger loop and the engine. The engine object is kept for a later `start()`.
    func stop() {
        wantsRunning = false
        stopAll()
        engine?.stop(completionHandler: nil)
        isHealthy = false
    }

    /// Media-server reset recovery (main actor, via the `resetHandler` hop): existing players are
    /// invalid after a reset, so restart the engine and rebuild all four. Skipped after `stop()`.
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

    /// Engine stopped by the system (main actor, via the `stoppedHandler` hop). Marks unhealthy
    /// so AppModel mirrors cues to the watch / speech, and stops the Geiger loop (its taps would
    /// only throw). `reasonCode` is `CHHapticEngine.StoppedReason.rawValue`, passed as an `Int`
    /// because that is what crosses the actor hop. Recovery: `resume()` on foreground for a
    /// suspension; the interruption's `.ended` notification for a call / Siri (retrying during
    /// the call would only be stopped again, Muse round 6); for any other reason (idle timeout,
    /// system error) a bounded retry — 5 tries, 1 s apart, never two loops at once — so cane
    /// haptics do not stay dead in the foreground until the next scene-phase change.
    private func engineStopped(reasonCode: Int) {
        isHealthy = false
        stopApproachLoop()
        let suspended = CHHapticEngine.StoppedReason.applicationSuspended.rawValue
        let interrupted = CHHapticEngine.StoppedReason.audioSessionInterrupt.rawValue
        guard reasonCode != suspended, reasonCode != interrupted else { return }
        lastError = "Haptic engine stopped (\(reasonCode))"
        guard !retrying else { return }
        retrying = true
        Task { @MainActor [weak self] in
            defer { self?.retrying = false }
            for _ in 0..<5 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.wantsRunning, !self.isHealthy else { return }
                self.start()
            }
        }
    }

    // MARK: Patterns

    /// (Re)build the four pattern players on the current engine. Throws on pattern/player
    /// creation failure; callers turn that into `isHealthy = false`. Patterns: docs/design.md §5.
    private func buildPlayers() throws {
        guard let engine else { return }
        leftPlayer = try engine.makePlayer(with: Self.pattern(taps: 2, gap: 0.12, intensity: 0.9, sharpness: 0.5))
        rightPlayer = try engine.makePlayer(with: Self.pattern(taps: 3, gap: 0.10, intensity: 0.9, sharpness: 0.5))
        headPlayer = try engine.makePlayer(with: Self.pattern(taps: 2, gap: 0.08, intensity: 1.0, sharpness: 1.0))
        tapPlayer = try engine.makePlayer(with: Self.pattern(taps: 1, gap: 0, intensity: 1.0, sharpness: 0.6))
        groundPlayer = try engine.makePlayer(with: Self.pattern(taps: 4, gap: 0.07, intensity: 1.0, sharpness: 0.3))
        navPlayers = [
            .turnLeft: try engine.makePlayer(with: Self.buzzes([0.45])),
            .turnRight: try engine.makePlayer(with: Self.buzzes([0.35, 0.35])),
            .crossing: try engine.makePlayer(with: Self.buzzes([0.3, 0.3, 0.3])),
            .arrived: try engine.makePlayer(with: Self.buzzes([0.4, 0.12, 0.4])),
        ]
    }

    /// Continuous buzzes of the given durations (s), 0.18 s apart, soft and dull (sharpness 0.15)
    /// so they read as "route", not "obstacle".
    private static func buzzes(_ durations: [TimeInterval]) throws -> CHHapticPattern {
        var t: TimeInterval = 0
        var events: [CHHapticEvent] = []
        for d in durations {
            events.append(CHHapticEvent(eventType: .hapticContinuous,
                                        parameters: [
                                            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.75),
                                            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.15),
                                        ],
                                        relativeTime: t, duration: d))
            t += d + 0.18
        }
        return try CHHapticPattern(events: events, parameters: [])
    }

    /// Route cue on the cane (in addition to the watch). No-op while silenced / unhealthy.
    func playNav(_ cue: NavCue) {
        guard !silenced, isHealthy, let p = navPlayers[cue] else { return }
        fire(p)
    }

    /// Ground hazard (drop-off, hole, curb, low obstacle) on the cane.
    func playGroundHazard() {
        guard !silenced, isHealthy else { return }
        fire(groundPlayer)
    }

    /// `taps` transients `gap` seconds apart.
    /// - Parameters:
    ///   - taps: number of transient events.
    ///   - gap: seconds between consecutive taps' start times.
    ///   - intensity: Core Haptics intensity 0…1 (felt strength).
    ///   - sharpness: Core Haptics sharpness 0…1 (0 = dull thud, 1 = crisp click).
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
    /// Always updates `rendering`; renders nothing while silenced or unhealthy (the caller
    /// handles the watch / speech fallback). A discrete cue does not stop a running Geiger
    /// loop — `CueDecider` sends `.stop` for that. Callers: `AppModel.handle` on `.fire`, `test`.
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
    /// Metres. Starts the loop if it is not running (e.g. after un-silencing mid-approach).
    /// Caller: `AppModel.handle` on `CueDecider`'s `.updateCenter`.
    func setApproach(distance: Float) {
        approachDistance = distance
        rendering = .center
        if !silenced, isHealthy { startApproachLoopIfNeeded() }
    }

    /// Active cue ended.
    /// Stops the Geiger loop and clears `rendering`; discrete patterns already in flight finish
    /// on their own (they are < 250 ms). Callers: AppModel on `.stop` and on backgrounding,
    /// `silenced = true`, and the debug "center" test after 2 s.
    func stopAll() {
        rendering = .clear
        stopApproachLoop()
    }

    /// Start a prebuilt pattern immediately; a nil player (engine never came up) is a no-op.
    private func fire(_ player: CHHapticPatternPlayer?) {
        do { try player?.start(atTime: CHHapticTimeImmediate) } catch {
            lastError = "Haptic play: \(error.localizedDescription)"
        }
    }

    // MARK: Geiger loop

    /// Start the centre-approach loop unless one is running. Each tick (main actor) reads
    /// `approachDistance`, fires one tap at intensity 0.6 (≥ 2 m) … 1.0 (≤ 0.5 m), then sleeps
    /// 1 / `GeigerRate.hertz(distance:)` s (2 Hz at 2 m … 8 Hz at 0.5 m, from CaneKitLogic).
    /// Runs until cancelled by `stopApproachLoop` (or `self` is gone at the top of a tick).
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

    /// Cancel the loop (its sleep throws, the `while` exits) and allow a new one to start.
    private func stopApproachLoop() {
        approachTask?.cancel()
        approachTask = nil
    }

    /// One Geiger tap: set the tap player's intensity via a dynamic parameter, then start it.
    /// - Parameter intensity: 0…1 intensity-control value applied to this tap.
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
    /// Buttons "Test left/center/right/head haptic" (accessibility labels are a UI-test
    /// contract). `.center` runs the Geiger loop at 1 m (4 Hz) for 2 s. Respects `silenced`.
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
