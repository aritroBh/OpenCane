//
//  DualCameraSession.swift
//  CaneKit
//
//  "Both cameras": the front (selfie) camera and the back camera on screen at the same time, for a
//  sighted spotter and the demo video.
//
//  Why it is a separate session and not part of the AR session. ARKit can **never** hand this app
//  two camera images. Apple DTS, developer forums thread 677731: "There can only be one running
//  capture session at a time, ARKit requires a running capture session, and there is no
//  ARConfiguration that will enable you to receive both the front and rear camera image, so the
//  functionality that you are looking for is not possible." The structure agrees: `ARFrame` has
//  exactly one `capturedImage`, and `userFaceTrackingEnabled` adds the front camera only as an
//  `ARFaceAnchor` (Apple: "ARKit 3 and later provide simultaneous anchors from all cameras … but
//  you still must choose one camera feed to show to the user at a time"). Measured on this phone
//  (`SensorProbe`, trip-log `probe_capabilities` / `probe_a_world_plus_face`): the only
//  `CVPixelBuffer` property on `ARFrame` carrying a camera picture is `capturedImage`, and with
//  face tracking on it is still the rear camera's 1920×1440. So two pictures require
//  `AVCaptureMultiCamSession`, which is a different capture pipeline from ARKit's — and pausing
//  ARKit is therefore the *only* way to show both, which is exactly what this class and
//  `AppModel.setBothCameras` do.
//
//  Why ARKit is paused. Measured (`probe_c_multicam`): starting a multi-cam session while the AR
//  session ran delivered 246 front and 244 back sample buffers — and ARKit collapsed from ~30
//  frames per 4 s window to **8**, with an interruption. Both pipelines want the same cameras and
//  the same ISP budget. Leaving ARKit "running" while it is starved would be the worst outcome for
//  a blind walker: the obstacle lanes would look alive and be two seconds stale. So this class
//  requires the caller to pause ARKit, and `AppModel` pauses it, **says so out loud**, and resumes
//  and says so again when the mode goes off.
//
//  ⚠ Why there is no `AVCaptureVideoPreviewLayer` here, even though it is the obvious API for a
//  two-up preview. Apple Developer Forums thread 742501 reports LiDAR depth delivery becoming
//  unreliable — stopping after 4–5 frames about half the time — once a preview layer is added to a
//  session that is also producing depth. This app's entire safety channel is LiDAR depth, and the
//  back camera borrowed here is the same camera ARKit takes back afterwards, so a preview layer is
//  not a risk worth running for a spotter feature. Both feeds are therefore rendered from
//  `AVCaptureVideoDataOutput` sample buffers into `AVSampleBufferDisplayLayer`s (GPU path, no
//  per-frame CPU image conversion). It also buys something a preview layer could not: a **count of
//  frames that actually arrived** per camera, which is the evidence in the trip log that both
//  cameras really ran.
//
//  Owner: `AppModel.bothCameras` (one instance). Driven only by the Hazards card's "Both cameras
//  (pauses obstacle detection)" switch, which is **off by default and never persisted** — no
//  launch can ever come up with the safety path suspended. Refused outright while a route is
//  running.
//
//  Threading / isolation: `@MainActor @Observable`. The two `AVSampleBufferDisplayLayer`s are
//  `CALayer`s and belong on the main actor, which is where `BothCamerasView` attaches them and
//  where every frame is enqueued. `AVCaptureVideoDataOutput` calls its delegate on a capture
//  queue, so the delegate is a `nonisolated` relay (`DualCameraFrameRelay`) that hops each buffer
//  to main inside a `CaptureHandoff` and drops frames while one is already in flight — the
//  back-pressure that keeps a busy main thread from queueing stale video (AGENTS.md hard rule 1).
//  `startRunning()` / `stopRunning()` block, so they are pushed to a global queue through the same
//  handoff. The interruption / runtime-error notifications are observed with `queue: .main`, so
//  `MainActor.assumeIsolated` is legal there.
//
//  Key invariants:
//    · `start()` never runs while ARKit is running: `AppModel` pauses depth first. This class does
//      not touch the AR session itself — one owner per session (`DepthEngine`).
//    · Unsupported hardware degrades to the back camera alone plus a spoken/visible message; it
//      never silently shows one feed as if it were two.
//    · `stop()` always tears the session down, even after a failed `start()`.
//    · No `AVCaptureVideoPreviewLayer`, ever (see above).
//

import AVFoundation
import CaneKitLogic
import CoreMedia
import Foundation
import Observation
import Synchronization

/// Front + back camera preview at the same time, via `AVCaptureMultiCamSession`, rendered from
/// video data output buffers. The AR session must be paused by the caller for the duration.
@MainActor
@Observable
final class DualCameraSession {

    // MARK: Capability

    /// Whether this phone can run two cameras at once at all (`AVCaptureMultiCamSession`).
    /// Measured true on the iPhone 17 Pro Max (trip-log `probe_capabilities`). False on the
    /// simulator, where the switch is disabled and the card says so.
    static let isSupported = AVCaptureMultiCamSession.isMultiCamSupported

    // MARK: Published

    /// True once the capture session is running.
    private(set) var isRunning = false
    /// True when the back camera's feed is connected (it always should be).
    private(set) var backConnected = false
    /// True when the **front** camera's feed is connected — the thing the owner asked to see.
    /// False on a phone without multi-cam support, where only the back feed is shown.
    private(set) var frontConnected = false
    /// Why the mode is degraded or dead: no multi-cam, a device error, an interruption. Shown on
    /// the Hazards card in the warning colour and spoken by `AppModel`; never cleared silently.
    private(set) var lastError: String?
    /// `AVCaptureMultiCamSession.hardwareCost` (0…1) at the last reading: "the percentage of the
    /// hardware in use". Apple: above 1.0 the session cannot run and posts a runtime error. Logged
    /// so the two-camera cost is a number, not an impression.
    private(set) var hardwareCost: Float = 0
    /// `systemPressureCost` at the last reading, same purpose.
    private(set) var systemPressureCost: Float = 0
    /// True when `hardwareCost` came in over budget and the frame rate was cut to
    /// `MultiCamCost.reducedFramesPerSecond` to make the session runnable (Apple's documented
    /// remedy). Logged; the walker is not told, because nothing safety-related reads these frames.
    private(set) var frameRateReduced = false

    // MARK: Picture layers

    /// The back camera's picture, attached by `BothCamerasView` as the large layer, fed from
    /// `AVCaptureVideoDataOutput` buffers (never a preview layer — see the file header).
    /// Created once and reused: a layer per start would leak layers.
    let backLayer: AVSampleBufferDisplayLayer = {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspectFill
        return layer
    }()
    /// The front camera's picture, attached as the small picture-in-picture layer.
    let frontLayer: AVSampleBufferDisplayLayer = {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspectFill
        return layer
    }()

    // MARK: Private

    /// The multi-cam session; nil while the mode is off, so nothing holds the cameras.
    @ObservationIgnored private var session: AVCaptureMultiCamSession?
    /// Notification observers for the live session (removed in `stop()`).
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The two inputs, kept so the frame rate can be cut if the hardware cost comes in over budget.
    @ObservationIgnored private var inputs: [AVCaptureDeviceInput] = []
    /// Strong references to the sample-buffer delegates (`AVCaptureVideoDataOutput` holds its
    /// delegate weakly) and the source of the per-camera frame counts.
    @ObservationIgnored private var relays: [String: DualCameraFrameRelay] = [:]
    /// Queue the two video data outputs deliver on. Serial and shared: the two feeds are only
    /// rendered, so ordering between them costs nothing and one queue is one fewer thread.
    @ObservationIgnored private let captureQueue = DispatchQueue(label: "canekit.dualcam", qos: .userInitiated)

    init() {}

    // MARK: Lifecycle

    /// Build and start the two-camera session.
    ///
    /// ⚠ The caller **must** have paused the AR session first (`AppModel.setBothCameras`), because
    /// both pipelines contend for the same cameras and ARKit loses (measured: 8 frames per 4 s).
    /// Order: input with no connections → data output with no connections → one explicit
    /// connection per camera → commit → cost check → start. `addInputWithNoConnections` /
    /// `addOutputWithNoConnections` plus explicit `AVCaptureConnection`s is the only way to drive
    /// two feeds from one session; the implicit connections `addInput` makes would wire only the
    /// first camera.
    /// A failure at any step leaves `lastError` set and the session torn down.
    func start() async {
        guard session == nil else { return }
        lastError = nil
        backConnected = false
        frontConnected = false
        frameRateReduced = false

        guard Self.isSupported else {
            lastError = "This phone cannot run two cameras at once, so only the back camera is shown."
            return
        }
        let session = AVCaptureMultiCamSession()
        self.session = session
        observe(session)

        session.beginConfiguration()
        backConnected = connect(.back, device: .builtInWideAngleCamera, name: "back",
                                to: backLayer, in: session)
        // The TrueDepth camera is the front camera on every Pro iPhone; fall back to whatever the
        // front wide-angle is, so a future device without TrueDepth still shows a selfie feed.
        frontConnected = connect(.front, device: .builtInTrueDepthCamera, name: "front",
                                 to: frontLayer, in: session)
            || connect(.front, device: .builtInWideAngleCamera, name: "front",
                       to: frontLayer, in: session)
        session.commitConfiguration()

        guard backConnected || frontConnected else {
            lastError = lastError ?? "No camera could be opened for the two-camera view."
            await stop()
            return
        }
        reduceFrameRateIfOverBudget(session)
        await Self.startRunning(session)
        isRunning = session.isRunning
        hardwareCost = session.hardwareCost
        systemPressureCost = session.systemPressureCost
        if !isRunning {
            lastError = "The two-camera session refused to run (hardware cost \(String(format: "%.2f", hardwareCost)))."
        } else if !frontConnected {
            lastError = "Only the back camera is available, so the front camera is not shown."
        }
    }

    /// Stop and release everything: the session, the connections, the delegates and the
    /// notification observers, and flush both layers so a later start never shows the last frame
    /// of the previous one.
    /// Safe to call when nothing is running (the Hazards card, backgrounding and route start all
    /// call it unconditionally).
    func stop() async {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        if let session {
            await Self.stopRunning(session)
            session.beginConfiguration()
            for connection in session.connections { session.removeConnection(connection) }
            for output in session.outputs { session.removeOutput(output) }
            for input in session.inputs { session.removeInput(input) }
            session.commitConfiguration()
        }
        session = nil
        inputs.removeAll()
        relays.removeAll()
        backLayer.sampleBufferRenderer.flush()
        frontLayer.sampleBufferRenderer.flush()
        isRunning = false
        backConnected = false
        frontConnected = false
    }

    /// Add one camera to the session and connect it to its own display layer through a video data
    /// output.
    /// - Parameters:
    ///   - position: `.back` or `.front`.
    ///   - type: the device type to ask for.
    ///   - name: "front" / "back", used for the error text and the frame counters.
    ///   - layer: the layer this camera's buffers are enqueued into.
    ///   - session: the multi-cam session being configured (inside begin/commit).
    /// - Returns: true when the camera is connected and its buffers will reach `layer`.
    private func connect(_ position: AVCaptureDevice.Position, device type: AVCaptureDevice.DeviceType,
                         name: String, to layer: AVSampleBufferDisplayLayer,
                         in session: AVCaptureMultiCamSession) -> Bool {
        guard let device = AVCaptureDevice.default(type, for: .video, position: position) else { return false }
        let label = name == "front" ? "Front" : "Back"
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            lastError = "\(label) camera: \(error.localizedDescription)"
            return false
        }
        guard session.canAddInput(input) else {
            lastError = "\(label) camera is not available right now."
            return false
        }
        session.addInputWithNoConnections(input)
        // Every failure below has to undo what has already been added. The front camera is tried
        // twice (TrueDepth, then plain wide angle), so a half-added first attempt would otherwise
        // leave an orphan input holding a camera and make the second attempt's `canAddInput` fail.
        func giveUp(_ message: String, output: AVCaptureVideoDataOutput? = nil) -> Bool {
            lastError = message
            if let output, session.outputs.contains(output) { session.removeOutput(output) }
            session.removeInput(input)
            relays[name] = nil
            return false
        }
        guard let port = input.ports(for: .video, sourceDeviceType: type,
                                     sourceDevicePosition: position).first else {
            return giveUp("\(label) camera has no video port.")
        }
        let output = AVCaptureVideoDataOutput()
        // Drop rather than queue: a spotter view showing a frame from a second ago is worse than a
        // spotter view that skipped one, and a backlog costs memory the depth pipeline wants back
        // the moment ARKit resumes.
        output.alwaysDiscardsLateVideoFrames = true
        let relay = DualCameraFrameRelay { [weak self] handoff in
            self?.render(handoff, into: layer)
        }
        relays[name] = relay
        output.setSampleBufferDelegate(relay, queue: captureQueue)
        guard session.canAddOutput(output) else {
            return giveUp("\(label) camera output could not be added.")
        }
        session.addOutputWithNoConnections(output)
        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        guard session.canAddConnection(connection) else {
            return giveUp("\(label) camera could not be connected.", output: output)
        }
        // The phone is clamped to a cane in portrait, and a preview layer would have handled this
        // itself; a data output will not, so the rotation is set explicitly. 90° is portrait for a
        // camera whose sensor is landscape.
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        // A selfie feed that is not mirrored reads as someone else's face to the person holding
        // the phone. Front camera only: mirroring the back camera would flip the world.
        if position == .front, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        session.addConnection(connection)
        inputs.append(input)
        return true
    }

    /// Enqueue one camera buffer on the main actor. Called by the relay once per hop.
    ///
    /// `AVSampleBufferDisplayLayer` is a `CALayer`, so the enqueue happens on main — but the pixels
    /// never touch the CPU: the renderer takes the `CMSampleBuffer` straight to the GPU, which is
    /// what makes two feeds at once affordable. A renderer that needs a flush gets one rather than
    /// staying dead, and a renderer that is not ready drops the frame.
    /// - Parameters:
    ///   - handoff: the sample buffer, carried across the queue hop.
    ///   - layer: the layer for that camera.
    private func render(_ handoff: CaptureHandoff<CMSampleBuffer>, into layer: AVSampleBufferDisplayLayer) {
        let renderer = layer.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding { renderer.flush() }
        guard renderer.isReadyForMoreMediaData else { return }
        renderer.enqueue(handoff.value)
    }

    /// Apple: a multi-cam session whose `hardwareCost` exceeds 1.0 will not run, and the documented
    /// remedy is to lower the frame rate through `AVCaptureDeviceInput.videoMinFrameDurationOverride`.
    /// Measured on the iPhone 17 Pro Max the cost was 0.26 with two feeds, so this never fired
    /// there — it exists so a hotter phone or a future device degrades to a slower picture instead
    /// of showing nothing at all. The threshold and the reduced rate are `MultiCamCost`
    /// (CaneKitLogic, pinned by MultiCamDepthTests).
    /// - Parameter session: the configured session, after `commitConfiguration()`.
    private func reduceFrameRateIfOverBudget(_ session: AVCaptureMultiCamSession) {
        guard MultiCamCost.needsFrameRateReduction(hardwareCost: Double(session.hardwareCost)) else { return }
        session.beginConfiguration()
        for input in inputs {
            input.videoMinFrameDurationOverride = CMTime(value: 1,
                                                         timescale: CMTimeScale(MultiCamCost.reducedFramesPerSecond))
        }
        session.commitConfiguration()
        frameRateReduced = true
    }

    /// Watch for the two things that silently kill a capture session, so the card can say why the
    /// picture went black instead of just showing black. Both observers use `queue: .main`, which
    /// is what makes `MainActor.assumeIsolated` legal (AGENTS.md hard rule 1).
    private func observe(_ session: AVCaptureMultiCamSession) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                           object: session, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let text = error?.localizedDescription ?? "unknown error"
            MainActor.assumeIsolated {
                self?.lastError = "Two-camera session error: \(text)"
                self?.isRunning = false
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                           object: session, queue: .main) { [weak self] note in
            let raw = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int) ?? -1
            MainActor.assumeIsolated {
                self?.lastError = "Two-camera session interrupted (reason \(raw))."
            }
        })
    }

    /// Numbers for the trip log: what the two cameras cost and whether they are really both live.
    /// `front_frames` / `back_frames` are the honest answer — a connection that was made but never
    /// delivered a buffer reads as 0 here, which a preview layer could not have shown.
    /// Read by `AppModel` when the mode is switched on and off.
    var diagnostics: [String: Any] {
        [
            "supported": Self.isSupported,
            "running": isRunning,
            "front": frontConnected,
            "back": backConnected,
            "front_frames": relays["front"]?.frameCount ?? 0,
            "back_frames": relays["back"]?.frameCount ?? 0,
            "hardware_cost": Double((hardwareCost * 100).rounded() / 100),
            "system_pressure_cost": Double((systemPressureCost * 100).rounded() / 100),
            "frame_rate_reduced": frameRateReduced,
            "error": lastError ?? "",
        ]
    }

    /// `AVCaptureSession.startRunning()` is documented as a blocking call, so it runs off the main
    /// actor; `CaptureHandoff` carries the non-Sendable session across the hop.
    private static func startRunning(_ session: AVCaptureSession) async {
        let handoff = CaptureHandoff(session)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                handoff.value.startRunning()
                cont.resume()
            }
        }
    }

    /// See `startRunning(_:)`; `stopRunning()` blocks in the same way.
    private static func stopRunning(_ session: AVCaptureSession) async {
        let handoff = CaptureHandoff(session)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                handoff.value.stopRunning()
                cont.resume()
            }
        }
    }
}

/// Sample-buffer delegate for one camera of the two-camera session.
///
/// It exists because `AVCaptureVideoDataOutput` delivers on a capture queue while everything that
/// touches a `CALayer` has to be on the main actor. It carries the buffer across in a
/// `CaptureHandoff` and keeps **at most one frame in flight**: while a hop is outstanding, newer
/// buffers are counted and dropped. That is the back-pressure that stops a busy main thread from
/// building a queue of stale video, and it is why the spotter view degrades in frame rate rather
/// than in latency.
///
/// `@unchecked Sendable` is sound: all mutable state lives in one `Mutex`, and each buffer is
/// handed over once and never read again by the capture queue (AGENTS.md hard rule 1).
private nonisolated final class DualCameraFrameRelay: NSObject,
                                                      AVCaptureVideoDataOutputSampleBufferDelegate,
                                                      @unchecked Sendable {

    /// Counter + in-flight flag together, so one lock covers both.
    private struct State {
        var frames = 0
        var inFlight = false
    }

    private let state = Mutex(State())
    /// Enqueues the buffer into this camera's layer, on the main actor.
    private let render: @MainActor (CaptureHandoff<CMSampleBuffer>) -> Void

    /// - Parameter render: main-actor closure that enqueues one buffer into the camera's layer.
    init(render: @escaping @MainActor (CaptureHandoff<CMSampleBuffer>) -> Void) {
        self.render = render
    }

    /// Sample buffers delivered by this camera since the session started — read by
    /// `DualCameraSession.diagnostics` for the trip log. Counts every buffer, including the ones
    /// dropped by the in-flight guard, because the question it answers is "did this camera
    /// actually produce frames?".
    var frameCount: Int { state.withLock { $0.frames } }

    /// Capture queue. Marks the buffer for immediate display and hops it to main, unless a hop is
    /// already outstanding.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let busy = state.withLock { state -> Bool in
            state.frames += 1
            if state.inFlight { return true }
            state.inFlight = true
            return false
        }
        guard !busy else { return }
        Self.markForImmediateDisplay(sampleBuffer)
        let handoff = CaptureHandoff(sampleBuffer)
        Task { @MainActor [self] in
            render(handoff)
            state.withLock { $0.inFlight = false }
        }
    }

    /// Capture buffers carry presentation timestamps on the capture clock, and
    /// `AVSampleBufferDisplayLayer` would otherwise wait for a timebase that a live preview does
    /// not have. `kCMSampleAttachmentKey_DisplayImmediately` is Apple's documented way to say
    /// "this is live video, show it now".
    /// - Parameter sampleBuffer: the buffer about to be enqueued (attachment mutated in place).
    private static func markForImmediateDisplay(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                        createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let raw = CFArrayGetValueAtIndex(attachments, 0)
        let dictionary = unsafeBitCast(raw, to: CFMutableDictionary.self)
        CFDictionarySetValue(dictionary,
                             Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
}

/// Carries one non-`Sendable` AVFoundation object across a single `await` or queue hop.
///
/// Sound because every use in this app is a single handover: the value is passed once, used on one
/// queue or actor, and the sender does not touch it again. It is never used to silence a real data
/// race (AGENTS.md hard rule 1). Used by `DualCameraSession` (sessions and sample buffers) and
/// `SensorProbe` (`startRunning` / `stopRunning`).
nonisolated final class CaptureHandoff<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
