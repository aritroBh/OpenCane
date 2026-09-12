//
//  DepthFrameProcessor.swift
//  CaneKit
//
//  The only piece of CaneKit that runs off the main actor on a hot path. ARKit calls
//  `session(_:didUpdate:)` on `queue` at up to 60 Hz; we turn each frame into a `LaneReport`
//  (a Sendable value) and hand it to the main actor through an AsyncStream that keeps only
//  the newest report.
//
//  Thread-safety model: the class is `@unchecked Sendable`; every mutable field is behind
//  `settings` (a Mutex) or `imageLock`, or is "queue-only" (touched only on the serial `queue`;
//  `latestPublishedSequence()` reads `publishedCount` through `queue.sync`). Nothing here touches
//  UI or the main-actor model.
//  ARKit objects (ARFrame, CVPixelBuffer, ARMeshAnchor) never leave the callback except for
//  the single retained camera buffer used by `jpegSnapshot`.
//
//  Per-method context:
//    · `queue` (serial, via `SessionObserver`): `session(_:didUpdate:)`, `computeGrid`,
//      `rotationRate`, and every field marked "queue-only" below — no lock needed because the
//      queue is serial and nothing else touches them.
//    · main actor: `startMotion` / `stopMotion` (DepthEngine lifecycle), `settings` writes
//      (DepthEngine.apply / setMeshClassification / setHighFrameRate), `synchronize` and
//      `latestPublishedSequence` (both `queue.sync` — never call them *on* `queue`, it would
//      deadlock), `dropLatestImage` (DepthEngine pause and reconfiguration).
//    · any thread: `jpegSnapshot` (HazardScanner, AppModel's hazard photo, ConversationCoordinator)
//      and `jpegSnapshotWithDepth` (SceneDescriber), from `@concurrent` code, i.e. the global
//      executor, and `hasCameraFrame` (main) — all go through `imageLock` / `settings`.
//  The class is `nonisolated` (overriding the module's MainActor default) precisely so ARKit
//  can call it on `queue`; the `@unchecked Sendable` is justified by the locking model above,
//  not added to silence the compiler (AGENTS.md hard rule 1).
//
//  Budget: at 30 Hz a published frame has ~33 ms (60 Hz high-rate has ~16 ms). Frames between publishes return right after
//  the rate check; the lane math reads the 256×192 depth map in place (no copy), and the mesh
//  lookup is throttled to every 8th publish (`meshEveryNthFrame`: ≈ 3.75 Hz at 30 Hz, 7.5 Hz in
//  high-rate mode) and capped by `MeshClassifier.faceBudget`.
//
//  Owner: `DepthEngine` (one instance, `processor`). Frames arrive through `SessionObserver`.
//  Tests: the pure pieces it drives — `LaneMathTests` (lanes, `PublishGate`, `MountTilt`),
//  `HazardTests` (`GroundHazardDetector`), `DepthSnapshotTests`, `DepthReadinessTests`
//  (`frameSequence` continuity). The ARKit / CoreMotion / Core Image glue here is verified on the
//  phone (trip-log `fps`, `tilt`, `scan`, `describe_result`), not by a unit test.
//

import ARKit
import CaneKitLogic
import CoreImage
import CoreMotion
import Foundation
import ImageIO
import Synchronization

/// Runtime-tunable knobs, replaced atomically from the main actor.
/// ⚠ `sweepThreshold`, `maxRate` and `meshEveryNthFrame` were tuned against `CueDecider`'s
/// seconds-based timing and a real cane sweep; change them only with a device walk
/// (`CueDeciderTests.untrustedFramesFreezeState` assumes sweeps exceed 0.6 rad/s).
/// Lives inside `DepthFrameProcessor.settings` (a `Mutex`); the frame callback copies the whole
/// struct once per frame, so a frame never sees a half-applied change.
struct ProcessorSettings: Sendable {
    /// Lane geometry and orientation (portrait rotation, left/right mirror) for `LaneMath`.
    var lane = LaneConfig()
    /// |gyro| above this (rad/s) marks the frame untrusted (the cane is mid-sweep).
    var sweepThreshold: Float = 0.6
    /// Publish rate cap in Hz. The normal 30 Hz path keeps obstacle latency low without excess
    /// heat; high-frame-rate mode raises this to 60 so every camera frame is visible to the
    /// readiness interlock. CueDecider is timed in seconds, not frames.
    var maxRate: Double = 30
    /// Run the mesh-classification lookup at the image centre (step 4). Costs ~10–15 % CPU.
    /// Turned off by the thermal watchdog (`DepthEngine.setMeshClassification`).
    var meshLookupEnabled = true
    /// Mesh lookups happen every Nth published frame (30 Hz / 8 ≈ 3.75 Hz, the "~4 Hz" the docs
    /// quote; 7.5 Hz in 60 Hz high-rate mode). When the publish cap went 15 → 30 Hz this went 4 → 8
    /// so the costly part stayed at the same wall-clock rate. Between lookups the last hit is
    /// re-attached, so `centerHit` can be up to 7 published frames old.
    var meshEveryNthFrame = 8
    /// LiDAR ground-hazard detection (drop-offs, holes, curbs; GroundSampler + CaneKitLogic
    /// GroundHazardDetector). Evaluated on published frames at most every 0.1 s (up to 10 Hz).
    /// ⚠ `true` is only the struct default: `AppModel.pushDepthSettings()` overwrites it from init
    /// with the "Detect drop-offs" setting, which defaults **false** (untuned on the real cane).
    var groundHazardsEnabled = true
    /// |gyro| (rad/s) under which a frame is good enough for the *ground* path. Looser than
    /// `sweepThreshold`: GroundSampler registers every point through `camera.transform` in the
    /// gravity frame, so a moving cane does not corrupt the profile. With the lane gate (0.6) a
    /// 1 Hz sweep leaves ~2 evaluations/s and a curb confirmed only ~1.2–1.7 m ahead at 1.2 m/s;
    /// at ~7/s it confirms at ~2.3–2.6 m (review round 5 ray-cast simulation).
    var groundSweepThreshold: Float = 1.5
}

/// Turns ARKit frames into `LaneReport`s off the main actor and keeps the latest camera image
/// for "Where am I". Owned by `DepthEngine` (which exposes it to `SceneDescriber`); receives
/// frames through `SessionObserver`, not as the session's direct delegate.
nonisolated final class DepthFrameProcessor: NSObject, ARSessionDelegate, @unchecked Sendable {

    // MARK: Output

    /// Newest-only stream of reports for the main actor to consume.
    /// Buffer policy `.bufferingNewest(1)`: if main is busy, older reports are overwritten, so
    /// the consumer always sees the freshest depth (a stale warning is worse than a skipped one).
    /// Single consumer: `DepthEngine.startConsumer`.
    let reports: AsyncStream<LaneReport>
    /// Producer side of `reports`; yielded from `queue` only. Never finished.
    private let continuation: AsyncStream<LaneReport>.Continuation

    /// Serial queue ARKit delivers frames on. `userInteractive` because a late frame is a late warning.
    /// Installed as `ARSession.delegateQueue` by `DepthEngine.start()`.
    let queue = DispatchQueue(label: "canekit.depth", qos: .userInteractive)

    /// Snapshot the last published sequence on the processor's serial queue. `DepthEngine` uses
    /// this at a route-start transition to exclude a report already buffered in the newest-only
    /// stream but not yet consumed on the main actor.
    /// Blocks the caller until `queue` is free (`queue.sync`); main actor only, never on `queue`.
    func latestPublishedSequence() -> Int {
        queue.sync { publishedCount }
    }

    /// Drain callbacks already admitted by ARKit before a session configuration changes.
    /// `ARSession.run` can overlap the tail of the old configuration; synchronizing this serial
    /// queue gives `DepthEngine` a real hand-off boundary before it captures the next readiness
    /// baseline. Callers: `DepthEngine.pause`, `resume`, `setHighFrameRate`, `setFaceTracking`,
    /// `setMeshClassification`. Blocks until the in-flight frame (≤ one publish budget) finishes.
    func synchronize() {
        queue.sync { }
    }

    // MARK: State

    /// Tunables shared with the main actor. Written by `DepthEngine` (main: `apply`,
    /// `setMeshClassification`, `setHighFrameRate`), read once per frame on `queue` and by
    /// `encode` (any thread, for `lane.rotateForPortrait`).
    let settings = Mutex(ProcessorSettings())

    /// Gyro source for the sweep gate. Started/stopped on main by `DepthEngine`; pull mode (no
    /// handler, no queue) — `rotationRate` reads the latest `gyroData` sample on `queue`.
    private let motion = CMMotionManager()
    /// GPU-backed Core Image context for snapshot JPEG encoding; reused (creation is expensive).
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    /// Guards `latestImage` between the frame queue (writer) and snapshot callers (readers).
    private let imageLock = NSLock()
    /// Most recent camera frame (YCbCr, full video-format resolution) for `jpegSnapshot`.
    /// Exactly one buffer is retained; each frame replaces it.
    private var latestImage: CVPixelBuffer?            // guarded by imageLock
    /// `frame.timestamp` (ARKit's monotonic clock) of `latestImage`, guarded by imageLock. Used
    /// to prove the depth grid below belongs to the *same* frame — `systemUptime` cannot, because
    /// the image is retained on every frame and the grid only on published frames with depth.
    private var latestImageFrameTime: TimeInterval = 0
    /// Coarse scene-space depth grid of the most recent *published* frame, so "Where am I" can put
    /// a distance on anything Vision finds in `latestImage` (`DepthSnapshot`). Guarded by
    /// `imageLock` so a reader sees it paired with the image it belongs to. 19.3 us (measured) and
    /// one 1.5 kB array per published frame; empty on a frame without depth.
    private var latestDepth = DepthSnapshot.empty   // guarded by imageLock
    /// `frame.timestamp` of `latestDepth` (guarded by imageLock); 0 = no grid yet.
    private var latestDepthFrameTime: TimeInterval = 0
    /// How far apart (s, ARKit clock) the image and the depth grid may be and still describe the
    /// same moment. Three frames at the 30 Hz publish cap, ≈ 12 cm at 1.2 m/s. Beyond it the grid
    /// is discarded and the walker hears a direction with no distance: depth can drop out
    /// (relocalisation, `.limited` tracking) while camera frames keep flowing, and pairing a
    /// fresh image with a two-second-old grid would put a confident wrong number on a person
    /// (adversarial review of this change — `systemUptime` freshness alone did not catch it).
    static let maxDepthPairingSkew: TimeInterval = 0.1
    /// `ProcessInfo.systemUptime` when `latestImage` arrived (guarded by imageLock). A frame older
    /// than `maxFrameAge` is treated as absent: after an ARKit stall or interruption the last
    /// frame shows a corner the walker has left (Muse camera review).
    private var latestImageAt: TimeInterval = 0
    /// Seconds after which the retained frame is too old to describe or scan.
    static let maxFrameAge: TimeInterval = 2
    /// ARKit timestamp (s) of the last published report. Written on every publish but no longer
    /// read: `publishGate` keeps its own last-publish time and is what enforces the `maxRate` cap.
    private var lastPublished: TimeInterval = 0        // queue-only
    /// Rate cap for published reports (queue-only); see `ProcessorSettings.maxRate`. The 15 here
    /// is a placeholder from the 15 Hz era: `session(_:didUpdate:)` overwrites `maxRate` from
    /// `settings` before the first check. Tolerance and the 10-Hz-instead-of-15 bug it fixed:
    /// `PublishGate` (pinned by `LaneMathTests.publishGateHitsFifteenHertzFromThirtyHertzFrames`).
    private var publishGate = PublishGate(maxRate: 15)
    /// Published-report counter (wrapping); selects every Nth frame for a mesh lookup.
    private var publishedCount = 0                     // queue-only
    /// Reusable sample buffer handed to `LaneMath.computeLanes` so the hot path never allocates.
    private var scratch: [Float] = {                   // queue-only sample buffer
        var a = [Float](); a.reserveCapacity(2048); return a
    }()
    /// Last mesh lookup result, re-attached to the frames between lookups (so `centerHit` does
    /// not flicker between published frames); cleared when mesh lookup is disabled.
    private var lastMeshHit: MeshHit?                  // queue-only, reused between lookups
    /// Pure ground-hazard confirmer (CaneKitLogic): a hazard must agree in position on 3 of the
    /// last 5 evaluations. Reset whenever the ground path is switched off. Queue-only.
    private var groundDetector = GroundHazardDetector() // queue-only, confirms over frames
    /// Last confirmed ground hazard, re-attached to every report until the next evaluation
    /// (evaluations run at most every 0.1 s). Queue-only.
    private var lastGroundHazard: GroundHazard?         // queue-only, reused between evaluations
    /// ARKit time (s) of the last ground evaluation, for the 0.1 s spacing. Queue-only.
    private var lastGroundEval: TimeInterval = 0        // queue-only, ARKit clock
    /// Smoothed horizontal walking direction (world frame, unit length; ~0.5 s EMA at the normal
    /// 30 Hz publish rate), queue-only. nil until the first frame with a non-vertical camera.
    private var walkDirection: SIMD3<Float>?
    /// Metres walked along `walkDirection` since launch (signed; steps ≥ 1 m are ignored as
    /// relocalisation jumps). `GroundHazardDetector` uses it to check that a hazard stays put in
    /// the world as the walker approaches. Queue-only.
    private var travelled: Float = 0
    /// Horizontal camera position (world x, 0, z) at the previous published frame. Queue-only.
    private var lastCamPos: SIMD3<Float>?
    /// Camera look direction below the horizon (deg, + = down), EMA (factor 0.07, ~0.5 s at the
    /// normal 30 Hz rate) over **every published frame** — trusted or not, because the pose is
    /// gravity-aligned even mid-sweep — for the Mount card's "Camera tilt" line (MountTilt) and the
    /// ground path's `MountTilt.groundUsable` gate. nil before the first published frame. Queue-only.
    private var tiltDownDeg: Float?

    /// Builds the newest-only report stream. Called on main by `DepthEngine`'s property
    /// initialiser; the processor does nothing until ARKit delivers frames.
    override init() {
        let (stream, cont) = AsyncStream.makeStream(of: LaneReport.self, bufferingPolicy: .bufferingNewest(1))
        reports = stream
        continuation = cont
        super.init()
    }

    // MARK: Gyro (sweep gate)

    /// Raw gyro at 60 Hz; we poll `gyroData` per frame instead of taking a callback so the
    /// gate and the depth sample refer to the same instant.
    /// Idempotent. Called on main by `DepthEngine.start()` / `resume()`.
    func startMotion() {
        guard motion.isGyroAvailable, !motion.isGyroActive else { return }
        motion.gyroUpdateInterval = 1.0 / 60.0
        motion.startGyroUpdates()
    }

    /// Stop the gyro (battery). Called on main by `DepthEngine.pause()`. Afterwards
    /// `rotationRate` reads the last cached sample or 0.
    func stopMotion() {
        motion.stopGyroUpdates()
    }

    /// Magnitude |ω| of the latest raw gyro sample, rad/s; 0 before the first sample (frames
    /// then count as trusted). Read on `queue`.
    private var rotationRate: Float {
        guard let rr = motion.gyroData?.rotationRate else { return 0 }
        return Float((rr.x * rr.x + rr.y * rr.y + rr.z * rr.z).squareRoot())
    }

    // MARK: ARSessionDelegate (runs on `queue`)

    /// Per-frame pipeline, on `queue` (forwarded by `SessionObserver`, up to 60 Hz):
    /// 1. retain the camera image (every frame, under `imageLock`);
    /// 2. snapshot `settings`, drop the frame unless `publishGate` admits it (1 / `maxRate` s,
    ///    4 ms tolerance); count it in `publishedCount` (the report's `frameSequence`);
    /// 3. sweep gate: `isTrusted = |ω| < sweepThreshold`; read `trackingNormal` from this frame;
    ///    update the camera tilt EMA (every published frame);
    /// 4. depth → `LaneGrid` + `DepthSnapshot` (or an empty, `depthAvailable: false` report if
    ///    depth is missing); store the snapshot beside the image under `imageLock`;
    /// 5. mesh lookup every `meshEveryNthFrame`th publish (reusing the last hit in between);
    /// 6. ground path when enabled: walk tracking every publish, evaluation ≤ every 0.1 s on frames
    ///    under `groundSweepThreshold` with a mount-like tilt;
    /// 7. yield the report into the newest-only stream.
    /// Must return quickly: ARKit recycles a small pool of frames and stalls if they are held.
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Keep the latest camera image for "Where am I". One buffer only — ARKit recycles
        // a small pool and stalls if we hoard them.
        imageLock.lock()
        latestImage = frame.capturedImage
        latestImageAt = ProcessInfo.processInfo.systemUptime
        latestImageFrameTime = frame.timestamp
        imageLock.unlock()

        let s = settings.withLock { $0 }
        let now = frame.timestamp
        // PublishGate (CaneKitLogic) tolerates the floating-point hair that made a 15 Hz cap run at
        // exactly 10 Hz on 30 Hz ARKit frames (first iPhone run).
        publishGate.maxRate = s.maxRate
        guard publishGate.shouldPublish(at: now) else { return }
        lastPublished = now
        publishedCount &+= 1

        let ω = rotationRate
        let trusted = ω < s.sweepThreshold
        // Read tracking from this exact frame. `ARSessionDelegate.cameraDidChangeTrackingState`
        // is a separate asynchronous callback, so the main-actor string in `DepthEngine` can lag
        // the depth map by a frame or two; route-start readiness must not accept that stale value.
        let trackingNormal: Bool = {
            if case .normal = frame.camera.trackingState { return true }
            return false
        }()
        trackTilt(frame)   // every frame: the pose is gravity-aligned even mid-sweep (Muse); the EMA smooths the sweep

        guard let (grid, snapshot) = computeGrid(frame: frame, config: s.lane) else {
            continuation.yield(LaneReport(grid: .empty, isTrusted: trusted, rotationRate: ω,
                                          timestamp: now, depthAvailable: false,
                                          trackingNormal: trackingNormal,
                                          frameSequence: publishedCount, centerHit: nil,
                                          cameraTiltDownDeg: tiltDownDeg))
            return
        }

        // Keep the depth grid next to the retained image, stamped with the same ARKit frame time
        // (`now` *is* `frame.timestamp`, above), so "Where am I" can prove the pair came from one
        // moment — see `takeLatest`. A Muse pass read these as two different clocks; they are not.
        imageLock.lock()
        latestDepth = snapshot
        latestDepthFrameTime = now
        imageLock.unlock()

        // Mesh classification at the image centre (step 4 fills `MeshClassifier`); throttled.
        if s.meshLookupEnabled, publishedCount % max(1, s.meshEveryNthFrame) == 0 {
            lastMeshHit = MeshClassifier.nearestFace(to: grid.centerDepth, in: frame)
        } else if !s.meshLookupEnabled {
            lastMeshHit = nil
        }

        // Ground profile (drop-offs / holes / curbs). Walking direction and distance walked are
        // tracked on every published frame; the (costlier) evaluation runs at most every 0.1 s on
        // frames under the ground path's own, looser gyro gate (`groundSweepThreshold`), so the
        // fastest part of a sweep never uses up confirmation slots but the turnarounds and
        // slow sweeps all count.
        if s.groundHazardsEnabled {
            trackWalk(frame)
            // Only with a mount-like camera aim (MountTilt.groundUsable, 0-15 deg down): hand-held
            // at a desk it called desk edges a hole (first real-phone test).
            if ω < s.groundSweepThreshold, now - lastGroundEval >= 0.1,
               MountTilt.groundUsable(downDeg: tiltDownDeg ?? 90) {
                lastGroundEval = now
                lastGroundHazard = groundDetector.update(
                    GroundSampler.samples(frame: frame, walkDirection: walkDirection),
                    trusted: true, travelled: travelled, time: now)
            }
        } else {
            lastGroundHazard = nil
            groundDetector.reset()
        }

        continuation.yield(LaneReport(grid: grid, isTrusted: trusted, rotationRate: ω,
                                      timestamp: now, depthAvailable: true,
                                      trackingNormal: trackingNormal,
                                      frameSequence: publishedCount, centerHit: lastMeshHit,
                                      groundHazard: lastGroundHazard, cameraTiltDownDeg: tiltDownDeg))
    }

    /// Not called in practice (`SessionObserver` is the session delegate and handles failures);
    /// kept as an explicit no-op in case the processor is ever installed as the delegate directly.
    func session(_ session: ARSession, didFailWithError error: Error) {
        // Surfaced through DepthEngine's session observer; nothing to do on the queue.
    }

    /// Smooths the camera's angle below the horizon (queue-only). ARKit's world is gravity-aligned
    /// (+Y up) and the camera looks along −Z of `camera.transform`, whatever the device orientation.
    /// EMA factor 0.07 per published frame, seeded by the first; sign pinned by
    /// `LaneMathTests.tiltSignIsDownPositive` (`MountTilt.downDegrees`).
    private func trackTilt(_ frame: ARFrame) {
        let deg = MountTilt.downDegrees(cameraZColumnY: frame.camera.transform.columns.2.y)
        tiltDownDeg = tiltDownDeg.map { $0 + 0.07 * (deg - $0) } ?? deg
    }

    /// Updates the smoothed walking direction and the distance walked along it (queue-only).
    /// Camera forward (−Z column) flattened to horizontal; ignored when shorter than 0.2 (camera
    /// pointing at the sky or the feet), else folded in with `simd_mix` 0.07. Only runs while the
    /// ground path is enabled. ⚠ Keep the `|step| < 1` guard and pass `walkDirection` (not the
    /// camera forward) to `GroundSampler`: `HazardTests` `sweepFramesDoNotConfirm` /
    /// `aCurbYouWalkTowardStillConfirms` assume both.
    private func trackWalk(_ frame: ARFrame) {
        let T = frame.camera.transform
        var f = -SIMD3<Float>(T.columns.2.x, T.columns.2.y, T.columns.2.z)
        f.y = 0
        if simd_length(f) > 0.2 {
            f = simd_normalize(f)
            walkDirection = walkDirection.map { simd_normalize(simd_mix($0, f, SIMD3(repeating: 0.07))) } ?? f
        }
        let pos = SIMD3<Float>(T.columns.3.x, 0, T.columns.3.z)
        if let last = lastCamPos, let w = walkDirection {
            let step = simd_dot(pos - last, w)
            if abs(step) < 1 { travelled += step }        // ignore relocalisation jumps
        }
        lastCamPos = pos
    }

    // MARK: Depth → lanes

    /// Prefers the temporally smoothed map (less flicker at the normal 30 Hz cadence) and falls back to raw depth.
    ///
    /// Locks the depth (and confidence, if present) buffers read-only for the duration of the
    /// call and hands raw base addresses to the pure `LaneMath.computeLanes` (CaneKitLogic,
    /// unit-tested), which fills head / torso lane distances (m) and `centerDepth`.
    /// Returns nil when the frame has no depth or an unexpected pixel format (not Float32).
    /// On `queue` only (uses `scratch`).
    /// - Returns: the lane grid the cue path needs **and** the coarse `DepthSnapshot` the scene
    ///   describer needs, both read from the same locked buffers so they can never disagree.
    ///   Measured on the same 256x192 buffers: the snapshot adds 19.3 us to the lane pass's
    ///   47.0 us, i.e. 0.06 % of a 33 ms frame at the 30 Hz publish cap (DepthSnapshot header).
    private func computeGrid(frame: ARFrame, config: LaneConfig) -> (LaneGrid, DepthSnapshot)? {
        guard let depth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let depthMap = depth.depthMap
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else { return nil }
        let confMap = depth.confidenceMap

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        if let confMap { CVPixelBufferLockBaseAddress(confMap, .readOnly) }
        defer { if let confMap { CVPixelBufferUnlockBaseAddress(confMap, .readOnly) } }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let confBase = confMap.flatMap { CVPixelBufferGetBaseAddress($0) }

        let depthStride = CVPixelBufferGetBytesPerRow(depthMap)
        let confStride = confMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)

        let grid = LaneMath.computeLanes(
            depth: depthBase,
            depthBytesPerRow: depthStride,
            confidence: confBase,
            confidenceBytesPerRow: confStride,
            width: w,
            height: h,
            config: config,
            scratch: &scratch)
        // Unmirrored on purpose: the camera image the describer sends to Vision is only rotated
        // (`jpegSnapshot`), never mirrored, so the grid must line up with Vision's boxes.
        // `mirrorLeftRight` is applied to the spoken word instead (`PeopleAhead.bearing`).
        let snapshot = DepthSnapshot.make(
            depth: depthBase,
            depthBytesPerRow: depthStride,
            confidence: confBase,
            confidenceBytesPerRow: confStride,
            width: w,
            height: h,
            rotateForPortrait: config.rotateForPortrait,
            minConfidence: config.minConfidence)
        return (grid, snapshot)
    }

    // MARK: Snapshot for the scene describer

    /// JPEG of the most recent camera frame, rotated upright when the phone is portrait,
    /// long edge ≤ `maxDimension`. Safe from any thread; ~30–80 ms on device, so callers
    /// run it with `@concurrent`.
    ///
    /// Copies the buffer reference under `imageLock` and encodes outside it, so the frame queue
    /// is never blocked by encoding. Portrait rotation follows `settings.lane.rotateForPortrait`
    /// (the same flag the lanes use). Returns nil before the first frame, when the frame is older
    /// than `maxFrameAge`, or if encoding fails. In the simulator with `FrameReplay` active it
    /// returns the replay JPEG as-is (no resize, no rotation).
    /// Holding the buffer during encoding briefly keeps one extra ARKit buffer alive.
    /// Callers (all off main, via `@concurrent`): `HazardScanner.snapshot` (signs / hazard watch),
    /// `AppModel.frame` (768 px hazard-map photo), `ConversationCoordinator` (defaults).
    /// "Where am I" uses `jpegSnapshotWithDepth` instead.
    /// - Parameters:
    ///   - maxDimension: long-edge cap in pixels (downscale only).
    ///   - quality: JPEG lossy quality 0…1.
    func jpegSnapshot(maxDimension: CGFloat = 1024, quality: CGFloat = 0.7) -> Data? {
        // Simulator e2e: Street View frames stand in for the camera (FrameReplay; inert on device).
        if FrameReplay.shared.isActive { return FrameReplay.shared.jpeg() }
        guard let latest = takeLatest() else { return nil }
        return encode(latest.buffer, maxDimension: maxDimension, quality: quality)
    }

    /// The same JPEG **and** the depth grid of the same ARKit frame, or nil when there is no fresh
    /// camera frame. The grid is `.empty` unless it provably belongs to that frame
    /// (`maxDepthPairingSkew`), so a person can never be given a distance measured elsewhere.
    /// Safe from any thread; the encode happens outside the lock.
    /// Caller: `SceneDescriber.snapshot` (off main, via `@concurrent`).
    /// - Parameters:
    ///   - maxDimension: long-edge cap in pixels (downscale only).
    ///   - quality: JPEG lossy quality 0…1.
    func jpegSnapshotWithDepth(maxDimension: CGFloat = 1024,
                               quality: CGFloat = 0.7) -> (jpeg: Data, depth: DepthSnapshot)? {
        // Replay frames (simulator e2e) have no LiDAR behind them: direction, never a distance.
        if FrameReplay.shared.isActive {
            guard let jpeg = FrameReplay.shared.jpeg() else { return nil }
            return (jpeg, .empty)
        }
        guard let latest = takeLatest(),
              let jpeg = encode(latest.buffer, maxDimension: maxDimension, quality: quality) else { return nil }
        return (jpeg, latest.depth)
    }

    /// The retained camera frame and the depth grid that belongs to it, in **one** critical
    /// section. nil before the first frame or when it is older than `maxFrameAge`.
    ///
    /// Two separate lock-guarded reads did not make a pair: the image is retained on every ARKit
    /// frame while the grid is written only on published frames *that have depth*, so a depth
    /// dropout (relocalisation, `.limited` tracking — exactly when the walker is turning) could
    /// hand out a fresh image with a grid up to `maxFrameAge` = 2 s old and speak a confident
    /// wrong distance. ARKit frame timestamps are compared instead (adversarial review).
    private func takeLatest() -> (buffer: CVPixelBuffer, depth: DepthSnapshot)? {
        imageLock.lock(); defer { imageLock.unlock() }
        guard let buffer = latestImage,
              ProcessInfo.processInfo.systemUptime - latestImageAt <= Self.maxFrameAge else { return nil }
        // `abs`: in practice the image is always stamped first in the same callback, so the skew
        // is 0 or positive — but a signed test that silently accepts every negative value is the
        // kind of thing a reorder turns into a wrong spoken distance (Muse).
        let skew = abs(latestImageFrameTime - latestDepthFrameTime)
        let paired = latestDepthFrameTime > 0 && skew <= Self.maxDepthPairingSkew
        return (buffer, paired ? latestDepth : .empty)
    }

    /// One camera buffer → an upright JPEG, long edge ≤ `maxDimension`. Never called with
    /// `imageLock` held, so the frame queue is not blocked by encoding. Portrait rotation follows
    /// `settings.lane.rotateForPortrait` (the same flag the lanes use) and applies **no** mirror,
    /// which is why `DepthSnapshot` is built unmirrored too. sRGB via the shared GPU `ciContext`;
    /// nil if the colour space or the encode fails.
    /// - Parameters:
    ///   - buffer: the retained `capturedImage` (YCbCr).
    ///   - maxDimension: long-edge cap in pixels (downscale only).
    ///   - quality: JPEG lossy quality 0…1.
    private func encode(_ buffer: CVPixelBuffer, maxDimension: CGFloat, quality: CGFloat) -> Data? {
        let rotate = settings.withLock { $0.lane.rotateForPortrait }
        var image = CIImage(cvPixelBuffer: buffer)
        if rotate { image = image.oriented(.right) }
        let longEdge = max(image.extent.width, image.extent.height)
        if longEdge > maxDimension {
            let s = maxDimension / longEdge
            image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
        ]
        return ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: options)
    }

    /// Forget the retained camera frame and its depth grid (both timestamps back to 0). Called by
    /// `DepthEngine.pause()`: after a background / foreground cycle the old frame shows a place the
    /// walker has left, and "Where am I" or the sign scan must wait for a fresh one instead of
    /// describing it (review round 5). Also called before every session re-run
    /// (`setHighFrameRate`, `setFaceTracking`, `setMeshClassification`). Thread-safe (`imageLock`).
    func dropLatestImage() {
        imageLock.lock()
        latestImage = nil
        latestImageFrameTime = 0
        latestDepth = .empty
        latestDepthFrameTime = 0
        imageLock.unlock()
    }

    /// True once a camera frame has been retained since the session last (re)started (used by
    /// the "camera warming up" guard) and it is no older than `maxFrameAge`; always true while
    /// `FrameReplay` is active. Thread-safe (takes `imageLock`); polled on main every
    /// 100 ms by `SceneDescriber.describe` for up to 3 s. False again after `dropLatestImage()`.
    var hasCameraFrame: Bool {
        if FrameReplay.shared.isActive { return true }
        imageLock.lock(); defer { imageLock.unlock() }
        return latestImage != nil && ProcessInfo.processInfo.systemUptime - latestImageAt <= Self.maxFrameAge
    }
}
