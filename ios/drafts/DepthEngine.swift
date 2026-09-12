//
//  DepthEngine.swift
//  CaneKit
//
//  ARKit LiDAR depth → 3 lanes (L/C/R) × 2 bands (head/torso) of 10th-percentile
//  distance, with gyro sweep gating and a held camera frame for scene description.
//
//  Threading: ARSession delegate runs on `sessionQueue`. Everything published
//  (`report`, `statusMessage`, …) and the `onReport` callback are delivered on main.
//

import ARKit
import CoreMotion
import CoreImage
import CoreVideo
import ImageIO
import Observation
import UIKit

// MARK: - LaneReport

struct LaneReport: Equatable {
    /// Distances in metres, index 0 = left, 1 = center, 2 = right. `.infinity` = nothing / no data.
    var head: [Float] = [.infinity, .infinity, .infinity]
    var torso: [Float] = [.infinity, .infinity, .infinity]
    /// True when the gyro says the cane is being swept faster than the threshold.
    var isSweeping = false
    /// |rotation rate| in rad/s (for the debug footer).
    var rotationRate: Float = 0
    var timestamp: TimeInterval = 0
    /// False until the first sceneDepth frame arrives (or on non-LiDAR devices).
    var depthAvailable = false

    /// Closest thing in a lane across both bands.
    func nearest(lane: Int) -> Float {
        min(head[lane], torso[lane])
    }
}

// MARK: - DepthEngine

@Observable
final class DepthEngine: NSObject, ARSessionDelegate {

    // Published (main thread)
    private(set) var report = LaneReport()
    private(set) var statusMessage = "Depth idle"
    private(set) var isRunning = false
    private(set) var framesProcessed = 0

    // Configuration (read by the processing queue each frame; set from main)
    /// Phone held portrait → depth map must be rotated. See README.
    var rotateForPortrait = true
    /// Swap L/R (phone mounted the other way round).
    var mirrorLeftRight = false
    /// Pixels below this ARKit confidence are ignored.
    var minConfidence: ARConfidenceLevel = .medium
    /// Sweep gate: frames with |gyro| ≥ this (rad/s) are marked `isSweeping`.
    var sweepThreshold: Float = 0.6
    /// Bottom fraction of the (upright) image to skip as ground.
    var groundSkipFraction: Float = 0.25
    /// Sample every Nth pixel in both axes.
    var subsampleStep = 4
    /// A cell with fewer valid samples than this reports `.infinity` (treated as clear).
    var minSamplesPerCell = 8
    /// Cap on processing rate (Hz). ARKit delivers 60 fps; we don't need that.
    var maxProcessingRate: Double = 20

    @ObservationIgnored var onReport: ((LaneReport) -> Void)?

    static let supportsSceneDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)

    // Private
    @ObservationIgnored private let session = ARSession()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "canekit.depth", qos: .userInitiated)
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    @ObservationIgnored private var configuration: ARWorldTrackingConfiguration?
    @ObservationIgnored private var lastProcessed: TimeInterval = 0
    @ObservationIgnored private var scratch: [Float] = {
        var a = [Float](); a.reserveCapacity(1024); return a
    }()
    @ObservationIgnored private let imageLock = NSLock()
    @ObservationIgnored private var latestImage: CVPixelBuffer?

    // MARK: Lifecycle

    func start() {
        guard Self.supportsSceneDepth else {
            setStatus("No LiDAR / sceneDepth on this device")
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth]        // alternative: .smoothedSceneDepth (temporally filtered, ~1 frame lag)
        config.worldAlignment = .gravity
        config.isAutoFocusEnabled = true
        config.planeDetection = []                   // we don't need planes; saves CPU
        configuration = config

        session.delegate = self
        session.delegateQueue = sessionQueue
        session.run(config, options: [.resetTracking, .removeExistingAnchors])

        if motion.isGyroAvailable {
            motion.gyroUpdateInterval = 1.0 / 60.0
            motion.startGyroUpdates()                // we poll `motion.gyroData` per frame
        }
        isRunning = true
        setStatus("Waiting for depth…")
    }

    func pause() {
        session.pause()
        isRunning = false
        setStatus("Depth paused")
    }

    func resume() {
        guard let configuration else { start(); return }
        session.run(configuration)                   // no reset: keep tracking
        isRunning = true
        setStatus("Depth resuming…")
    }

    func stop() {
        session.pause()
        motion.stopGyroUpdates()
        isRunning = false
        setStatus("Depth stopped")
    }

    // MARK: Snapshot for SceneDescriber

    /// JPEG of the most recent camera frame, rotated upright if `rotateForPortrait`,
    /// downscaled so the long edge ≤ `maxDimension`. Safe to call from any thread.
    func jpegSnapshot(maxDimension: CGFloat = 1024, quality: CGFloat = 0.7) -> Data? {
        imageLock.lock()
        let pixelBuffer = latestImage
        imageLock.unlock()
        guard let pixelBuffer else { return nil }

        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if rotateForPortrait {
            image = image.oriented(.right)           // EXIF 6: rotate 90° CW to display upright
        }
        let longEdge = max(image.extent.width, image.extent.height)
        if longEdge > maxDimension {
            let s = maxDimension / longEdge
            image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
        ]
        return ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: options)
    }

    // MARK: ARSessionDelegate (runs on sessionQueue)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Keep the latest camera image for "Describe scene". Holding ONE CVPixelBuffer
        // is fine; holding ARFrames (or many buffers) makes ARKit drop frames.
        imageLock.lock()
        latestImage = frame.capturedImage
        imageLock.unlock()

        let now = frame.timestamp
        guard now - lastProcessed >= 1.0 / maxProcessingRate else { return }
        lastProcessed = now

        // Sweep gating from raw gyro.
        var rotationRate: Float = 0
        if let rr = motion.gyroData?.rotationRate {
            rotationRate = Float((rr.x * rr.x + rr.y * rr.y + rr.z * rr.z).squareRoot())
        }
        let sweeping = rotationRate >= sweepThreshold

        guard var r = computeLanes(frame: frame) else {
            let empty = LaneReport(isSweeping: sweeping, rotationRate: rotationRate, timestamp: now, depthAvailable: false)
            publish(empty, status: "No depth in frame")
            return
        }
        r.isSweeping = sweeping
        r.rotationRate = rotationRate
        r.timestamp = now
        publish(r, status: "Depth OK")
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        setStatus("AR error: \(error.localizedDescription)")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        setStatus("AR interrupted")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        setStatus("AR resumed")
    }

    // MARK: Depth processing

    /// Splits the depth map into 3 lanes × 2 bands in *scene* space (what the pedestrian sees:
    /// x = left→right, y = top→bottom), skipping the bottom `groundSkipFraction`, and returns the
    /// 10th-percentile depth of each cell.
    ///
    /// Buffer layout: ARKit depth/camera buffers are landscape (256×192) in sensor orientation.
    /// With the phone held upright (portrait, camera at top) the buffer is the scene rotated
    /// 90° CCW, i.e. EXIF orientation 6:
    ///     buffer column 0 (x = 0)      = visual TOP of the scene
    ///     buffer column W-1            = visual BOTTOM (ground)
    ///     buffer row 0    (y = 0)      = visual RIGHT
    ///     buffer row H-1               = visual LEFT
    /// So for portrait: bufferX = sceneY, bufferY = (H-1) - sceneX.
    private func computeLanes(frame: ARFrame) -> LaneReport? {
        guard let sceneDepth = frame.sceneDepth else { return nil }
        let depthMap = sceneDepth.depthMap
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else { return nil }
        let confMap = sceneDepth.confidenceMap

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        if let confMap { CVPixelBufferLockBaseAddress(confMap, .readOnly) }
        defer { if let confMap { CVPixelBufferUnlockBaseAddress(confMap, .readOnly) } }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let bufW = CVPixelBufferGetWidth(depthMap)       // 256 on current LiDAR iPhones
        let bufH = CVPixelBufferGetHeight(depthMap)      // 192
        let depthBPR = CVPixelBufferGetBytesPerRow(depthMap)

        let confBase = confMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confBPR = confMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let minConf = UInt8(clamping: minConfidence.rawValue)

        // Snapshot config once per frame.
        let rotate = rotateForPortrait
        let mirror = mirrorLeftRight
        let step = max(1, subsampleStep)
        let minSamples = minSamplesPerCell
        let groundSkip = groundSkipFraction

        // Scene-space dimensions.
        let sceneW = rotate ? bufH : bufW
        let sceneH = rotate ? bufW : bufH
        let usableH = max(2, Int(Float(sceneH) * (1 - groundSkip)))
        let bandH = usableH / 2
        let laneW = sceneW / 3

        var head = [Float](repeating: .infinity, count: 3)
        var torso = [Float](repeating: .infinity, count: 3)

        for band in 0..<2 {
            let sy0 = band * bandH
            let sy1 = sy0 + bandH
            for lane in 0..<3 {
                let sx0 = lane * laneW
                let sx1 = sx0 + laneW
                scratch.removeAll(keepingCapacity: true)

                var sy = sy0
                while sy < sy1 {
                    var sx = sx0
                    while sx < sx1 {
                        let bx = rotate ? sy : sx
                        let by = rotate ? (bufH - 1 - sx) : sy
                        var ok = true
                        if let confBase {
                            let c = confBase.load(fromByteOffset: by * confBPR + bx, as: UInt8.self)
                            ok = c >= minConf
                        }
                        if ok {
                            let d = depthBase.load(fromByteOffset: by * depthBPR + bx * MemoryLayout<Float>.stride, as: Float.self)
                            if d.isFinite && d > 0.05 {
                                scratch.append(d)
                            }
                        }
                        sx += step
                    }
                    sy += step
                }

                var value: Float = .infinity
                if scratch.count >= minSamples {
                    scratch.sort()
                    value = scratch[scratch.count / 10]      // 10th percentile
                }
                let outLane = mirror ? (2 - lane) : lane
                if band == 0 { head[outLane] = value } else { torso[outLane] = value }
            }
        }

        return LaneReport(head: head, torso: torso, depthAvailable: true)
    }

    // MARK: Publishing (hop to main)

    private func publish(_ r: LaneReport, status: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.report = r
            self.framesProcessed &+= 1
            if self.statusMessage != status { self.statusMessage = status }
            self.onReport?(r)
        }
    }

    private func setStatus(_ s: String) {
        if Thread.isMainThread {
            statusMessage = s
        } else {
            DispatchQueue.main.async { [weak self] in self?.statusMessage = s }
        }
    }
}
