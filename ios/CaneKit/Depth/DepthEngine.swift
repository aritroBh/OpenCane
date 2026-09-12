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
//  Front camera: with `faceTrackingEnabled` the same session also runs the TrueDepth camera
//  (`userFaceTrackingEnabled`), which adds an `ARFaceAnchor` for the walker's own head and changes
//  nothing about the rear camera or LiDAR — measured on the phone, not assumed (`SensorProbe`,
//  trip-log records `probe_a0_world_baseline` / `probe_a_world_plus_face`). ARKit delivers exactly
//  one `capturedImage` per frame and it is the rear camera's, so there is no front-camera *picture*
//  to show; the anchor's yaw goes to `onFaceYaw` and drives the beacon when there are no AirPods.
//
//  Invariants: the delegate and consumer are wired exactly once (first `start()`); later starts
//  go through `resume()` and never reset tracking. Re-running the session (`setMeshClassification`)
//  costs ~1–2 s of depth, so it happens only on a thermal *change*. No audio: ARKit here never
//  touches the audio session. The session is exposed read-only (`arSession`) so the Hazards card's
//  `LiveCameraView` can draw it; nothing outside this class runs, pauses or delegates it.
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

    /// The pure route-start freshness gate. `AppModel` observes this while a route request is
    /// queued; after a route starts it is reset to idle and ordinary depth interruptions continue
    /// to be represented by `status` / `report` as before.
    private(set) var readinessState: DepthReadinessState = .idle

    /// Fired on the main actor for every report; the cue router hangs off this.
    /// Set once by `AppModel.start()` to `AppModel.handle(_:)` (haptics, watch mirror, speech).
    @ObservationIgnored var onReport: ((LaneReport) -> Void)?

    /// Fired on the main actor at most every `FaceYawTracker.publishInterval` with the walker's
    /// head yaw in ARKit's world frame (degrees) and the ARKit clock of the frame it came from.
    /// Only ever called while `faceTrackingEnabled` — that is, while the front (TrueDepth) camera
    /// runs alongside the back camera's LiDAR. Set once by `AppModel.start()` to
    /// `AppModel.faceHead.ingest(worldYawDeg:now:)`.
    @ObservationIgnored var onFaceYaw: ((Double, TimeInterval) -> Void)?

    /// Main-actor callback for route-start interlock transitions.
    @ObservationIgnored var onReadinessChanged: ((DepthReadinessState) -> Void)?

    /// True while an `ARFaceAnchor` has been seen at all this session (any age). Only for the
    /// Hazards card's "the front camera is live" line; freshness is `FaceHeadPose.isTracking`.
    private(set) var faceAnchorSeen = false

    // MARK: Capability

    /// Device has LiDAR scene depth (iPhone Pro models). False → `start()` only sets a status.
    static let supportsDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    /// Device supports classified scene meshes (needed for obstacle names).
    static let supportsMesh = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)

    // MARK: Private

    /// The single AR session for the app's lifetime (never recreated).
    @ObservationIgnored private let session = ARSession()

    /// Read-only access to the app's one `ARSession`, for display only: `LiveCameraView` (the
    /// Hazards card's "Live camera view") hands it to an `ARSCNView`, which draws ARKit's own
    /// camera frames on the GPU at the camera's rate. Callers must never `run`/`pause` it or set
    /// its `delegate` / `delegateQueue` — this engine owns the lifecycle and `SessionObserver`
    /// must stay the delegate. Assigning it to `ARSCNView.session` leaves the delegate and queue
    /// untouched (probed in the iOS 27 simulator, see LiveCameraView.swift).
    var arSession: ARSession { session }
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
    /// Timestamp of the last report seen before a readiness window began. A report buffered before
    /// a two-camera stop must never count as one of the fresh post-reconfiguration frames.
    @ObservationIgnored private var readinessBaselineFrameTime: TimeInterval?
    /// Sequence boundary captured from the processor queue at the transition. This is stronger
    /// than the consumed report timestamp because `reports` buffers one pre-transition value.
    @ObservationIgnored private var readinessBaselineFrameSequence: Int?
    /// Published-report continuity across the readiness boundary. A gap means the newest-only
    /// stream dropped at least one published frame, so the consecutive run restarts conservatively.
    @ObservationIgnored private var readinessContinuity = DepthFrameContinuity()
    /// Pure state machine; all mutations happen on the main actor.
    @ObservationIgnored private var readiness = DepthReadiness()

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

    // MARK: Route-start readiness

    /// Begin the bounded freshness window used by `AppModel` before a route starts. The caller
    /// supplies wall-clock uptime for the timeout; frame timestamps remain ARKit's own clock.
    /// Baseline timestamp and processor sequence are retained so a buffered pre-transition report
    /// cannot satisfy the gate after two-camera teardown or another AR session reconfiguration.
    func beginReadiness(at now: TimeInterval) {
        readinessBaselineFrameTime = report.depthAvailable ? report.timestamp : nil
        readinessBaselineFrameSequence = processor.latestPublishedSequence()
        readinessContinuity.begin(after: readinessBaselineFrameSequence)
        publishReadiness(readiness.begin(at: now))
    }

    /// Poll the readiness timeout when no frame has arrived.
    func pollReadiness(at now: TimeInterval) {
        publishReadiness(readiness.poll(at: now))
    }

    /// Cancel a queued route request and return the gate to idle.
    func cancelReadiness() {
        readinessBaselineFrameTime = nil
        readinessBaselineFrameSequence = nil
        readinessContinuity = DepthFrameContinuity()
        publishReadiness(readiness.cancel())
    }

    /// Invalidate the current freshness window after an AR interruption, pause/resume or session
    /// reconfiguration. This is a no-op when no route-start request is waiting.
    private func invalidateReadiness(at now: TimeInterval) {
        guard readiness.state != .idle else { return }
        readinessBaselineFrameTime = report.depthAvailable ? report.timestamp : nil
        readinessBaselineFrameSequence = processor.latestPublishedSequence()
        readinessContinuity.begin(after: readinessBaselineFrameSequence)
        publishReadiness(readiness.invalidate(at: now))
    }

    /// Publish only actual state changes; the route-start adapter does not need a callback for each
    /// warming frame, while the observable state remains useful to the UI and diagnostics.
    private func publishReadiness(_ state: DepthReadinessState) {
        guard readinessState != state else { return }
        readinessState = state
        onReadinessChanged?(state)
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
        // Complete any callback already in flight before capturing the paused-session boundary.
        // A newest-only report yielded just before the pause must never satisfy a post-resume gate.
        processor.synchronize()
        processor.stopMotion()
        processor.dropLatestImage()     // a paused frame is a stale frame: never describe it later
        isRunning = false
        // A paused engine publishes no reports, so the last rate is not the current rate: leaving
        // it at 30 made the "both cameras" trip-log record read as though depth were still
        // flowing while ARKit was stopped. Zero it, and clear the window so the first rate after
        // `resume()` is not averaged across the pause.
        fps = 0
        fpsWindow.removeAll(keepingCapacity: true)
        status = "Depth paused"
        invalidateReadiness(at: ProcessInfo.processInfo.systemUptime)
    }

    /// Re-run the configuration *without* resetting tracking (keeps anchors / mesh), restart the
    /// gyro. Falls through to `start()` if the session was never started. Caller:
    /// `AppModel.scenePhaseChanged(.active)` and `start()` itself.
    ///
    /// ⚠ The configuration is rebuilt from the *current* settings, not replayed from the stored
    /// one. `setFaceTracking`, `setMeshClassification` and `setHighFrameRate` all end in
    /// `guard isRunning else { return }`: while the session is paused they record the flag and
    /// skip the `session.run`, so the stored configuration still describes the world as it was
    /// before the walker changed anything. Replaying it brought the session back *without* the
    /// feature while every flag, every trip-log field and every UI readout said it was on. Not
    /// hypothetical: on 2026-09-12 the walker turned on "Head tracking without AirPods"
    /// (`canekit-2026-09-12T02-40-53Z.jsonl`, t=17.583) while "Both cameras" had ARKit paused
    /// (t=5.772), so `userFaceTrackingEnabled` was requested and never actually run in that
    /// process — the first session that really ran with it was the next cold launch, which died
    /// inside the ARKit warm-up. A settings change has to reach ARKit at the next resume, or it
    /// reaches it later somewhere nobody is watching. Rebuilding costs one value object, and
    /// `session.run` without `.resetTracking` still keeps the world map.
    func resume() {
        guard !isRunning else { return }
        guard configuration != nil else { start(); return }
        // Drain the old session's delegate tail before taking a new readiness boundary. Without
        // this, a report published during the pause can look like post-resume evidence.
        processor.synchronize()
        invalidateReadiness(at: ProcessInfo.processInfo.systemUptime)
        let config = makeConfiguration(mesh: meshEnabled)
        configuration = config
        processor.startMotion()
        session.run(config)                      // no reset: keep the world map
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
    /// Camera at 60 fps (Mount card "60 fps camera (warmer)", off by default). Cues use 30 depth
    /// reports/s either way; 60 fps doubles the camera's cost and heat for a smoother live view
    /// and slightly fresher frames. Muse + Antigravity: untested over a 20-minute walk, so it
    /// ships off until stress-plan D14 passes with it on. Re-runs the session (~1-2 s of depth).
    private(set) var highFrameRate = false

    func setHighFrameRate(_ on: Bool) {
        guard on != highFrameRate else { return }
        highFrameRate = on
        // In high-rate mode every camera frame is published, so an untrusted 60 Hz frame cannot
        // be hidden between two qualifying readiness reports. The normal 30 Hz cap remains the
        // shipped low-power path.
        let rate = CameraRate.framesPerSecond(highFrameRate: on)
        processor.settings.withLock { $0.maxRate = Double(rate) }
        guard isRunning else { return }
        session.pause()
        processor.dropLatestImage()
        processor.synchronize()
        invalidateReadiness(at: ProcessInfo.processInfo.systemUptime)
        let config = makeConfiguration(mesh: meshEnabled)
        configuration = config
        session.run(config)
    }

    /// Whether the front (TrueDepth) camera also tracks the walker's face, for head yaw without
    /// AirPods (`ARWorldTrackingConfiguration.userFaceTrackingEnabled`).
    ///
    /// Measured on the iPhone 17 Pro Max (2026-09-11, `probe_a_world_plus_face` in the trip log):
    /// with `userFaceTrackingEnabled = true`, LiDAR `sceneDepth` keeps arriving on every frame and
    /// `capturedImage` is still the **rear** camera's 1920×1440 — the front camera contributes an
    /// `ARFaceAnchor` and nothing else. See `SensorProbe` for the full measurement.
    /// Off by default (AGENTS.md rule 6: anything new and untuned ships off).
    private(set) var faceTrackingEnabled = false

    /// Turn the front-camera face tracking on or off. Re-runs the session (~1–2 s of depth), so
    /// callers flip it on a *setting change*, never per frame — exactly like
    /// `setMeshClassification`. A no-op where the phone cannot do it
    /// (`supportsFrontCameraWithLiDAR`), so the setting can be on harmlessly in the simulator.
    /// Caller: `AppModel.faceHeadTrackingEnabled`'s `didSet`.
    func setFaceTracking(_ on: Bool) {
        let wanted = on && Self.supportsFrontCameraWithLiDAR
        guard wanted != faceTrackingEnabled else { return }
        faceTrackingEnabled = wanted
        if !wanted { faceAnchorSeen = false }
        guard isRunning else { return }
        session.pause()
        processor.dropLatestImage()
        processor.synchronize()
        invalidateReadiness(at: ProcessInfo.processInfo.systemUptime)
        let config = makeConfiguration(mesh: meshEnabled)
        configuration = config
        session.run(config)
    }

    func setMeshClassification(_ on: Bool) {
        guard on != meshEnabled else { return }
        meshEnabled = on
        processor.settings.withLock { $0.meshLookupEnabled = on }
        guard isRunning else { return }
        session.pause()
        processor.dropLatestImage()
        processor.synchronize()
        invalidateReadiness(at: ProcessInfo.processInfo.systemUptime)
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
        // The front (TrueDepth) camera, when the walker asked for head tracking without AirPods.
        // It adds an `ARFaceAnchor` and changes nothing about the rear camera or LiDAR (measured:
        // `probe_a_world_plus_face`). `supportsUserFaceTracking` is false in the simulator, so the
        // flag is simply never set there.
        if faceTrackingEnabled, Self.supportsFrontCameraWithLiDAR {
            config.userFaceTrackingEnabled = true
        }
        // Measured on the iPhone 17 Pro Max (2026-09-11): world tracking with LiDAR exposes only
        // the 1x wide camera, up to 60 fps (no ultra-wide, no 120). Use the full 4:3 frame (widest
        // view; the sign-range numbers assume it) at 30 fps by default, 60 when `highFrameRate`.
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        let fourThree = { (f: ARConfiguration.VideoFormat) in
            abs(f.imageResolution.width / f.imageResolution.height - 4.0 / 3.0) < 0.01
        }
        let fps = CameraRate.framesPerSecond(highFrameRate: highFrameRate)   // pinned in LiveViewTests
        if let best = formats.filter({ $0.framesPerSecond == fps && fourThree($0) })
            .min(by: { $0.imageResolution.width < $1.imageResolution.width })
            ?? formats.first(where: { $0.framesPerSecond >= fps })
            ?? formats.last(where: { $0.framesPerSecond >= 30 }) {
            config.videoFormat = best
        }
        chosenFormat = Self.describe(config.videoFormat)
        return config
    }

    /// The video format the session runs ("wide 1920x1440 @60"), for the trip log's `start` event.
    private(set) var chosenFormat = ""

    /// Every video format ARKit world tracking offers on this device, e.g. "wide 1920x1440 @60",
    /// "ultrawide 1920x1440 @60" — so which cameras / frame rates can run *with* LiDAR is measured
    /// on the phone, not assumed. Logged once at start.
    static var supportedFormats: [String] {
        ARWorldTrackingConfiguration.supportedVideoFormats.map(describe)
    }

    /// True when world tracking can also run the front (TrueDepth) camera for face tracking.
    static var supportsFrontCameraWithLiDAR: Bool { ARWorldTrackingConfiguration.supportsUserFaceTracking }

    private static func describe(_ f: ARConfiguration.VideoFormat) -> String {
        let type: String
        switch f.captureDeviceType {
        case .builtInUltraWideCamera: type = "ultrawide"
        case .builtInWideAngleCamera: type = "wide"
        case .builtInTelephotoCamera: type = "tele"
        default: type = "\(f.captureDeviceType.rawValue)"
        }
        return "\(type) \(Int(f.imageResolution.width))x\(Int(f.imageResolution.height)) @\(f.framesPerSecond)"
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
        if readiness.state == .warming,
           readinessBaselineFrameTime.map({ r.timestamp > $0 }) ?? true,
           readinessBaselineFrameSequence.map({ r.frameSequence > $0 }) ?? true {
            let now = ProcessInfo.processInfo.systemUptime
            let contiguous = readinessContinuity.accepts(r.frameSequence)
            if !contiguous {
                // `reports` intentionally buffers only the newest value. If delivery skipped any
                // published report, one of those unseen frames may have been limited or missing
                // depth; never call the values on either side consecutive evidence.
                publishReadiness(readiness.invalidate(at: now))
            }
            if contiguous {
                publishReadiness(readiness.frame(at: now,
                                                 trackingNormal: r.trackingNormal,
                                                 sceneDepthAvailable: r.depthAvailable,
                                                 reportTrusted: r.isTrusted))
            }
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
        invalidateReadiness(at: ProcessInfo.processInfo.systemUptime)
    }

    /// One throttled face-yaw sample from the front camera, already reduced to a world yaw by
    /// `SessionObserver` (which does the trigonometry on the delegate queue so no ARKit object
    /// crosses to main). Publishes `faceAnchorSeen` and forwards to `onFaceYaw`.
    /// - Parameters:
    ///   - worldYawDeg: `FaceYawGeometry.worldYawDegrees` of the anchor's forward axis.
    ///   - now: `ARFrame.timestamp` of the newest frame (the ARKit clock).
    fileprivate func faceYawUpdated(_ worldYawDeg: Double, now: TimeInterval) {
        faceAnchorSeen = true
        onFaceYaw?(worldYawDeg, now)
    }

    /// ARKit interruption begin/end (camera taken by another app, backgrounding). Status only:
    /// ARKit resumes the session by itself; `isRunning` is left unchanged.
    fileprivate func sessionInterrupted(_ interrupted: Bool) {
        status = interrupted ? "AR interrupted" : "AR resumed"
        if interrupted { invalidateReadiness(at: ProcessInfo.processInfo.systemUptime) }
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
/// `@unchecked Sendable` is sound: `engine` and `frames` are immutable after init and `engine` is
/// only dereferenced on the main actor inside the hop; the two mutable fields (`lastFrameTime`,
/// `lastFaceHop`) are written and read **only** on the session's serial `delegateQueue`, the same
/// "queue-only" discipline `DepthFrameProcessor` documents for its own fields. Nothing else in the
/// app touches this object after `DepthEngine.start()` installs it.
nonisolated private final class SessionObserver: NSObject, ARSessionDelegate, @unchecked Sendable {
    /// Weak so the relay never keeps the engine alive; read only inside main-actor hops.
    private weak var engine: DepthEngine?
    /// The processor that receives frames synchronously on the delegate queue.
    private let frames: DepthFrameProcessor

    init(engine: DepthEngine, frames: DepthFrameProcessor) {
        self.engine = engine
        self.frames = frames
    }

    /// Newest `ARFrame.timestamp`, so a face anchor can be stamped with the ARKit clock (the
    /// anchor callbacks carry no time of their own, and `session.currentFrame` is not documented
    /// as safe to read off the delegate queue).
    /// Queue-only: written and read on `DepthFrameProcessor.queue`, which is serial — the same
    /// discipline the processor's own "queue-only" fields use, so no lock is needed.
    private var lastFrameTime: TimeInterval = 0
    /// ARKit clock of the last face yaw hopped to the main actor (queue-only), for the throttle.
    private var lastFaceHop: TimeInterval = 0

    /// Hot path (~60 Hz): forward synchronously, no hop, no allocation.
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        lastFrameTime = frame.timestamp
        frames.session(session, didUpdate: frame)
    }

    /// Anchors added — the walker's `ARFaceAnchor` arrives here first (and, with scene
    /// reconstruction on, so do hundreds of `ARMeshAnchor`s, which `faceYaw` ignores).
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { faceYaw(anchors) }

    /// Anchors updated (~camera rate while a face is in view).
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { faceYaw(anchors) }

    /// Turn a face anchor into a world yaw and hop it to the main actor, at most every
    /// `FaceYawTracker.publishInterval` (the beacon is rendered by a 10 Hz ticker; hopping at the
    /// camera's rate would be main-thread work nobody reads).
    ///
    /// The trigonometry happens here, on the delegate queue, so only a `Double` crosses to main
    /// and the `ARFaceAnchor` never leaves the queue (AGENTS.md hard rule 1). `columns.2` is the
    /// face's +Z axis, which points out of the face — the direction the walker is looking.
    private func faceYaw(_ anchors: [ARAnchor]) {
        guard let face = anchors.lazy.compactMap({ $0 as? ARFaceAnchor }).first else { return }
        let now = lastFrameTime
        guard now - lastFaceHop >= FaceYawTracker.publishInterval else { return }
        let forward = face.transform.columns.2
        guard let yaw = FaceYawGeometry.worldYawDegrees(forwardX: Double(forward.x),
                                                       forwardZ: Double(forward.z)) else { return }
        lastFaceHop = now
        Task { @MainActor [engine] in engine?.faceYawUpdated(yaw, now: now) }
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
