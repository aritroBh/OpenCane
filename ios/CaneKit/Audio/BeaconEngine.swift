//
//  BeaconEngine.swift
//  CaneKit
//
//  A soft click that always comes from the direction to walk. AVAudioEngine → AVAudioPlayerNode
//  (mono, generated) → AVAudioEnvironmentNode (HRTF) → output. One rotation convention:
//    · the source sits at the *absolute* target bearing θ (degrees true), 10 m out:
//        position = (10 sin θ, 0, −10 cos θ)      (north = −z, east = +x)
//    · the listener's yaw carries the user's absolute facing = phone heading + head yaw:
//        listenerAngularOrientation.yaw = −(heading + headYaw)   (AVAudio yaw is CCW-positive)
//  Volume shrinks as the bearing error shrinks: silent under 10°, full by 90°, and ducks while
//  speech plays. Without AirPods motion data headYaw is 0 and the same graph pans from the
//  compass alone.
//
//  Audio-session rules (AGENTS.md hard rule 7): the engine plays on the app's single `.playback`
//  / `.default` / `[.duckOthers]` session configured by `SpeechQueue.configureAudioSession()`;
//  this file never calls `setCategory`. It only re-activates the session (`setActive(true)`)
//  when recovering from an interruption. Rendering is `.HRTF` with a mono source
//  (`.spatializeIfMono`) and `outputType = .headphones`; no Bluetooth/HFP options anywhere,
//  because HFP would drop AirPods to mono call audio and the click would lose its direction.
//  Deliberate behaviour (AGENTS.md): the beacon only plays into headphones — `render()` is
//  silent unless `headphonesConnected`.
//
//  Threading / isolation: `@MainActor`. AVAudioEngine does its real-time rendering on its own
//  audio thread; we only change node parameters (position, listener yaw, volume) from main,
//  which AVAudioEngine supports. Both NotificationCenter observers use `queue: .main`, so
//  `MainActor.assumeIsolated` is legal inside them (hard rule 1); only the decoded
//  `InterruptionType` crosses in. The restart-retry `Task` inherits the main actor.
//
//  Inputs (all main actor, from AppModel): `setHeading` on every heading update
//  (`LocationService.onHeading`: GPS course, or a compass reading that passed the gyro gate), and a
//  10 Hz ticker (`AppModel.startTicker`) that pushes `setSpeaking` (SpeechQueue.isSpeaking),
//  `setHeadYaw` (CaneKitLogic `HeadYawSelector`: AirPods yaw, else the front camera's
//  `FaceHeadPose` yaw, else 0 — forced to 0 while a recenter is pending on a new leg) and
//  `setTarget` (nil when not navigating, or while NavigationEngine keeps the beacon silent —
//  settling at a crossing, a curved leg). `start()` / `stop()` bracket a route
//  (`AppModel.startRouteNow`; `stopRoute`, `endRouteQuietly` and arrival). `headphonesConnected`
//  comes from `AudioRouteMonitor`; `enabled` from the persisted "Audio beacon while navigating"
//  setting, and `VoiceInputEngine` turns it off while the walker dictates and restores it after.
//
//  Readers: GuideCard's beacon pill (`renderedVolume`, `isRunning`). Tests: none (AVAudioEngine,
//  device-only); the bearings it is given are pinned by `NavSupportTests` (settling, crossings),
//  the head yaw by `HeadYawSourcesTests`. ⚠ The rotation convention and the sign of head yaw need
//  the AirPods device walk: turn the head with the body still and the click moves the other way.
//

import AVFoundation
import Foundation
import Observation

/// Head-tracked (or compass-panned) spatial click that points the way to walk. Owned by
/// `AppModel`; one instance, one AVAudioEngine graph for the app's lifetime.
@MainActor
@Observable
final class BeaconEngine {

    // MARK: Published

    /// True between a successful `start()` and `stop()`. Not cleared when the system stops the
    /// engine during an interruption — that is what lets `restartEngine` bring it back.
    private(set) var isRunning = false
    /// Last start/restart failure (debug); nil after a successful (re)start.
    private(set) var lastError: String?
    /// The bearing error currently rendered (debug).
    /// Degrees in (−180, 180], positive = target is to the right of the user's facing; nil when
    /// silent for lack of input.
    private(set) var renderedError: Double?
    /// 0…1, what the mixer is set to (debug).
    /// Also drives the GuideCard pill ("Beacon N%"), so it must be 0 whenever nothing plays.
    private(set) var renderedVolume: Float = 0
    /// User setting (persisted by AppModel as `beaconEnabled`). False silences immediately; turning
    /// it back on takes effect at the next input update (≤ 100 ms via the ticker). Also written by
    /// `VoiceInputEngine` (off while listening, then its previous value), so the click never plays
    /// over the walker's dictation.
    var enabled = true {
        didSet { if !enabled { silence() } }
    }
    /// Only render into headphones: a spatial click out of the cane-mounted speaker is noise
    /// for everyone and carries no direction. Set from `AudioRouteMonitor` via
    /// `AppModel.wireAudioRoute()` — undebounced (`onImmediateChange`), so the click stops the moment
    /// the AirPods drop; re-renders immediately on change.
    var headphonesConnected = false {
        didSet { render() }
    }

    // MARK: Private

    /// The one audio graph: player → environment → main mixer → output.
    @ObservationIgnored private let engine = AVAudioEngine()
    /// Mono source node looping `clickBuffer`; its `position` is the target direction.
    @ObservationIgnored private let player = AVAudioPlayerNode()
    /// HRTF spatialiser; its listener yaw is the user's absolute facing.
    @ObservationIgnored private let environment = AVAudioEnvironmentNode()
    /// 400 ms mono buffer (40 ms click + silence) looped forever → a 2.5 Hz tick.
    @ObservationIgnored private var clickBuffer: AVAudioPCMBuffer?
    /// `AVAudioEngineConfigurationChange` observer (route change, e.g. AirPods connect).
    @ObservationIgnored private var configObserver: NSObjectProtocol?
    /// `AVAudioSession.interruptionNotification` observer (call, Siri).
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    /// Where to walk, degrees true (0 = north, clockwise); nil = silent.
    @ObservationIgnored private var targetBearing: Double?
    /// Phone/body heading, degrees true; nil = silent (no compass yet).
    @ObservationIgnored private var heading: Double?
    /// Head yaw relative to the recentred forward, degrees, right-positive; 0 = no head source (the
    /// beacon then pans from the heading alone).
    @ObservationIgnored private var headYaw: Double = 0
    /// Speech is playing → volume × `duckWhileSpeaking`.
    @ObservationIgnored private var speaking = false
    /// Nodes are attached exactly once; a second `start()` (second route) only restarts the engine.
    @ObservationIgnored private var graphBuilt = false
    /// Invalidates delayed interruption-restart retries when a route stops or a newer route starts.
    /// Without this fence, a retry from an old route could restart the beacon on a replacement
    /// route after its own recovery state had already been discarded.
    @ObservationIgnored private var lifecycleGeneration: UInt64 = 0

    /// Silent inside this error; full volume at `fullVolumeError`.
    /// Degrees. Inside ±10° the user is on course, so silence *is* the "keep going" signal.
    var silentError: Double = 10
    /// Degrees of bearing error at which volume reaches 1.0 (linear ramp from `silentError`).
    var fullVolumeError: Double = 90
    /// Volume multiplier (0…1) applied while speech plays so instructions stay intelligible.
    var duckWhileSpeaking: Float = 0.3

    /// The engine and node objects exist from here, but nothing is attached, scheduled or started
    /// until the first `start()` (route start); no observers are installed either.
    init() {}

    // MARK: Lifecycle

    /// Build the graph on first use, start the engine, (re)start the click loop, install the
    /// route/interruption observers (once) and render the current inputs. Idempotent while
    /// running. On failure sets `lastError` and leaves `isRunning == false`. Caller:
    /// `AppModel.startRouteNow` (after the depth-readiness gate). Requires the app audio session to
    /// be configured already (`SpeechQueue.configureAudioSession`, at launch).
    func start() {
        guard !isRunning else { return }
        lifecycleGeneration &+= 1
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            if clickBuffer == nil {
                guard let click = Self.makeClick(format: format) else {
                    lastError = "Beacon: click buffer unavailable"
                    isRunning = false
                    return
                }
                clickBuffer = click
            }
            if !graphBuilt {
                engine.attach(player)
                engine.attach(environment)
                // Mono in → environment (spatialised) → main mixer.
                engine.connect(player, to: environment, format: format)
                engine.connect(environment, to: engine.mainMixerNode, format: nil)

                player.renderingAlgorithm = .HRTF
                player.sourceMode = .spatializeIfMono
                environment.outputType = .headphones
                environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
                environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
                environment.distanceAttenuationParameters.referenceDistance = 10
                environment.distanceAttenuationParameters.maximumDistance = 20
                environment.reverbParameters.enable = false
                graphBuilt = true
            }

            try engine.start()
            isRunning = true
            guard restartLoop() else {
                engine.stop()
                isRunning = false
                return
            }
            lastError = nil
            observeRouteChanges()
            render()
        } catch {
            lastError = "Beacon: \(error.localizedDescription)"
            isRunning = false
        }
    }

    /// Stop the click and the engine (graph and observers stay for the next route). After this
    /// `restartEngine` is a no-op, so interruptions no longer revive the beacon. Does not reset
    /// `renderedVolume`; the next input update (any `set…`) renders silence since
    /// `isRunning` is false. Callers: `AppModel.stopRoute`, `endRouteQuietly` (a route replaced
    /// mid-walk) and the `nav.onArrived` handler.
    func stop() {
        lifecycleGeneration &+= 1
        player.stop()
        engine.stop()
        isRunning = false
    }

    /// One looping click, never two: stop first (drops any scheduled buffer), then schedule + play.
    /// Starts at the last `renderedVolume`, so a restart does not blip at full volume before
    /// the next `render()`.
    @discardableResult
    private func restartLoop() -> Bool {
        guard clickBuffer != nil else {
            lastError = "Beacon: click buffer unavailable"
            return false
        }
        player.stop()
        player.scheduleBuffer(clickBuffer!, at: nil, options: [.loops])
        player.volume = renderedVolume
        player.play()
        return true
    }

    /// AirPods connect/disconnect re-configures the engine, and a phone call / Siri interrupts
    /// the audio session (the engine stops silently): restart the graph in both cases.
    ///
    /// Installed once (first `start()`), never removed. Both observers use `queue: .main`, which
    /// is what makes `MainActor.assumeIsolated` legal in their closures. Interruption `.began`
    /// only zeroes the published volume (the system already stopped the audio); `.ended`
    /// restarts. `SpeechQueue` handles the same interruption for speech independently.
    private func observeRouteChanges() {
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartEngine() }
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            MainActor.assumeIsolated {
                if type == .began { self?.silence() }          // the pill must not claim a live click
                if type == .ended { self?.restartEngine() }
            }
        }
    }

    /// Called when the app returns to the foreground (`AppModel.scenePhaseChanged(.active)`): the
    /// engine can stop across a screen lock without an interruption notification; restart it if a
    /// route is running (Muse M4).
    func resumeIfNeeded() {
        guard isRunning, !engine.isRunning else { return }
        restartEngine()
    }

    /// Bring a stopped engine back with its loop; a no-op when the beacon is not in use.
    /// Activation can fail right at `.ended` while the call's session winds down, so retry up to
    /// three times, a second apart — otherwise the click would be gone for the rest of the walk.
    ///
    /// Re-activates the shared session (never re-categorises it), starts the engine if the
    /// system stopped it, reschedules the loop and re-renders. `attempt` counts retries (0…3).
    /// Main actor; retries run in a main-actor `Task`.
    private func restartEngine(attempt: Int = 0, generation: UInt64? = nil) {
        let generation = generation ?? lifecycleGeneration
        guard isRunning, generation == lifecycleGeneration else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning { try engine.start() }
            guard restartLoop() else {
                engine.stop()
                isRunning = false
                return
            }
            render()
            lastError = nil
        } catch {
            lastError = "Beacon restart: \(error.localizedDescription)"
            guard attempt < 3 else {
                // Do not leave the published beacon state looking alive after all recovery attempts
                // failed. The route's speech/watch channels remain available, and the card exposes
                // this error so a later route can retry cleanly.
                engine.stop()
                isRunning = false
                silence()
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.lifecycleGeneration == generation else { return }
                self.restartEngine(attempt: attempt + 1, generation: generation)
            }
        }
    }

    // MARK: Inputs

    /// Where to walk, degrees true. nil = no target → silent. Pushed at 10 Hz by the ticker with
    /// `nav.targetBearing` while navigating (nil on a curved leg or while a crossing settles).
    func setTarget(bearing: Double?) {
        targetBearing = bearing
        render()
    }

    /// The phone's heading, degrees true: the GPS course while walking, or a compass reading the
    /// caller already gyro-gated (only the compass is gated — gating the course froze it mid-sweep,
    /// Muse H1). nil = silent.
    func setHeading(_ h: Double?) {
        heading = h
        render()
    }

    /// Head yaw relative to the recentred forward direction, degrees, right-positive.
    /// AppModel passes `HeadYawSelector.choose(...)`: AirPods yaw, else front-camera yaw, else 0, and
    /// 0 while `recenterPending` (after a turn the old reference would double-count the body turn the
    /// heading already contains — AGENTS.md).
    func setHeadYaw(_ yaw: Double) {
        headYaw = yaw
        render()
    }

    /// Duck to `duckWhileSpeaking` while `SpeechQueue.isSpeaking` (pushed by AppModel's 10 Hz
    /// ticker, so ducking lags speech start by ≤ 100 ms).
    func setSpeaking(_ on: Bool) {
        speaking = on
        render()
    }

    // MARK: Render

    /// Apply the current inputs to the graph (main actor; called after every input change).
    ///
    /// Silent (volume 0, `renderedError` nil) unless running, enabled, in headphones, not
    /// `SpeechQueue.muted` (automation stays silent), with both a target and a heading. Otherwise: source at the absolute target bearing 10 m out, listener
    /// yawed to the absolute facing (heading + head yaw, negated because AVAudio yaw is CCW),
    /// error wrapped to (−180, 180], volume ramped linearly from 0 at `silentError` to 1 at
    /// `fullVolumeError`, then ducked while speaking.
    private func render() {
        guard isRunning, enabled, headphonesConnected, !SpeechQueue.muted, let θ = targetBearing, let h = heading else {
            silence()
            return
        }
        // Source at the absolute bearing, listener rotated to the absolute facing.
        let rad = θ * .pi / 180
        player.position = AVAudio3DPoint(x: Float(10 * sin(rad)), y: 0, z: Float(-10 * cos(rad)))
        let facing = h + headYaw
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: Float(-facing), pitch: 0, roll: 0)

        var err = (θ - facing).truncatingRemainder(dividingBy: 360)
        if err > 180 { err -= 360 }
        if err <= -180 { err += 360 }
        renderedError = err
        let magnitude = abs(err)
        var volume: Float = magnitude <= silentError ? 0
            : Float(min(1, (magnitude - silentError) / (fullVolumeError - silentError)))
        if speaking { volume *= duckWhileSpeaking }
        renderedVolume = volume
        player.volume = volume
    }

    /// Zero the published volume/error and, if the graph is running, the player volume. The loop
    /// keeps playing silently so un-silencing is instant (no reschedule).
    private func silence() {
        renderedVolume = 0
        renderedError = nil
        if isRunning { player.volume = 0 }
    }

    /// 40 ms decaying 1.2 kHz sine followed by silence to 400 ms — a soft, periodic tick.
    /// Peak amplitude 0.6, exponential decay e^(−90 t) (≈ −31 dB by the end of the click).
    /// Looped, the 400 ms buffer gives 2.5 clicks per second. `format` must be mono Float32
    /// (48 kHz standard format from `start()`); returns nil if the buffer cannot be allocated.
    private static func makeClick(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let total = AVAudioFrameCount(sampleRate * 0.4)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = total
        let clickFrames = Int(sampleRate * 0.04)
        for i in 0..<Int(total) {
            if i < clickFrames {
                let t = Double(i) / sampleRate
                let env = exp(-t * 90)                       // fast decay
                data[i] = Float(0.6 * env * sin(2 * .pi * 1200 * t))
            } else {
                data[i] = 0
            }
        }
        return buffer
    }
}
