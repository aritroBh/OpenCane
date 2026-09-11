//
//  DepthEngine.swift
//  CaneKit
//
//  Main-actor owner of the ARSession. Configures LiDAR depth + mesh classification, starts the
//  off-main `DepthFrameProcessor`, and republishes its reports as observable state for the UI
//  and for the cue router. Also owns the video-format choice and the thermal downgrade hook.
//
//  Threading / isolation (three contexts):
//    · main actor — this class: lifecycle (`start` / `pause` / `resume`), configuration, and
//      every published property. `ingest` runs here, fed by the consumer task.
//    · `processor.queue` ("canekit.depth", serial, userInteractive) — ARKit delivers *all*
//      `ARSessionDelegate` callbacks there because `session.delegateQueue` is set to it. Frames
//      go straight to `DepthFrameProcessor`; nothing main-actor is touched on that queue.
//    · `SessionObserver` — a `nonisolated` relay (AGENTS.md hard rule 1). It forwards frames
//      synchronously to the processor on the delegate queue and turns lifecycle events
//      (failure, interruption, tracking state) into Sendable values that hop to the main actor
//      with `Task { @MainActor in … }`. A main-actor delegate would be called off main.
//  Hand-off: the processor yields `LaneReport` values (Sendable) into a newest-only
//  `AsyncStream`; the consumer task (main actor) drains it, so a slow main thread drops stale
//  reports instead of queueing them.
//
//  Invariants: the delegate and consumer are wired exactly once (first `start()`); later starts
//  go through `resume()` and never reset tracking. Re-running the session (`setMeshClassification`)
//  costs ~1–2 s of depth, so it happens only on a thermal *change*. No audio: ARKit here never
//  touches the audio session.
//

import ARKit
import CaneKitLogic
import Observation
import UIKit

/// Main-actor owner of the LiDAR `ARSession` and its frame processor; publishes the latest
/// `LaneReport` plus debug state. Owned by `AppModel`, which wires `onReport` to its cue router.
@MainActor
@Observable
final class DepthEngine {

    // MARK: Published

    /// Latest report (~15 Hz).
    /// Written by `ingest` on the main actor. Also read directly by AppModel's heading gate
    /// (`report.isTrusted`) and the Mount card's camera-tilt row.
    private(set) var report = LaneReport()
    /// Human-readable session state for the header.
    /// Values include "Depth idle", "Waiting for depth…", "Depth OK", "Depth paused",
    /// "Depth resuming…", "Mesh classification off (thermal)", "AR error: …".
    private(set) var status = "Depth idle"
    /// Rolling frames-per-second of published reports.
    /// Computed over a 2 s window of report timestamps (should sit near `ProcessorSettings.maxRate`).
    private(set) var fps: Double = 0
    /// Count of reports ingested since launch (wrapping add; diagnostics only).
    private(set) var framesProcessed = 0
    /// True between a successful `start`/`resume` and `pause` or a session failure. Gates
    /// `start`/`resume`/`pause` and the thermal re-run; AppModel uses it to relax the heading
    /// gyro gate when depth is off.
    private(set) var isRunning = false
    /// Whether mesh classification is currently requested (thermal watchdog toggles it).
    private(set) var meshEnabled = true
    /// ARKit tracking state, e.g. "normal", "limited (excessive motion)".
    /// Short forms actually used: "normal", "not available", "limited (motion)",
    /// "limited (features)", "initializing", "relocalizing", "limited".
    private(set) var tracking = "—"

    /// Fired on the main actor for every report; the cue router hangs off this.
    /// Set once by `AppModel.start()` to `AppModel.handle(_:)` (haptics, watch mirror, speech).
    @ObservationIgnored var onReport: ((LaneReport) -> Void)?

    // MARK: Capability

    /// Device has LiDAR scene depth (iPhone Pro models). False → `start()` only sets a status.
    static let supportsDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    /// Device supports classified scene meshes (needed for obstacle names).
    static let supportsMesh = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)

    // MARK: Private

    /// The single AR session for the app's lifetime (never recreated).
    @ObservationIgnored private let session = ARSession()
    /// Off-main frame → `LaneReport` pipeline. Internal (not private) because `SceneDescriber`
    /// needs it for `jpegSnapshot` / `hasCameraFrame`.
    @ObservationIgnored let processor = DepthFrameProcessor()
    /// Last configuration run; non-nil means the session was started at least once.
    @ObservationIgnored private var configuration: ARWorldTrackingConfiguration?
    /// Main-actor task draining `processor.reports` into `ingest`.
    @ObservationIgnored private var consumer: Task<Void, Never>?
    /// Report timestamps from the last 2 s, for `fps`.
    @ObservationIgnored private var fpsWindow: [TimeInterval] = []
    /// Strong reference to the session delegate (ARSession holds its delegate weakly).
    @ObservationIgnored private var sessionObserver: SessionObserver?

    init() {}

    // MARK: Configuration

    /// Push the lane / gate settings into the processor (called by AppModel when settings change).
    /// Writes through the processor's `Mutex`, so it is safe while frames are being processed;
    /// the next frame picks it up. `portrait` rotates the depth grid for a portrait-mounted
    /// phone (and the snapshot JPEG); `mirror` swaps left/right lanes. Caller:
    /// `AppModel.pushDepthSettings()`.
    func apply(portrait: Bool, mirror: Bool, groundHazards: Bool = true) {
        processor.settings.withLock {
            $0.lane.rotateForPortrait = portrait
            $0.lane.mirrorLeftRight = mirror
            $0.groundHazardsEnabled = groundHazards
        }
    }

    // MARK: Lifecycle

    /// First start: build the configuration, install `SessionObserver` as delegate on the
    /// processor's queue, start the gyro, run with `.resetTracking` + `.removeExistingAnchors`,
    /// and start the report consumer. Later calls after `pause()` delegate to `resume()`.
    /// Without LiDAR it only sets `status` (the rest of the app runs without obstacle cues).
    /// Triggers the camera permission prompt on first run. Caller: `AppModel.start()`.
    func start() {
        guard !isRunning else { return }
        // A second `start()` after `pause()` must not re-wire the delegate or add a consumer.
        if configuration != nil { resume(); return }
        guard Self.supportsDepth else {
            status = "No LiDAR / sceneDepth on this device"
            return
        }
        let config = makeConfiguration(mesh: meshEnabled)
        configuration = config

        // The processor is the frame delegate; a tiny main-actor observer gets the lifecycle calls.
        let observer = SessionObserver(engine: self, frames: processor)
        sessionObserver = observer
        session.delegate = observer
        session.delegateQueue = processor.queue

        processor.startMotion()
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
        status = "Waiting for depth…"
        startConsumer()
    }

    /// Pause ARKit and the gyro (battery + heat) while keeping the world map, delegate and
    /// consumer in place. Caller: `AppModel.scenePhaseChanged(.background)` — ARKit would pause
    /// itself, but the gyro would not.
    func pause() {
        guard isRunning else { return }
        session.pause()
        processor.stopMotion()
        processor.dropLatestImage()     // a paused frame is a stale frame: never describe it later
        isRunning = false
        status = "Depth paused"
    }

    /// Re-run the last configuration *without* resetting tracking (keeps anchors / mesh), restart
    /// the gyro. Falls through to `start()` if the session was never started. Caller:
    /// `AppModel.scenePhaseChanged(.active)` and `start()` itself.
    func resume() {
        guard !isRunning else { return }
        guard let configuration else { start(); return }
        processor.startMotion()
        session.run(configuration)               // no reset: keep the world map
        isRunning = true
        status = "Depth resuming…"
    }

    /// Thermal watchdog hook. Re-running the session costs ~1–2 s of depth, so callers only
    /// toggle on a thermal *change*, never per frame.
    ///
    /// Flips `meshEnabled`, tells the processor to stop/start its mesh lookup immediately (so no
    /// stale `centerHit` is published while the new configuration spins up), and — if running —
    /// re-runs the session with the new configuration (no tracking reset). Caller:
    /// `AppModel.updateThermal()` (off at `.serious` / `.critical`, back on when it cools).
    func setMeshClassification(_ on: Bool) {
        guard on != meshEnabled else { return }
        meshEnabled = on
        processor.settings.withLock { $0.meshLookupEnabled = on }
        guard isRunning else { return }
        let config = makeConfiguration(mesh: on)
        configuration = config
        session.run(config)
        status = on ? "Mesh classification on" : "Mesh classification off (thermal)"
    }

    /// World-tracking configuration: scene depth (raw + smoothed), optional classified mesh
    /// (only where supported), gravity-aligned world (y up, so "head height" is meaningful), no
    /// plane detection, and the lowest-resolution ≥ 30 fps video format to save power.
    /// - Parameter mesh: request `.meshWithClassification` (ignored when unsupported).
    private func makeConfiguration(mesh: Bool) -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        // Raw + smoothed depth: smoothed for the lanes (less flicker), raw as the fallback.
        config.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        if mesh, Self.supportsMesh {
            config.sceneReconstruction = .meshWithClassification
        }
        config.worldAlignment = .gravity
        config.planeDetection = []                       // we never use planes; saves CPU
        config.isAutoFocusEnabled = true
        // Lowest-resolution colour stream at ≥ 30 fps: depth resolution is fixed at 256×192
        // regardless, and the colour frame only feeds the occasional JPEG snapshot.
        if let low = ARWorldTrackingConfiguration.supportedVideoFormats.last(where: { $0.framesPerSecond >= 30 }) {
            config.videoFormat = low
        }
        return config
    }

    // MARK: Consumer

    /// Start the single main-actor task that drains `processor.reports`. The task inherits the
    /// main actor, so `ingest` runs on main; it lives for the app's lifetime (the stream is never
    /// finished) and survives pause/resume. Called once from the first `start()`.
    private func startConsumer() {
        consumer?.cancel()
        consumer = Task { [weak self] in
            guard let self else { return }
            for await r in processor.reports {
                if Task.isCancelled { break }
                self.ingest(r)
            }
        }
    }

    /// Publish one report (main actor): store it, update the 2 s fps window, promote the status
    /// to "Depth OK" on the first real depth after a start/resume, then call `onReport`.
    private func ingest(_ r: LaneReport) {
        report = r
        framesProcessed &+= 1
        fpsWindow.append(r.timestamp)
        while let first = fpsWindow.first, r.timestamp - first > 2 { fpsWindow.removeFirst() }
        if fpsWindow.count > 1, let first = fpsWindow.first {
            fps = Double(fpsWindow.count - 1) / max(0.001, r.timestamp - first)
        }
        if r.depthAvailable, status == "Waiting for depth…" || status == "Depth resuming…" {
            status = "Depth OK"
        }
        onReport?(r)
    }

    // MARK: Session lifecycle (called by SessionObserver on the main actor)

    /// `code` is the `ARError.Code` raw value (e.g. 103 = camera unauthorized) so the UI can tell
    /// a permissions problem from a sensor failure.
    /// Sets `isRunning = false` so a later `start()`/`resume()` can re-run the session; does not
    /// stop the gyro. Reached from `SessionObserver` via a main-actor hop.
    fileprivate func sessionFailed(code: Int, message: String) {
        let hint: String
        switch ARError.Code(rawValue: code) {
        case .cameraUnauthorized: hint = "Camera access denied — enable it in Settings"
        case .sensorUnavailable, .sensorFailed: hint = "LiDAR sensor unavailable"
        case .unsupportedConfiguration: hint = "Unsupported AR configuration"
        default: hint = message
        }
        status = "AR error: \(hint)"
        isRunning = false
    }

    /// ARKit interruption begin/end (camera taken by another app, backgrounding). Status only:
    /// ARKit resumes the session by itself; `isRunning` is left unchanged.
    fileprivate func sessionInterrupted(_ interrupted: Bool) {
        status = interrupted ? "AR interrupted" : "AR resumed"
    }

    /// Map `ARCamera.TrackingState` (a Sendable enum, passed by value across the hop) to the short
    /// debug string in `tracking`.
    fileprivate func trackingChanged(_ state: ARCamera.TrackingState) {
        switch state {
        case .normal: tracking = "normal"
        case .notAvailable: tracking = "not available"
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: tracking = "limited (motion)"
            case .insufficientFeatures: tracking = "limited (features)"
            case .initializing: tracking = "initializing"
            case .relocalizing: tracking = "relocalizing"
            @unknown default: tracking = "limited"
            }
        }
    }
}

/// Splits the ARSessionDelegate: frames go to the processor on its queue, lifecycle events hop
/// to the main-actor engine. Kept tiny and `nonisolated` so ARKit can call it from any thread.
///
/// Every method runs on `DepthFrameProcessor.queue` (the session's `delegateQueue`). Why not
/// make `DepthEngine` the delegate: it is main-actor isolated, and ARKit would call it off main.
/// Why not make the processor handle lifecycle too: it must never touch main-actor state. So
/// this relay extracts Sendable values (`Int`, `String`, `ARCamera.TrackingState`) and hops
/// with `Task { @MainActor in … }`; the `ARFrame` (not Sendable) never leaves the queue.
/// `@unchecked Sendable` is sound: both stored properties are immutable after init and
/// `engine` is only dereferenced on the main actor inside the hop.
nonisolated private final class SessionObserver: NSObject, ARSessionDelegate, @unchecked Sendable {
    /// Weak so the relay never keeps the engine alive; read only inside main-actor hops.
    private weak var engine: DepthEngine?
    /// The processor that receives frames synchronously on the delegate queue.
    private let frames: DepthFrameProcessor

    init(engine: DepthEngine, frames: DepthFrameProcessor) {
        self.engine = engine
        self.frames = frames
    }

    /// Hot path (~60 Hz): forward synchronously, no hop, no allocation.
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frames.session(session, didUpdate: frame)
    }

    /// Session failed (permissions, sensor). Hops code + message to `DepthEngine.sessionFailed`.
    func session(_ session: ARSession, didFailWithError error: Error) {
        // `any Error` is not Sendable; carry the two values the engine needs.
        let code = (error as NSError).code
        let message = error.localizedDescription
        Task { @MainActor [engine] in engine?.sessionFailed(code: code, message: message) }
    }

    /// Camera lost (another app, background) → status "AR interrupted" on main.
    func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [engine] in engine?.sessionInterrupted(true) }
    }

    /// Camera back → status "AR resumed" on main.
    func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor [engine] in engine?.sessionInterrupted(false) }
    }

    /// Tracking quality changed; only the value-type state crosses to main (`ARCamera` does not).
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let state = camera.trackingState
        Task { @MainActor [engine] in engine?.trackingChanged(state) }
    }
}
