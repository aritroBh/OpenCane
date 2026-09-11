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
//  `settings` (a Mutex) or `imageLock`. Nothing here touches UI or the main-actor model.
//  ARKit objects (ARFrame, CVPixelBuffer, ARMeshAnchor) never leave the callback except for
//  the single retained camera buffer used by `jpegSnapshot`.
//
//  Per-method context:
//    · `queue` (serial, via `SessionObserver`): `session(_:didUpdate:)`, `computeGrid`,
//      `rotationRate`, and every field marked "queue-only" below — no lock needed because the
//      queue is serial and nothing else touches them.
//    · main actor: `startMotion` / `stopMotion` (DepthEngine lifecycle), `settings` writes
//      (DepthEngine.apply / setMeshClassification).
//    · any thread: `jpegSnapshot` (SceneDescriber, `@concurrent`, i.e. the global executor) and
//      `hasCameraFrame` (main) — both go through `imageLock` / `settings`.
//  The class is `nonisolated` (overriding the module's MainActor default) precisely so ARKit
//  can call it on `queue`; the `@unchecked Sendable` is justified by the locking model above,
//  not added to silence the compiler (AGENTS.md hard rule 1).
//
//  Budget: at 15 Hz a published frame has ~66 ms. Frames between publishes return right after
//  the rate check; the lane math reads the 256×192 depth map in place (no copy), and the mesh
//  lookup is throttled to every 4th publish and capped by `MeshClassifier.faceBudget`.
//

import ARKit
import CaneKitLogic
import CoreImage
import CoreMotion
import Foundation
import ImageIO
import Synchronization

/// Runtime-tunable knobs, replaced atomically from the main actor.
/// Lives inside `DepthFrameProcessor.settings` (a `Mutex`); the frame callback copies the whole
/// struct once per frame, so a frame never sees a half-applied change.
struct ProcessorSettings: Sendable {
    /// Lane geometry and orientation (portrait rotation, left/right mirror) for `LaneMath`.
    var lane = LaneConfig()
    /// |gyro| above this (rad/s) marks the frame untrusted (the cane is mid-sweep).
    var sweepThreshold: Float = 0.6
    /// Publish rate cap in Hz. ARKit runs at 60; the cue logic needs ~15.
    var maxRate: Double = 15
    /// Run the mesh-classification lookup at the image centre (step 4). Costs ~10–15 % CPU.
    /// Turned off by the thermal watchdog (`DepthEngine.setMeshClassification`).
    var meshLookupEnabled = true
    /// Mesh lookups happen every Nth published frame (15 Hz / 4 ≈ 4 Hz).
    var meshEveryNthFrame = 4
    /// LiDAR ground-hazard detection (drop-offs, holes, curbs; GroundSampler + CaneKitLogic
    /// GroundHazardDetector). Evaluated on published frames at most every 0.1 s (~7 Hz).
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

    // MARK: State

    /// Tunables shared with the main actor. Written by `DepthEngine` (main), read once per frame
    /// on `queue` and by `jpegSnapshot` (any thread).
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
    /// ARKit timestamp (s) of the last published report; drives the `maxRate` cap.
    private var lastPublished: TimeInterval = 0        // queue-only
    /// Published-report counter (wrapping); selects every Nth frame for a mesh lookup.
    private var publishedCount = 0                     // queue-only
    /// Reusable sample buffer handed to `LaneMath.computeLanes` so the hot path never allocates.
    private var scratch: [Float] = {                   // queue-only sample buffer
        var a = [Float](); a.reserveCapacity(2048); return a
    }()
    /// Last mesh lookup result, re-attached to the frames between lookups (so `centerHit` does
    /// not flicker to nil at 15 Hz); cleared when mesh lookup is disabled.
    private var lastMeshHit: MeshHit?                  // queue-only, reused between lookups
    private var groundDetector = GroundHazardDetector() // queue-only, confirms over frames
    private var lastGroundHazard: GroundHazard?         // queue-only, reused between evaluations
    private var lastGroundEval: TimeInterval = 0        // queue-only, ARKit clock
    /// Smoothed horizontal walking direction (~1 s EMA of the camera forward), queue-only.
    private var walkDirection: SIMD3<Float>?
    /// Metres walked along `walkDirection` since launch, and the last camera position.
    private var travelled: Float = 0
    private var lastCamPos: SIMD3<Float>?
    /// Camera look direction below the horizon (deg, + = down), ~1 s EMA of trusted frames, for
    /// the Mount card's "Camera tilt" line (MountTilt). Queue-only.
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
    /// 2. snapshot `settings`, drop the frame if < 1 / `maxRate` s since the last publish;
    /// 3. sweep gate: `isTrusted = |ω| < sweepThreshold`;
    /// 4. depth → `LaneGrid` (or an empty, `depthAvailable: false` report if depth is missing);
    /// 5. mesh lookup every `meshEveryNthFrame`th publish (reusing the last hit in between);
    /// 6. yield the report into the newest-only stream.
    /// Must return quickly: ARKit recycles a small pool of frames and stalls if they are held.
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Keep the latest camera image for "Where am I". One buffer only — ARKit recycles
        // a small pool and stalls if we hoard them.
        imageLock.lock()
        latestImage = frame.capturedImage
        imageLock.unlock()

        let s = settings.withLock { $0 }
        let now = frame.timestamp
        guard now - lastPublished >= 1.0 / s.maxRate else { return }
        lastPublished = now
        publishedCount &+= 1

        let ω = rotationRate
        let trusted = ω < s.sweepThreshold
        if trusted { trackTilt(frame) }

        guard let grid = computeGrid(frame: frame, config: s.lane) else {
            continuation.yield(LaneReport(grid: .empty, isTrusted: trusted, rotationRate: ω,
                                          timestamp: now, depthAvailable: false, centerHit: nil,
                                          cameraTiltDownDeg: tiltDownDeg))
            return
        }

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
            if ω < s.groundSweepThreshold, now - lastGroundEval >= 0.1 {
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
                                      timestamp: now, depthAvailable: true, centerHit: lastMeshHit,
                                      groundHazard: lastGroundHazard, cameraTiltDownDeg: tiltDownDeg))
    }

    /// Not called in practice (`SessionObserver` is the session delegate and handles failures);
    /// kept as an explicit no-op in case the processor is ever installed as the delegate directly.
    func session(_ session: ARSession, didFailWithError error: Error) {
        // Surfaced through DepthEngine's session observer; nothing to do on the queue.
    }

    /// Smooths the camera's angle below the horizon (queue-only). ARKit's world is gravity-aligned
    /// (+Y up) and the camera looks along −Z of `camera.transform`, whatever the device orientation.
    private func trackTilt(_ frame: ARFrame) {
        let T = frame.camera.transform
        let lookY = -T.columns.2.y                       // vertical part of the look direction
        let deg = asin(max(-1, min(1, -lookY))) * 180 / .pi
        tiltDownDeg = tiltDownDeg.map { $0 + 0.07 * (deg - $0) } ?? deg
    }

    /// Updates the smoothed walking direction and the distance walked along it (queue-only).
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

    /// Prefers the temporally smoothed map (less flicker at 15 Hz) and falls back to raw depth.
    ///
    /// Locks the depth (and confidence, if present) buffers read-only for the duration of the
    /// call and hands raw base addresses to the pure `LaneMath.computeLanes` (CaneKitLogic,
    /// unit-tested), which fills head / torso lane distances (m) and `centerDepth`.
    /// Returns nil when the frame has no depth or an unexpected pixel format (not Float32).
    /// On `queue` only (uses `scratch`).
    private func computeGrid(frame: ARFrame, config: LaneConfig) -> LaneGrid? {
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

        return LaneMath.computeLanes(
            depth: depthBase,
            depthBytesPerRow: CVPixelBufferGetBytesPerRow(depthMap),
            confidence: confBase,
            confidenceBytesPerRow: confMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0,
            width: CVPixelBufferGetWidth(depthMap),
            height: CVPixelBufferGetHeight(depthMap),
            config: config,
            scratch: &scratch)
    }

    // MARK: Snapshot for the scene describer

    /// JPEG of the most recent camera frame, rotated upright when the phone is portrait,
    /// long edge ≤ `maxDimension`. Safe from any thread; ~30–80 ms on device, so callers
    /// run it with `@concurrent`.
    ///
    /// Copies the buffer reference under `imageLock` and encodes outside it, so the frame queue
    /// is never blocked by encoding. Portrait rotation follows `settings.lane.rotateForPortrait`
    /// (the same flag the lanes use). Returns nil before the first frame or if encoding fails.
    /// Holding the buffer during encoding briefly keeps one extra ARKit buffer alive.
    /// Caller: `SceneDescriber.snapshot` (off main, via `@concurrent`).
    /// - Parameters:
    ///   - maxDimension: long-edge cap in pixels (downscale only).
    ///   - quality: JPEG lossy quality 0…1.
    func jpegSnapshot(maxDimension: CGFloat = 1024, quality: CGFloat = 0.7) -> Data? {
        // Simulator e2e: Street View frames stand in for the camera (FrameReplay; inert on device).
        if FrameReplay.shared.isActive { return FrameReplay.shared.jpeg() }
        imageLock.lock()
        let buffer = latestImage
        imageLock.unlock()
        guard let buffer else { return nil }

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

    /// Forget the retained camera frame. Called by `DepthEngine.pause()`: after a background /
    /// foreground cycle the old frame shows a place the walker has left, and "Where am I" or the
    /// sign scan must wait for a fresh one instead of describing it (review round 5).
    func dropLatestImage() {
        imageLock.lock()
        latestImage = nil
        imageLock.unlock()
    }

    /// True once a camera frame has been retained since the session last (re)started (used by
    /// the "camera warming up" guard). Thread-safe (takes `imageLock`); polled on main every
    /// 100 ms by `SceneDescriber.describe` for up to 3 s. False again after `dropLatestImage()`.
    var hasCameraFrame: Bool {
        if FrameReplay.shared.isActive { return true }
        imageLock.lock(); defer { imageLock.unlock() }
        return latestImage != nil
    }
}
