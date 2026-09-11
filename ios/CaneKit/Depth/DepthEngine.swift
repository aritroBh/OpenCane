//
//  DepthEngine.swift
//  CaneKit
//
//  Main-actor owner of the ARSession. Configures LiDAR depth + mesh classification, starts the
//  off-main `DepthFrameProcessor`, and republishes its reports as observable state for the UI
//  and for the cue router. Also owns the video-format choice and the thermal downgrade hook.
//

import ARKit
import CaneKitLogic
import Observation
import UIKit

@MainActor
@Observable
final class DepthEngine {

    // MARK: Published

    /// Latest report (~15 Hz).
    private(set) var report = LaneReport()
    /// Human-readable session state for the header.
    private(set) var status = "Depth idle"
    /// Rolling frames-per-second of published reports.
    private(set) var fps: Double = 0
    private(set) var framesProcessed = 0
    private(set) var isRunning = false
    /// Whether mesh classification is currently requested (thermal watchdog toggles it).
    private(set) var meshEnabled = true
    /// ARKit tracking state, e.g. "normal", "limited (excessive motion)".
    private(set) var tracking = "—"

    /// Fired on the main actor for every report; the cue router hangs off this.
    @ObservationIgnored var onReport: ((LaneReport) -> Void)?

    // MARK: Capability

    static let supportsDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    static let supportsMesh = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)

    // MARK: Private

    @ObservationIgnored private let session = ARSession()
    @ObservationIgnored let processor = DepthFrameProcessor()
    @ObservationIgnored private var configuration: ARWorldTrackingConfiguration?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var fpsWindow: [TimeInterval] = []
    @ObservationIgnored private var sessionObserver: SessionObserver?

    init() {}

    // MARK: Configuration

    /// Push the lane / gate settings into the processor (called by AppModel when settings change).
    func apply(portrait: Bool, mirror: Bool) {
        processor.settings.withLock {
            $0.lane.rotateForPortrait = portrait
            $0.lane.mirrorLeftRight = mirror
        }
    }

    // MARK: Lifecycle

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

    func pause() {
        guard isRunning else { return }
        session.pause()
        processor.stopMotion()
        isRunning = false
        status = "Depth paused"
    }

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

    fileprivate func sessionInterrupted(_ interrupted: Bool) {
        status = interrupted ? "AR interrupted" : "AR resumed"
    }

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
nonisolated private final class SessionObserver: NSObject, ARSessionDelegate, @unchecked Sendable {
    private weak var engine: DepthEngine?
    private let frames: DepthFrameProcessor

    init(engine: DepthEngine, frames: DepthFrameProcessor) {
        self.engine = engine
        self.frames = frames
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frames.session(session, didUpdate: frame)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        // `any Error` is not Sendable; carry the two values the engine needs.
        let code = (error as NSError).code
        let message = error.localizedDescription
        Task { @MainActor [engine] in engine?.sessionFailed(code: code, message: message) }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [engine] in engine?.sessionInterrupted(true) }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor [engine] in engine?.sessionInterrupted(false) }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let state = camera.trackingState
        Task { @MainActor [engine] in engine?.trackingChanged(state) }
    }
}
