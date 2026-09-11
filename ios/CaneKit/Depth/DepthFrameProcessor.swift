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

import ARKit
import CaneKitLogic
import CoreImage
import CoreMotion
import Foundation
import ImageIO
import Synchronization

/// Runtime-tunable knobs, replaced atomically from the main actor.
struct ProcessorSettings: Sendable {
    var lane = LaneConfig()
    /// |gyro| above this (rad/s) marks the frame untrusted (the cane is mid-sweep).
    var sweepThreshold: Float = 0.6
    /// Publish rate cap in Hz. ARKit runs at 60; the cue logic needs ~15.
    var maxRate: Double = 15
    /// Run the mesh-classification lookup at the image centre (step 4). Costs ~10–15 % CPU.
    var meshLookupEnabled = true
    /// Mesh lookups happen every Nth published frame (15 Hz / 4 ≈ 4 Hz).
    var meshEveryNthFrame = 4
}

nonisolated final class DepthFrameProcessor: NSObject, ARSessionDelegate, @unchecked Sendable {

    // MARK: Output

    /// Newest-only stream of reports for the main actor to consume.
    let reports: AsyncStream<LaneReport>
    private let continuation: AsyncStream<LaneReport>.Continuation

    /// Serial queue ARKit delivers frames on. `userInteractive` because a late frame is a late warning.
    let queue = DispatchQueue(label: "canekit.depth", qos: .userInteractive)

    // MARK: State

    let settings = Mutex(ProcessorSettings())

    private let motion = CMMotionManager()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let imageLock = NSLock()
    private var latestImage: CVPixelBuffer?            // guarded by imageLock
    private var lastPublished: TimeInterval = 0        // queue-only
    private var publishedCount = 0                     // queue-only
    private var scratch: [Float] = {                   // queue-only sample buffer
        var a = [Float](); a.reserveCapacity(2048); return a
    }()
    private var lastMeshHit: MeshHit?                  // queue-only, reused between lookups

    override init() {
        let (stream, cont) = AsyncStream.makeStream(of: LaneReport.self, bufferingPolicy: .bufferingNewest(1))
        reports = stream
        continuation = cont
        super.init()
    }

    // MARK: Gyro (sweep gate)

    /// Raw gyro at 60 Hz; we poll `gyroData` per frame instead of taking a callback so the
    /// gate and the depth sample refer to the same instant.
    func startMotion() {
        guard motion.isGyroAvailable, !motion.isGyroActive else { return }
        motion.gyroUpdateInterval = 1.0 / 60.0
        motion.startGyroUpdates()
    }

    func stopMotion() {
        motion.stopGyroUpdates()
    }

    private var rotationRate: Float {
        guard let rr = motion.gyroData?.rotationRate else { return 0 }
        return Float((rr.x * rr.x + rr.y * rr.y + rr.z * rr.z).squareRoot())
    }

    // MARK: ARSessionDelegate (runs on `queue`)

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

        guard let grid = computeGrid(frame: frame, config: s.lane) else {
            continuation.yield(LaneReport(grid: .empty, isTrusted: trusted, rotationRate: ω,
                                          timestamp: now, depthAvailable: false, centerHit: nil))
            return
        }

        // Mesh classification at the image centre (step 4 fills `MeshClassifier`); throttled.
        if s.meshLookupEnabled, publishedCount % max(1, s.meshEveryNthFrame) == 0 {
            lastMeshHit = MeshClassifier.nearestFace(to: grid.centerDepth, in: frame)
        } else if !s.meshLookupEnabled {
            lastMeshHit = nil
        }

        continuation.yield(LaneReport(grid: grid, isTrusted: trusted, rotationRate: ω,
                                      timestamp: now, depthAvailable: true, centerHit: lastMeshHit))
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        // Surfaced through DepthEngine's session observer; nothing to do on the queue.
    }

    // MARK: Depth → lanes

    /// Prefers the temporally smoothed map (less flicker at 15 Hz) and falls back to raw depth.
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
    func jpegSnapshot(maxDimension: CGFloat = 1024, quality: CGFloat = 0.7) -> Data? {
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

    /// True once at least one camera frame has been retained (used by the "camera warming up" guard).
    var hasCameraFrame: Bool {
        imageLock.lock(); defer { imageLock.unlock() }
        return latestImage != nil
    }
}
