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
//    · Unsupported hardware gets **no picture and an honest refusal**, not a back-camera
//      consolation prize. With `AVCaptureMultiCamSession.isMultiCamSupported` false the switch is
//      disabled on the Hazards card, `AppModel.setBothCameras` refuses *before* it pauses anything
//      (ARKit keeps running, and the separate "Live camera view" still shows the back camera from
//      ARKit's own frames), and every line of copy says the same thing: "This phone cannot show
//      two cameras at once."
//      ⚠ `lastError` here used to end "…so only the back camera is shown" while the code returned
//      without opening a single camera — a promise the code does not keep, which is worse than a
//      refusal. If a real single-camera fallback is ever built, change the words back with it.
//    · `stop()` always tears the session down, even after a failed `start()` — and `start()`
//      itself tears down on **every** failure path once the session object exists. `start()` opens
//      with `guard session == nil`, so a failed start that left the object behind would turn every
//      later attempt to switch the mode on into a silent no-op, with a dead session still holding
//      the camera inputs.
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
    /// Which cameras `start()` managed to open, kept **across the teardown** that now follows a
    /// failed start. `frontConnected` / `backConnected` are the live truth and go false in
    /// `stop()`, because after a teardown nothing is connected; these two remember what came up
    /// before the session refused to run, which is the difference between "no camera opened" and
    /// "both cameras opened and the session would not start" in the trip log.
    @ObservationIgnored private(set) var frontOpened = false
    @ObservationIgnored private(set) var backOpened = false

    /// Buffers actually handed to a display layer's renderer since the last `start()`.
    ///
    /// This is *not* `front_frames` + `back_frames`: those count what the cameras delivered to the
    /// relay, this counts what reached the picture. The two numbers differ by exactly the frames
    /// this class threw away, which is the evidence that separates "the cameras are not running"
    /// from "the cameras are running and the view is black" — the bug that used to be here (see
    /// `render(_:into:)`). `@ObservationIgnored`: it changes ~60 times a second and no view reads
    /// it, so it must never invalidate the Hazards card.
    @ObservationIgnored private(set) var enqueuedFrames = 0
    /// How many times a renderer was flushed back to life (`requiresFlushToResumeDecoding`, or
    /// `status == .failed`). Normally 0; a climbing count is a decoder that keeps dying, which
    /// looks identical to a dead camera on screen and would otherwise be invisible.
    @ObservationIgnored private(set) var rendererFlushes = 0

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
    /// One per camera, retained for the life of the session: `AVCaptureDevice.RotationCoordinator`
    /// observes the device's orientation and stops updating the moment it is released.
    @ObservationIgnored private var rotationCoordinators: [AVCaptureDevice.RotationCoordinator] = []
    /// The `videoRotationAngle` actually applied per camera ("front" / "back"), kept for the trip
    /// log. When the front inset still looks tilted on the device, these two numbers say whether
    /// the coordinator or the fallback is to blame — no second guess-run needed.
    @ObservationIgnored private var appliedRotationAngles: [String: Double] = [:]
    /// The `isVideoMirrored` actually in effect on the front connection, kept for the trip log
    /// beside the rotation angles. Read back from the connection after setting, so the log
    /// records what AVFoundation accepted, not what was asked.
    @ObservationIgnored private var frontMirrored = false
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
    /// A failure at any step leaves `lastError` set and the session torn down — *every* path,
    /// including "the session did not start", because of the `guard session == nil` on the first
    /// line (see the file header's invariants).
    func start() async {
        guard session == nil else { return }
        lastError = nil
        backConnected = false
        frontConnected = false
        frameRateReduced = false
        enqueuedFrames = 0
        rendererFlushes = 0
        frontOpened = false
        backOpened = false
        appliedRotationAngles.removeAll()
        frontMirrored = false

        guard Self.isSupported else {
            // Say what actually happens, which is nothing. This line used to end "…so only the
            // back camera is shown" and the next statement was `return`: no camera was opened, no
            // fallback existed, and the walker was promised a picture that could never appear.
            // `AppModel` refuses this mode before it pauses ARKit, so the safety path is untouched
            // and "Live camera view" still shows the back camera from ARKit's frames.
            lastError = "This phone cannot show two cameras at once, so the two-camera view is not available."
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
        backOpened = backConnected
        frontOpened = frontConnected

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
            // Tear the session down instead of leaving a zombie behind. `start()` begins with
            // `guard session == nil else { return }`, so a session that was assigned and then
            // failed to run (system pressure, camera contention, cost over budget) made **every
            // later attempt to turn the mode on return immediately and do nothing**, while the dead
            // session still held both camera inputs — for the rest of the app's life, with the
            // walker having paid for it by pausing ARKit. `stop()` never touches `lastError`, but
            // it does reset the connection flags, so the message is re-applied after it.
            let why = "The two-camera session refused to run (hardware cost \(String(format: "%.2f", hardwareCost)))."
            await stop()
            lastError = why
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
            for output in session.outputs {
                // Clear the delegate **before** the output is removed and `relays` is emptied
                // below. An `AVCaptureVideoDataOutput` that still has a delegate and a callback
                // queue can call into the relay while this teardown runs on the main actor, with
                // the relay about to be deallocated and its layer flushed — the long-standing
                // AVFoundation teardown rule ("set the delegate and queue to nil before you
                // release the output, to avoid deadlocks"). ⚠ That sentence is *not* in the
                // iOS 27 SDK's AVCaptureVideoDataOutput.h nor in the current online reference
                // (both checked, 2026-09-11): it is legacy wording, so treat it as belt and
                // braces rather than a documented guarantee. What is documented is that nil is
                // the one allowed value for the queue here ("may not be NULL, except when setting
                // the sampleBufferDelegate to nil"), and that this is what stops delivery.
                (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
                session.removeOutput(output)
            }
            for input in session.inputs { session.removeInput(input) }
            session.commitConfiguration()
        }
        session = nil
        inputs.removeAll()
        rotationCoordinators.removeAll()
        appliedRotationAngles.removeAll()
        frontMirrored = false
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
            if let output {
                // Same order as `stop()`: the delegate goes first, because the line below drops
                // `relays[name]` — the only strong reference to the relay — while this output may
                // still be wired to it. The output is passed on **every** failure path that has
                // built one, including "output could not be added", where it never entered the
                // session and would otherwise be released with its delegate still set.
                output.setSampleBufferDelegate(nil, queue: nil)
                if session.outputs.contains(output) { session.removeOutput(output) }
            }
            session.removeInput(input)
            relays[name] = nil
            appliedRotationAngles[name] = nil
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
            return giveUp("\(label) camera output could not be added.", output: output)
        }
        session.addOutputWithNoConnections(output)
        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        guard session.canAddConnection(connection) else {
            return giveUp("\(label) camera could not be connected.", output: output)
        }
        // The phone is clamped to a cane in portrait, and a preview layer would have handled the
        // rotation itself; a data output will not, so it is set explicitly.
        //
        // NOT a hard-coded 90°. That is right for the back sensor and wrong for the front one,
        // which is mounted the other way round — the front feed came out sideways on the device,
        // and still tilted after the first coordinator fix.
        // `AVCaptureDevice.RotationCoordinator` computes the correct angle for THIS device, which
        // is why Apple added it; a table of per-camera magic numbers is wrong on the next model.
        // The coordinator must be retained: it observes device orientation and a released one
        // stops updating.
        // Capture angle first, not preview: this connection feeds a video data output (a capture
        // connection), and the preview angle follows the interface orientation while the capture
        // angle follows the horizon — on a clamped phone those can disagree by exactly the 90°
        // tilt seen on the front inset. Last resort is per-position, not a blind 90: the front
        // sensor needs 270 in portrait where the back needs 90.
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinators.append(coordinator)
        let captureAngle = coordinator.videoRotationAngleForHorizonLevelCapture
        let previewAngle = coordinator.videoRotationAngleForHorizonLevelPreview
        let fallbackAngle: CGFloat = position == .front ? 270 : 90
        let applied: CGFloat
        if connection.isVideoRotationAngleSupported(captureAngle) {
            applied = captureAngle
        } else if connection.isVideoRotationAngleSupported(previewAngle) {
            applied = previewAngle
        } else if connection.isVideoRotationAngleSupported(fallbackAngle) {
            applied = fallbackAngle
        } else {
            applied = connection.videoRotationAngle
        }
        connection.videoRotationAngle = applied
        appliedRotationAngles[name] = Double(applied)
        // The front inset is NOT mirrored, on purpose. Selfie-mirror convention is for the
        // person being filmed; this screen is watched by a sighted spotter next to the walker,
        // and the inset must agree with the back feed on left and right — a mirrored inset
        // contradicts the main picture (and flips every sign). Observed on device: mirrored read
        // backwards; unmirrored matches the world. Back camera is never mirrored.
        if position == .front, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        if position == .front { frontMirrored = connection.isVideoMirrored }
        session.addConnection(connection)
        inputs.append(input)
        return true
    }

    /// Enqueue one camera buffer on the main actor. Called by the relay once per hop.
    ///
    /// `AVSampleBufferDisplayLayer` is a `CALayer`, so the enqueue happens on main — but the pixels
    /// never touch the CPU: the renderer takes the `CMSampleBuffer` straight to the GPU, which is
    /// what makes two feeds at once affordable. A renderer that is *broken* is flushed back to life
    /// and then fed this very frame; a renderer that merely says it is busy is fed anyway.
    ///
    /// ⚠ There is deliberately **no** `guard renderer.isReadyForMoreMediaData else { return }`
    /// here, and there must never be one again. It was here, and while the flag reads false it
    /// throws every frame on the floor: the buffer is dropped, nothing re-delivers it, and the
    /// layer keeps showing whatever it showed last — black, if that is nothing. Whether this
    /// phone's renderer really holds the flag false (a layer that has never been enqueued and has
    /// no timebase running is the usual suspect) has **not** been reproduced on the device; what
    /// has been verified is that the guard is wrong in principle, from the iOS 27 SDK header
    /// `AVQueuedSampleBufferRendering.h` (the source developer.apple.com is generated from), which
    /// describes the flag as belonging to the *pull* protocol, for sources that can outrun the
    /// renderer — not to live push:
    ///   · "An object conforming to AVQueuedSampleBufferRendering keeps track of the occupancy
    ///     levels of its internal queues **for the benefit of clients that enqueue sample buffers
    ///     from non-real-time sources** — i.e., clients that can supply sample buffers faster than
    ///     they are consumed, and so need to decide when to hold back."
    ///   · "**It is safe to call enqueueSampleBuffer: when readyForMoreMediaData is NO**, but it
    ///     is a bad idea to enqueue sample buffers without bound."
    ///   · "To help with control of the non-real-time supply of sample buffers, such clients can
    ///     use -requestMediaDataWhenReadyOnQueue:usingBlock …", and "This property is not key
    ///     value observable" — i.e. the supported way to use it is the pull loop this class does
    ///     not run.
    /// Nothing here is a non-real-time source: the buffers arrive from the camera at its own frame
    /// rate, each carries `kCMSampleAttachmentKey_DisplayImmediately` (documented in the same
    /// header as "the decoded image will be displayed as soon as possible, **replacing all
    /// previously enqueued images** regardless of their timestamps", so they cannot pile up), and
    /// `DualCameraFrameRelay` already holds the supply to one frame in flight. "Without bound",
    /// the only thing the flag protects against, cannot happen.
    ///
    /// What *is* still guarded is the renderer being unable to decode at all, where enqueueing
    /// really would be pointless — and both conditions are documented as recoverable by a flush:
    ///   · `requiresFlushToResumeDecoding`: "clients must first reset the video renderer by calling
    ///     flush" (`AVSampleBufferVideoRenderer.h`).
    ///   · `status == .failed`: "To resume rendering sample buffers using the video renderer after
    ///     a failure, clients must first reset the status to AVQueuedSampleBufferRenderingStatus-
    ///     Unknown. This can be achieved by invoking -flush on the video renderer." (same header.)
    /// Flushing and then enqueueing means a renderer that died — app backgrounded, decoder
    /// resources taken away — comes back on the next camera buffer (~33 ms) instead of staying
    /// black until the mode is switched off and on again.
    /// - Parameters:
    ///   - handoff: the sample buffer, carried across the queue hop.
    ///   - layer: the layer for that camera.
    private func render(_ handoff: CaptureHandoff<CMSampleBuffer>, into layer: AVSampleBufferDisplayLayer) {
        let renderer = layer.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding || renderer.status == .failed {
            renderer.flush()
            rendererFlushes += 1
        }
        renderer.enqueue(handoff.value)
        enqueuedFrames += 1
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
    /// delivered a buffer reads as 0 here, which a preview layer could not have shown. `enqueued`
    /// is the second half of that answer: frames the cameras delivered *and* this class handed to
    /// a renderer. Camera frames climbing while `enqueued` stays at 0 is a black view with live
    /// cameras, which is exactly what the old `isReadyForMoreMediaData` guard produced.
    /// Read by `AppModel` when the mode is switched on and off.
    var diagnostics: [String: Any] {
        [
            "supported": Self.isSupported,
            "running": isRunning,
            "front": frontConnected,
            "back": backConnected,
            // What came up during configuration; survives the teardown after a failed start.
            "front_opened": frontOpened,
            "back_opened": backOpened,
            "front_frames": relays["front"]?.frameCount ?? 0,
            "back_frames": relays["back"]?.frameCount ?? 0,
            // Frames that reached a renderer, and renderer resurrections. `enqueued` far below
            // `front_frames + back_frames` means frames arrived and were dropped before the
            // picture — the failure mode that made this view black (see `render(_:into:)`).
            "enqueued": enqueuedFrames,
            "renderer_flushes": rendererFlushes,
            "front_rotation": appliedRotationAngles["front"] ?? -1,
            "back_rotation": appliedRotationAngles["back"] ?? -1,
            "front_mirrored": frontMirrored,
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
