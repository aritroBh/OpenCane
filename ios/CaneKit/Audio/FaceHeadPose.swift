//
//  FaceHeadPose.swift
//  CaneKit
//
//  Head yaw from the **front** (TrueDepth) camera, running at the same time as the back camera's
//  LiDAR depth, so the audio beacon can be head-tracked with **no AirPods**.
//
//  Why this exists: `HeadPoseTracker` is the only head-direction source the app had, and it needs
//  AirPods Pro (`CMHeadphoneMotionManager`). The owner wants the AirPods and the Apple Watch to be
//  optional. `ARWorldTrackingConfiguration.userFaceTrackingEnabled` costs nothing but the front
//  camera's power: ARKit keeps the rear camera and LiDAR exactly as they are and adds an
//  `ARFaceAnchor` for the walker's own face (measured on the phone, `probe_a_world_plus_face` in
//  the trip log). The anchor's orientation is the head direction, which is what the beacon needs.
//
//  What it is *not*: the front camera's **image**. ARKit delivers one `capturedImage` per frame and
//  it is the rear camera's; Apple states "you still must choose one camera feed to show to the user
//  at a time" (developer.apple.com/documentation/arkit/choosing-which-camera-feed-to-augment), and
//  the on-device probe found no second image buffer on `ARFrame`. So this class publishes numbers
//  — face found, head yaw in degrees — and the Hazards card shows those, labelled as such. It
//  never implies a selfie picture is on screen.
//
//  Owner: `AppModel.faceHead` (one instance). Fed by `DepthEngine.onFaceYaw` (main actor, from the
//  AR session's anchor delegate); read by `AppModel.startTicker` through `HeadYawSelector`, which
//  prefers AirPods and falls back to this.
//
//  Threading / isolation: `@MainActor @Observable`. Every numeric rule (smoothing, staleness,
//  jump rejection, the reference) lives in CaneKitLogic `FaceYawTracker`, tested by
//  HeadYawSourcesTests; this class only owns the value and the lifecycle.
//
//  Audio: none. Motion: none. It is a view of the AR session that is already running.
//
//  Key invariants:
//    · `yawDeg` is relative to a reference captured at Recenter, positive = head turned right —
//      byte-for-byte the same contract as `HeadPoseTracker.headYawDeg`, so `BeaconEngine` needs no
//      second code path.
//    · A face not seen for `FaceYawTracker.maxAge` reports nil, never a stale direction.
//    · `stop()` clears everything: the UI must never show a head pose from a previous walk.
//

import CaneKitLogic
import Foundation
import Observation

/// Head yaw from the front camera's `ARFaceAnchor`, as a drop-in alternative to AirPods motion.
@MainActor
@Observable
final class FaceHeadPose {

    // MARK: Published

    /// Degrees, positive = head turned to the right of the recentred direction; nil when no fresh
    /// face or no reference yet. Range (−180, 180]. Read by AppModel's 10 Hz ticker.
    private(set) var yawDeg: Double?
    /// A face was seen within `FaceYawTracker.maxAge`. Drives the Hazards card's honest
    /// "Front camera: face found" readout and the trip log's `head_source`.
    private(set) var isTracking = false
    /// Face anchors ingested since `start()` — proof in the UI and the log that the front camera is
    /// really running, not just requested.
    private(set) var samples = 0

    /// Pure smoothing / staleness / reference rules (CaneKitLogic, HeadYawSourcesTests).
    @ObservationIgnored private var tracker = FaceYawTracker()
    /// True between `start()` and `stop()`; samples that arrive outside that window are dropped so
    /// a frame already queued cannot resurrect a stopped tracker (the bug `HeadPoseTracker.active`
    /// exists to prevent).
    @ObservationIgnored private var active = false
    /// Clock of the last ingested sample (ARKit frame clock), used for `yawDeg`'s staleness check
    /// on the ticker, which has no frame of its own.
    @ObservationIgnored private var lastNow: Double = 0

    init() {}

    // MARK: Lifecycle

    /// Begin using face samples. Clears the reference so the walker's pose at the next recenter
    /// (or the first sample) becomes forward. Callers: `AppModel.beginRoute` and the Hazards
    /// card's switch going on.
    func start() {
        guard !active else { return }
        active = true
        tracker.reset()
        yawDeg = nil
        isTracking = false
        samples = 0
    }

    /// Stop and forget (route stopped, arrival, the switch going off, ARKit paused).
    func stop() {
        active = false
        tracker.reset()
        yawDeg = nil
        isTracking = false
    }

    /// One face anchor, already reduced to a world yaw by `DepthEngine`'s anchor relay.
    /// - Parameters:
    ///   - worldYawDeg: `FaceYawGeometry.worldYawDegrees` of the anchor's forward axis.
    ///   - now: the ARKit frame clock (seconds) — the same clock the cue router uses.
    func ingest(worldYawDeg: Double, now: Double) {
        guard active else { return }
        lastNow = now
        samples &+= 1
        tracker.ingest(worldYawDeg: worldYawDeg, now: now)
        // Seed the reference from the first usable sample, so the beacon has a head direction
        // before the walker ever presses Recenter (`HeadPoseTracker` does the same).
        if tracker.referenceYaw == nil { tracker.recenterWhenReady(now: now) }
        refresh(now: now)
    }

    /// Re-read the tracker with the freshest clock we have. Called by `AppModel.handle(_:)` on
    /// every depth report (~30 Hz normal / up to 60 Hz high-rate), so "no face for 0.7 s" becomes nil while the walker looks away
    /// even though no face anchor is arriving to trigger it.
    /// - Parameter now: the ARKit clock of the newest depth report (`DepthEngine.report.timestamp`).
    func refresh(now: Double) {
        guard active else { return }
        let clock = max(now, lastNow)
        isTracking = tracker.isFresh(now: clock)
        yawDeg = tracker.yawDeg(now: clock)
    }

    /// The walker's current head direction becomes "straight ahead" (Recenter button, watch
    /// Recenter, auto-recenter when walking straight). Mirrors `HeadPoseTracker.recenter()`.
    func recenter() {
        tracker.recenter()
        refresh(now: lastNow)
    }

    /// Short line for the Hazards card, deliberately worded so it can never be read as a picture:
    /// "face found, head 12° right" / "no face in view" / "off".
    /// ⚠ The card's accessibility label is built from this; keep it a statement about *detection*.
    var readout: String {
        guard active else { return "off" }
        guard isTracking else { return "no face in view" }
        guard let yawDeg else { return "face found, centring" }
        let rounded = Int(yawDeg.rounded())
        if abs(rounded) <= 3 { return "face found, head straight ahead" }
        return "face found, head \(abs(rounded))° \(rounded > 0 ? "right" : "left")"
    }
}
