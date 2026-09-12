//
//  SensorProbe.swift
//  CaneKit
//
//  Debug-only, one-shot measurement of what this phone *actually* lets us run at the same time as
//  LiDAR depth. It exists because the answer to "can the app show the front and the back camera at
//  once?" was previously asserted from memory instead of measured, and AGENTS.md ("How we
//  engineer", rule 1) does not allow that: a claim about the hardware needs a command whose output
//  proves it.
//
//  What it measures, in order, writing one trip-log record per case:
//    · `probe_capabilities` — the static capability flags and the complete Objective-C property
//      list of `ARFrame`. The property list is the evidence for (a): if no property on `ARFrame`
//      has a `CVPixelBuffer` type other than `capturedImage`, there is no second camera image to
//      read, whatever the configuration.
//    · `probe_a0_world_baseline` — world tracking + LiDAR alone: frames/s and thermal state, the
//      baseline the face-tracking cost is measured against.
//    · `probe_a_world_plus_face` — the same configuration with `userFaceTrackingEnabled = true`:
//      does depth survive, do `ARFaceAnchor`s arrive, and what size is `capturedImage` (back
//      camera or front camera?).
//    · `probe_b_face_plus_world` — `ARFaceTrackingConfiguration.isWorldTrackingEnabled = true`
//      (front camera primary): does `sceneDepth` survive? `supportsFrameSemantics(.sceneDepth)`
//      is asked first and the *measured* count of frames carrying depth is logged.
//    · `probe_c_multicam` — `AVCaptureMultiCamSession` with a front and a back input started while
//      ARKit owns the back camera: every `canAddInput` / input-creation error, whether the session
//      ran, how many sample buffers each output delivered, every `AVCaptureSession` interruption
//      or runtime error, and whether ARKit kept delivering frames.
//    · `probe_d_front_capture` — the same with a plain `AVCaptureSession` on the front camera only.
//    · `probe_e_audio_session` — what `.playAndRecord` does to the audio route (the sound-watch
//      feature needs an input; AGENTS.md hard rule 7 says the app has one `.playback` session, so
//      the cost of changing it is measured here rather than guessed).
//
//  Safety: it runs only under `CANEKIT_SENSOR_PROBE=1`, only before `DepthEngine.start()`, on its
//  own `ARSession` that is paused and released at the end, and it restores the `.playback` audio
//  session before returning. Nothing here is compiled out, but nothing here runs on a normal
//  launch either. It never speaks and never buzzes.
//
//  Threading / isolation: `@MainActor` (module default). ARKit and AVFoundation call back on their
//  own queues, so the two delegates are `nonisolated` relay classes holding a `Mutex`
//  (AGENTS.md hard rule 1); `startRunning()` / `stopRunning()` are blocking calls and are pushed
//  to a global queue through `CaptureHandoff` (DualCameraSession.swift), whose only job is to
//  carry a non-Sendable AVFoundation object across that hop.
//
//  Caller: `AppModel.start()`. Results: `ios/CaneKit/Depth/SensorProbe.swift` writes them to the
//  trip log; pull it with `xcrun devicectl device copy from … --domain-type appDataContainer`.
//

import ARKit
import AVFoundation
import CaneKitLogic
import Foundation
import ObjectiveC
import SoundAnalysis
import Synchronization
import UIKit

/// One-shot "what can run together" measurement, behind `CANEKIT_SENSOR_PROBE=1`.
/// Owned by `AppModel.start()`, which awaits `run()` and only then starts `DepthEngine`.
@MainActor
final class SensorProbe {

    /// True when the launch asked for the probe: `CANEKIT_SENSOR_PROBE=1` in the environment, or
    /// a `--sensor-probe` argument. Everything else in this file is dead code on a normal launch.
    ///
    /// Both, because `xcrun devicectl device process launch` proved unreliable at delivering
    /// environment variables to a device app (two of four launches arrived without it, while the
    /// trailing argument always did) — the same reason `AppModel.start()` accepts `--demo-route`
    /// as well as `CANEKIT_DEMO_ROUTE=1`.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["CANEKIT_SENSOR_PROBE"] == "1"
            || CommandLine.arguments.contains("--sensor-probe")
    }

    /// Where each measurement goes: `AppModel` wires this to `TripLogger.event`.
    /// Set before `run()`; every record is a trip-log `kind` starting with `probe_`.
    var onEvent: ((String, [String: Any]) -> Void)?

    /// How long each configuration is left running before its counters are read. Four seconds is
    /// enough for ARKit to finish starting the camera (≈1–2 s) and still deliver ≥ 30 frames.
    private let dwell = Duration.seconds(4)

    /// The probe's own session. Never the app's: `DepthEngine` has not started yet, and this one
    /// is paused and dropped before it does.
    private let session = ARSession()
    /// Serial queue ARKit delivers the probe's frames on (never the main queue: a blocked main
    /// thread would distort the frames/s numbers this probe exists to measure).
    private let queue = DispatchQueue(label: "canekit.probe", qos: .userInitiated)
    /// Counting delegate for `session`.
    private let watcher = ProbeSessionWatcher()

    init() {}

    /// Run every case in order and leave the phone exactly as it was found (AR session paused,
    /// capture sessions stopped, `.playback` audio session restored).
    /// Awaited by `AppModel.start()` before `DepthEngine.start()`.
    func run() async {
        // Behind the lock screen iOS takes the rear camera away (`sessionWasInterrupted`), which
        // produced a first run with "0 frames" that said nothing about the API question. Wait for
        // the app to actually be on screen, and record the state in every case so a record taken
        // in the wrong state is recognisable rather than believed.
        await waitForForeground()
        emit("probe_capabilities", [
            "world_supports_scene_depth": ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
            "world_supports_user_face_tracking": ARWorldTrackingConfiguration.supportsUserFaceTracking,
            "face_tracking_supported": ARFaceTrackingConfiguration.isSupported,
            "face_supports_world_tracking": ARFaceTrackingConfiguration.supportsWorldTracking,
            "face_supports_scene_depth": ARFaceTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
            "face_supports_smoothed_scene_depth": ARFaceTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth),
            "multicam_supported": AVCaptureMultiCamSession.isMultiCamSupported,
            // The evidence for (a): every ARFrame property and its Objective-C type. A second
            // camera image would have to appear here as another CVPixelBuffer-typed property.
            "arframe_pixel_buffer_properties": ProbeIntrospection.framePixelBufferProperties,
            "arframe_properties": ProbeIntrospection.frameProperties,
        ])

        session.delegate = watcher
        session.delegateQueue = queue

        await caseA0Baseline()
        await caseAWorldPlusFace()
        await caseBFacePlusWorld()
        await caseCMultiCam()
        await caseDFrontCaptureSession()
        caseEAudioSession()
        caseFSoundLabels()

        session.pause()
        session.delegate = nil
    }

    // MARK: (a) world tracking + user face tracking

    /// Baseline: world tracking with LiDAR, exactly what the app normally runs. Gives the
    /// frames/s and thermal state that the face-tracking case is compared against, so the cost of
    /// `userFaceTrackingEnabled` is a measured delta and not a guess.
    private func caseA0Baseline() async {
        let config = Self.worldConfiguration(face: false)
        await measure(config, options: [.resetTracking, .removeExistingAnchors],
                      as: "probe_a0_world_baseline", extra: [:])
    }

    /// (a) The same world configuration with `userFaceTrackingEnabled = true`. The question the
    /// owner asked is whether this hands the app the front camera's *image*; the record answers it
    /// with `captured_image` (the one image ARKit delivers — compare it with the baseline's, which
    /// is the back camera) plus the ARFrame property list from `probe_capabilities`.
    private func caseAWorldPlusFace() async {
        let config = Self.worldConfiguration(face: true)
        await measure(config, options: [.resetTracking, .removeExistingAnchors],
                      as: "probe_a_world_plus_face",
                      extra: ["config_user_face_tracking_enabled": config.userFaceTrackingEnabled])
    }

    /// The app's normal configuration, optionally with the front camera also tracking a face.
    /// - Parameter face: request `userFaceTrackingEnabled` (ignored where unsupported).
    private static func worldConfiguration(face: Bool) -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        config.worldAlignment = .gravity
        config.planeDetection = []
        if face, ARWorldTrackingConfiguration.supportsUserFaceTracking {
            config.userFaceTrackingEnabled = true
        }
        return config
    }

    // MARK: (b) face tracking + world tracking

    /// (b) Front camera primary: `ARFaceTrackingConfiguration` with `isWorldTrackingEnabled`.
    /// `supportsFrameSemantics(.sceneDepth)` is logged first, then the *measured* number of frames
    /// that actually carried `sceneDepth` — so the answer does not rest on the flag alone.
    /// An unsupported frame semantic is never assigned (ARKit raises for that); the flag is the
    /// runtime answer and the frame count confirms it.
    private func caseBFacePlusWorld() async {
        guard ARFaceTrackingConfiguration.isSupported else {
            emit("probe_b_face_plus_world", ["skipped": "ARFaceTrackingConfiguration unsupported"])
            return
        }
        let config = ARFaceTrackingConfiguration()
        let supportsWorld = ARFaceTrackingConfiguration.supportsWorldTracking
        if supportsWorld { config.isWorldTrackingEnabled = true }
        let supportsDepth = ARFaceTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        if supportsDepth { config.frameSemantics.insert(.sceneDepth) }
        await measure(config, options: [.resetTracking, .removeExistingAnchors],
                      as: "probe_b_face_plus_world",
                      extra: ["supports_world_tracking": supportsWorld,
                              "scene_depth_requested": supportsDepth,
                              "world_tracking_enabled": config.isWorldTrackingEnabled])
    }

    // MARK: (c) AVCaptureMultiCamSession alongside ARKit

    /// (c) Start ARKit on the back camera with LiDAR, then try to start an
    /// `AVCaptureMultiCamSession` with a back and a front input on top of it. Every failure mode
    /// is recorded separately: the device lookup, `AVCaptureDeviceInput(device:)` throwing,
    /// `canAddInput` refusing, the session refusing to run, no sample buffers arriving, an
    /// `AVCaptureSession` interruption (with its `InterruptionReason` raw value) or runtime error,
    /// and whether ARKit itself failed or was interrupted while this happened.
    private func caseCMultiCam() async {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            emit("probe_c_multicam", ["skipped": "multicam unsupported"])
            return
        }
        await runAndSettle(Self.worldConfiguration(face: false))
        let multi = AVCaptureMultiCamSession()
        await probeCapture(multi, positions: [(.back, .builtInWideAngleCamera), (.front, .builtInTrueDepthCamera)],
                           as: "probe_c_multicam")
    }

    // MARK: (d) a second AVCaptureSession on the front camera

    /// (d) ARKit keeps the back camera; a plain `AVCaptureSession` asks only for the front one.
    /// This is the "two independent sessions" question, separate from multi-cam.
    private func caseDFrontCaptureSession() async {
        await runAndSettle(Self.worldConfiguration(face: false))
        let capture = AVCaptureSession()
        await probeCapture(capture, positions: [(.front, .builtInTrueDepthCamera)],
                           as: "probe_d_front_capture")
    }

    /// Shared body of (c) and (d): build the capture session, start it while ARKit runs, watch
    /// both sides for `dwell`, then tear it down and report.
    /// - Parameters:
    ///   - capture: an `AVCaptureSession` or `AVCaptureMultiCamSession`.
    ///   - positions: the cameras to ask for, as (position, device type) pairs.
    ///   - kind: the trip-log record kind.
    private func probeCapture(_ capture: AVCaptureSession,
                              positions: [(AVCaptureDevice.Position, AVCaptureDevice.DeviceType)],
                              as kind: String) async {
        let notes = ProbeCaptureNotes()
        let outputs = ProbeCaptureCounter()
        let observers = notes.observe(capture)
        defer { for o in observers { NotificationCenter.default.removeObserver(o) } }

        watcher.reset()
        var setup: [String] = []
        capture.beginConfiguration()
        for (position, type) in positions {
            let name = position == .front ? "front" : "back"
            guard let device = AVCaptureDevice.default(type, for: .video, position: position) else {
                setup.append("\(name): no device")
                continue
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if capture.canAddInput(input) {
                    capture.addInput(input)
                    setup.append("\(name): input added")
                } else {
                    setup.append("\(name): canAddInput=false")
                }
            } catch {
                let e = error as NSError
                setup.append("\(name): input threw \(e.domain) \(e.code) — \(e.localizedDescription)")
                continue
            }
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(outputs.delegate(for: name), queue: queue)
            if capture.canAddOutput(output) {
                capture.addOutput(output)
                setup.append("\(name): output added")
            } else {
                setup.append("\(name): canAddOutput=false")
            }
        }
        capture.commitConfiguration()

        await Self.startRunning(capture)
        try? await Task.sleep(for: dwell)
        let running = capture.isRunning
        let ar = watcher.snapshot()
        await Self.stopRunning(capture)

        emit(kind, [
            "setup": setup,
            "capture_session_running": running,
            "sample_buffers": outputs.snapshot(),
            "capture_events": notes.snapshot(),
            "ar_frames_during": ar.frames,
            "ar_frames_with_depth_during": ar.depthFrames,
            "ar_error": ar.failure ?? "",
            "ar_interruptions": ar.interruptions,
            "thermal": Self.thermalName,
            "app_state": Self.applicationStateName,
        ])
    }

    // MARK: (e) the audio session the sound watch would need

    /// (e) SoundAnalysis needs an audio *input*, and `.playback` has none (AGENTS.md hard rule 7
    /// pins the app to one `.playback` session because HFP drops AirPods to call quality). Measure
    /// what `.playAndRecord` does to the current route instead of assuming, then restore
    /// `.playback` before returning — the walk's speech and beacon must be untouched.
    /// Nothing here requests microphone permission; the current permission state is logged.
    private func caseEAudioSession() {
        let session = AVAudioSession.sharedInstance()
        let before = Self.routeDescription(session)
        var failure = ""
        var after = "not reached"
        var restored = "not reached"
        do {
            // `.allowBluetoothA2DP` is required to keep AirPods output on A2DP at all under
            // `.playAndRecord` (Apple: "apps using the playAndRecord category may also allow
            // routing output to paired Bluetooth A2DP devices"). `.allowBluetoothHFP` is
            // deliberately NOT passed: Apple documents that HFP wins routing priority on a device
            // that offers both, which is the AirPods call-quality drop ios/README.md §2 forbids.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.duckOthers, .allowBluetoothA2DP, .defaultToSpeaker])
            try session.setActive(true)
            after = Self.routeDescription(session)
        } catch {
            let e = error as NSError
            failure = "playAndRecord: \(e.domain) \(e.code) — \(e.localizedDescription)"
            after = "failed"
        }
        let inputs = session.availableInputs?.map { "\($0.portType.rawValue):\($0.portName)" } ?? []
        do {
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
            restored = Self.routeDescription(session)
        } catch {
            restored = "restore failed: \(error.localizedDescription)"
            failure += " | restore: \(error.localizedDescription)"
        }
        emit("probe_e_audio_session", [
            "route_playback": before,
            "route_play_and_record": after,
            "route_restored": restored,
            "error": failure,
            "record_permission": "\(AVAudioApplication.shared.recordPermission.rawValue)",
            "available_inputs_while_recording": inputs,
        ])
    }

    // MARK: (f) which sound labels the built-in classifier actually has

    /// Apple documents "hundreds of sounds" for `SNClassifierIdentifier.version1` but publishes no
    /// list of the label strings, and `SNClassifySoundRequest.knownClassifications` is the
    /// documented way to get them ("every prediction label in the request's underlying sound
    /// classifier model"). So the identifiers the danger-sound watch matches on are *read off this
    /// phone* rather than guessed, and both the matches and the misses are logged.
    private func caseFSoundLabels() {
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            let known = Set(request.knownClassifications)
            let wanted = SoundAlerts.candidateLabels
            emit("probe_f_sound_labels", [
                "known_count": known.count,
                "matched": wanted.filter { known.contains($0) }.sorted(),
                "missing": wanted.filter { !known.contains($0) }.sorted(),
                // Everything with a road / vehicle / alarm flavour, so a missing candidate can be
                // replaced with the real identifier without another build.
                "road_like": request.knownClassifications.filter { label in
                    ["siren", "horn", "car", "vehicle", "truck", "bus", "engine", "traffic",
                     "motorcycle", "train", "alarm", "emergency", "bicycle", "brake", "skid"]
                        .contains(where: label.contains)
                }.sorted(),
            ])
        } catch {
            emit("probe_f_sound_labels", ["error": error.localizedDescription])
        }
    }

    /// "BluetoothA2DP:AirPods Pro → " style summary of the current route, both directions.
    private static func routeDescription(_ session: AVAudioSession) -> String {
        let route = session.currentRoute
        let outs = route.outputs.map { "\($0.portType.rawValue)" }.joined(separator: "+")
        let ins = route.inputs.map { "\($0.portType.rawValue)" }.joined(separator: "+")
        return "out=\(outs.isEmpty ? "none" : outs) in=\(ins.isEmpty ? "none" : ins)"
    }

    // MARK: Plumbing

    /// Run one AR configuration for `dwell`, then emit its counters as `kind`.
    ///
    /// `frames_per_second` is measured between the *first and last* frame ARKit delivered, not
    /// over the whole dwell: `session.run` needs 1–2 s to bring the camera up, and dividing by the
    /// dwell buried the real rate (a 60 fps camera read as 12). This is the number the
    /// face-tracking cost comment quotes.
    /// A case that received no frames at all is retried once — the usual cause is the previous
    /// configuration's camera still shutting down, not an API limit.
    private func measure(_ config: ARConfiguration, options: ARSession.RunOptions,
                         as kind: String, extra: [String: Any]) async {
        var counts = await runDwell(on: config, options: options)
        var retried = false
        if counts.frames == 0 {
            retried = true
            counts = await runDwell(on: config, options: options)
        }
        var fields: [String: Any] = [
            "frames": counts.frames,
            "frames_per_second": Self.framesPerSecond(counts),
            "frames_with_scene_depth": counts.depthFrames,
            "face_anchors_seen": counts.faceAnchors,
            "captured_image": "\(counts.imageWidth)x\(counts.imageHeight)",
            "ar_error": counts.failure ?? "",
            "ar_interruptions": counts.interruptions,
            "thermal": Self.thermalName,
            "app_state": Self.applicationStateName,
            "retried": retried,
        ]
        if let sample = counts.faceForward {
            fields["face_forward_xz"] = [Double(sample.0), Double(sample.1)]
        }
        for (k, v) in extra { fields[k] = v }
        emit(kind, fields)
    }

    /// Run `config` for the dwell and hand back its counters.
    private func runDwell(on config: ARConfiguration, options: ARSession.RunOptions) async -> ProbeSessionWatcher.Counts {
        watcher.reset()
        session.run(config, options: options)
        try? await Task.sleep(for: dwell)
        return watcher.snapshot()
    }

    /// Frames per second between the first and the last frame of a dwell (−1 with fewer than two
    /// frames). The clock is `ARFrame.timestamp`, ARKit's own.
    private static func framesPerSecond(_ counts: ProbeSessionWatcher.Counts) -> Double {
        guard counts.frames > 1, let first = counts.firstFrameTime, let last = counts.lastFrameTime,
              last > first else { return -1 }
        return (Double(counts.frames - 1) / (last - first) * 10).rounded() / 10
    }

    /// `active` / `inactive` / `background`: a record taken outside `active` says nothing about
    /// what the API allows, because iOS takes the camera away behind the lock screen.
    private static var applicationStateName: String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    /// Poll until the app is `.active`, for at most 60 s. Returns immediately in the normal case
    /// (the probe is started from the root view's `.task`, i.e. on screen).
    private func waitForForeground() async {
        for _ in 0..<120 {
            if UIApplication.shared.applicationState == .active { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
        emit("probe_warning", ["message": "app never became active; camera results are not valid"])
    }

    /// Start `config` and give ARKit a second to hand out its first frames, without emitting a
    /// record: used to put ARKit in its normal state before a capture-session case.
    private func runAndSettle(_ config: ARConfiguration) async {
        watcher.reset()
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        try? await Task.sleep(for: .seconds(2))
    }

    /// `AVCaptureSession.startRunning()` blocks, so it is documented as a background call. The
    /// session is not `Sendable`; `CaptureHandoff` carries it across the hop, which is sound because
    /// only this probe touches it and the two hops are strictly ordered by `await`.
    private static func startRunning(_ capture: AVCaptureSession) async {
        let box = CaptureHandoff(capture)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                box.value.startRunning()
                cont.resume()
            }
        }
    }

    /// See `startRunning(_:)`; `stopRunning()` blocks in the same way.
    private static func stopRunning(_ capture: AVCaptureSession) async {
        let box = CaptureHandoff(capture)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                box.value.stopRunning()
                cont.resume()
            }
        }
    }

    /// `nominal` / `fair` / `serious` / `critical`, so a probe record shows whether a number was
    /// taken on a hot phone.
    private static var thermalName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// One trip-log record; no-op when `AppModel` did not wire `onEvent`.
    private func emit(_ kind: String, _ fields: [String: Any]) {
        onEvent?(kind, fields)
    }
}

// MARK: - Introspection

/// Reads the Objective-C property list of `ARFrame`. This is the evidence for question (a): a
/// second camera image would have to be reachable as a property of the frame, and the only way to
/// show there is none is to enumerate them all rather than to recall the header.
enum ProbeIntrospection {

    /// Every `ARFrame` property as `name:T<encoding>` (the first field of the attribute string).
    static var frameProperties: [String] { properties(of: ARFrame.self) }

    /// The subset whose Objective-C type is a `CVPixelBuffer` (`^{__CVBuffer=}`). On a phone where
    /// only `capturedImage` appears here, no configuration can hand the app a second image.
    static var framePixelBufferProperties: [String] {
        properties(of: ARFrame.self).filter { $0.contains("CVBuffer") }
    }

    /// `name:typeEncoding` for every declared property of `cls` (not its superclasses).
    /// - Parameter cls: an Objective-C class object, e.g. `ARFrame.self`.
    static func properties(of cls: AnyClass) -> [String] {
        var count: UInt32 = 0
        guard let list = class_copyPropertyList(cls, &count) else { return [] }
        defer { free(list) }
        return (0..<Int(count)).map { i in
            let property = list[i]
            let name = String(cString: property_getName(property))
            // `property_getAttributes` is nullable in the runtime headers; a property with no
            // attribute string still has a usable name.
            let attributes = property_getAttributes(property).map { String(cString: $0) } ?? ""
            let type = attributes.split(separator: ",").first.map(String.init) ?? ""
            return "\(name):\(type)"
        }
    }
}

// MARK: - Relays

/// Counting `ARSessionDelegate` for the probe's session. `nonisolated` because ARKit calls it on
/// `SensorProbe.queue`; all state lives in one `Mutex` so the main actor can read a snapshot.
private nonisolated final class ProbeSessionWatcher: NSObject, ARSessionDelegate, @unchecked Sendable {

    /// What one configuration delivered during its dwell.
    struct Counts: Sendable {
        /// Frames delivered by `session(_:didUpdate:)`.
        var frames = 0
        /// Of those, how many carried `sceneDepth` (the LiDAR answer for cases a and b).
        var depthFrames = 0
        /// `ARFaceAnchor`s seen in `didAdd` / `didUpdate`.
        var faceAnchors = 0
        /// Size of `ARFrame.capturedImage`; identifies which camera the one image comes from.
        var imageWidth = 0
        var imageHeight = 0
        /// `ARFrame.timestamp` of the first and the last frame of the dwell. The frame rate is
        /// measured between them, so `session.run`'s 1–2 s camera start-up is not averaged in.
        var firstFrameTime: Double?
        var lastFrameTime: Double?
        /// A sample of the face anchor's forward axis (world x, z), so the head-yaw maths can be
        /// sanity-checked against a real anchor.
        var faceForward: (Float, Float)?
        /// `session(_:didFailWithError:)`, verbatim.
        var failure: String?
        /// `sessionWasInterrupted` count.
        var interruptions = 0
    }

    private let counts = Mutex(Counts())

    /// Zero the counters before a new configuration's dwell (main actor).
    func reset() { counts.withLock { $0 = Counts() } }
    /// Read the counters after a dwell (main actor).
    func snapshot() -> Counts { counts.withLock { $0 } }

    /// Hot path: count the frame, whether it carried depth, and the image size. The `ARFrame`
    /// itself never leaves this call (retaining frames makes ARKit drop them — ios/README.md §6).
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let hasDepth = frame.sceneDepth != nil
        let width = CVPixelBufferGetWidth(frame.capturedImage)
        let height = CVPixelBufferGetHeight(frame.capturedImage)
        let time = frame.timestamp
        counts.withLock {
            $0.frames += 1
            if hasDepth { $0.depthFrames += 1 }
            $0.imageWidth = width
            $0.imageHeight = height
            if $0.firstFrameTime == nil { $0.firstFrameTime = time }
            $0.lastFrameTime = time
        }
    }

    /// Face anchors added (the only thing `userFaceTrackingEnabled` actually delivers).
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { note(anchors) }
    /// Face anchors updated (~60 Hz while a face is in view).
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { note(anchors) }

    /// Count `ARFaceAnchor`s and keep one sample of the head's forward axis in world space.
    /// The anchor's +Z column points out of the face, i.e. the direction the walker is looking.
    private func note(_ anchors: [ARAnchor]) {
        let faces = anchors.compactMap { $0 as? ARFaceAnchor }
        guard !faces.isEmpty else { return }
        let z = faces[0].transform.columns.2
        counts.withLock {
            $0.faceAnchors += faces.count
            $0.faceForward = (z.x, z.z)
        }
    }

    /// Session failure (the exact ARKit error is the answer for an unsupported combination).
    func session(_ session: ARSession, didFailWithError error: Error) {
        let e = error as NSError
        let text = "\(e.domain) \(e.code) — \(e.localizedDescription)"
        counts.withLock { $0.failure = text }
    }

    /// Camera taken away (this is what a competing capture session would look like from ARKit).
    func sessionWasInterrupted(_ session: ARSession) {
        counts.withLock { $0.interruptions += 1 }
    }
}

/// Collects `AVCaptureSession` notifications (interruption, interruption ended, runtime error)
/// as readable strings. `nonisolated` + `Mutex`: the notifications are delivered on an arbitrary
/// queue and read from the main actor.
private nonisolated final class ProbeCaptureNotes: @unchecked Sendable {

    private let lines = Mutex<[String]>([])

    /// Subscribe to the three notifications that say why a capture session did not work.
    /// - Returns: the observer tokens; the caller removes them.
    func observe(_ capture: AVCaptureSession) -> [NSObjectProtocol] {
        let center = NotificationCenter.default
        let interrupted = center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                             object: capture, queue: nil) { [self] note in
            let raw = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int) ?? -1
            append("wasInterrupted reason=\(raw) (\(Self.reasonName(raw)))")
        }
        let ended = center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                       object: capture, queue: nil) { [self] _ in
            append("interruptionEnded")
        }
        let failed = center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                        object: capture, queue: nil) { [self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            append("runtimeError \(error?.domain ?? "?") \(error?.code ?? 0) — \(error?.localizedDescription ?? "?")")
        }
        return [interrupted, ended, failed]
    }

    /// Everything recorded so far (main actor).
    func snapshot() -> [String] { lines.withLock { $0 } }

    private func append(_ line: String) { lines.withLock { $0.append(line) } }

    /// `AVCaptureSession.InterruptionReason` raw value → its case name, so the log is readable
    /// without the header. 5 is the one this probe is looking for.
    private static func reasonName(_ raw: Int) -> String {
        switch AVCaptureSession.InterruptionReason(rawValue: raw) {
        case .videoDeviceNotAvailableInBackground: return "videoDeviceNotAvailableInBackground"
        case .audioDeviceInUseByAnotherClient: return "audioDeviceInUseByAnotherClient"
        case .videoDeviceInUseByAnotherClient: return "videoDeviceInUseByAnotherClient"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: return "videoDeviceNotAvailableWithMultipleForegroundApps"
        case .videoDeviceNotAvailableDueToSystemPressure: return "videoDeviceNotAvailableDueToSystemPressure"
        case .sensitiveContentMitigationActivated: return "sensitiveContentMitigationActivated"
        case .none: return "unknown"
        @unknown default: return "unknown"
        }
    }
}

/// Counts sample buffers per camera, so "the session said it was running" can be told apart from
/// "images actually arrived". One delegate object per camera name.
private nonisolated final class ProbeCaptureCounter: @unchecked Sendable {

    private let counts = Mutex<[String: Int]>([:])
    private let delegates = Mutex<[String: ProbeOutputDelegate]>([:])

    /// A retained delegate for `name` ("front" / "back"); `AVCaptureVideoDataOutput` holds its
    /// sample-buffer delegate weakly, so the probe must keep it alive.
    func delegate(for name: String) -> ProbeOutputDelegate {
        let delegate = ProbeOutputDelegate { [self] in
            counts.withLock { $0[name, default: 0] += 1 }
        }
        delegates.withLock { $0[name] = delegate }
        return delegate
    }

    /// "front=118 back=0" (main actor).
    func snapshot() -> [String: Int] { counts.withLock { $0 } }
}

/// Minimal `AVCaptureVideoDataOutputSampleBufferDelegate` that only counts. The sample buffer is
/// never retained or copied: the question is whether frames arrive at all.
private nonisolated final class ProbeOutputDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let onFrame: @Sendable () -> Void
    init(onFrame: @escaping @Sendable () -> Void) { self.onFrame = onFrame }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        onFrame()
    }
}
