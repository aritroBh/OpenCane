//
//  GroundSampler.swift
//  CaneKit
//
//  Turns one ARFrame's LiDAR depth into `GroundSample`s in the walker's frame, for the ground
//  hazard detector (CaneKitLogic.GroundHazardDetector: drop-offs, potholes, curbs, low obstacles).
//
//  Geometry: every `stride`-th depth pixel (u, v) with depth d is back-projected with the camera
//  intrinsics (scaled from the captured-image resolution to the depth-map resolution) into ARKit
//  camera space (+x right, +y up, −z forward, in the sensor's landscape orientation — so this is
//  correct however the phone is held), then into world space with `camera.transform`. The world
//  is gravity-aligned (DepthEngine runs `worldAlignment = .gravity`), so the sample's height is
//  simply `world.y − camera.y`, and "forward" is the camera's look direction flattened onto the
//  horizontal plane. That makes the detector independent of the cane's tilt and of the mount angle.
//
//  Threading / isolation: a `nonisolated` caseless enum of pure static functions, called only from
//  `DepthFrameProcessor.session(_:didUpdate:)` on the depth queue; the ARFrame never escapes.
//  Cost: 256×192 map at stride 4 → ≤ 3,072 samples, one 4×4 multiply each (< 1 ms).
//

import ARKit
import CaneKitLogic
import simd

nonisolated enum GroundSampler {

    /// Pixels further than this (m) are ignored: LiDAR is weak past ~5 m and the detector only
    /// scans to 3.5 m ahead.
    static let maxDepth: Float = 4.5
    /// Pixels closer than this (m) are ignored (the cane shaft, a hand in front of the lens).
    static let minDepth: Float = 0.3

    /// - Parameters:
    ///   - frame: the current ARFrame (depth + camera).
    ///   - stride: sample every Nth pixel in both directions.
    ///   - minConfidence: ARConfidenceLevel raw value (0 low, 1 medium, 2 high). Medium drops the
    ///     grazing-angle returns that make ground far away noisy.
    /// - Returns: samples in the walker's frame, or `[]` when there is no depth or the phone is
    ///   pointing (almost) straight up or down so "forward" is undefined.
    ///   - walkDirection: smoothed horizontal walking direction (world, unit). The corridor must
    ///     follow the *walk*, not the cane: trusted frames happen at the sweep turnarounds where
    ///     the camera points ±20° off the path, which put curbs, planters and walls beside the
    ///     sidewalk inside the corridor (review simulation). nil = the camera's own forward.
    static func samples(frame: ARFrame, walkDirection: SIMD3<Float>? = nil,
                        stride: Int = 4, minConfidence: UInt8 = 1) -> [GroundSample] {
        // Raw depth first: the smoothed map blends several frames, which smears the ground
        // profile while the cane is moving (the ground path accepts faster frames than the lanes).
        guard let depth = frame.sceneDepth ?? frame.smoothedSceneDepth else { return [] }
        let map = depth.depthMap
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32 else { return [] }
        let conf = depth.confidenceMap

        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        if let conf { CVPixelBufferLockBaseAddress(conf, .readOnly) }
        defer { if let conf { CVPixelBufferUnlockBaseAddress(conf, .readOnly) } }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return [] }
        let confBase = conf.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confRow = conf.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        let row = CVPixelBufferGetBytesPerRow(map)

        // Intrinsics are given for `camera.imageResolution`; scale them to the depth map.
        let res = frame.camera.imageResolution
        let sx = Float(w) / Float(res.width), sy = Float(h) / Float(res.height)
        let K = frame.camera.intrinsics
        let fx = K[0][0] * sx, fy = K[1][1] * sy
        let cx = K[2][0] * sx, cy = K[2][1] * sy

        let T = frame.camera.transform
        let camPos = SIMD3<Float>(T.columns.3.x, T.columns.3.y, T.columns.3.z)
        var fwd = walkDirection ?? -SIMD3<Float>(T.columns.2.x, T.columns.2.y, T.columns.2.z)
        fwd.y = 0
        guard simd_length(fwd) > 0.2 else { return [] }        // pointing at the sky or the feet
        fwd = simd_normalize(fwd)
        let right = simd_normalize(simd_cross(fwd, SIMD3<Float>(0, 1, 0)))

        var out: [GroundSample] = []
        out.reserveCapacity((w / stride) * (h / stride))
        var v = 0
        while v < h {
            let depthRow = base.advanced(by: v * row).assumingMemoryBound(to: Float32.self)
            var u = 0
            while u < w {
                let d = depthRow[u]
                if d.isFinite, d >= minDepth, d <= maxDepth {
                    let confident = confBase.map {
                        $0.load(fromByteOffset: v * confRow + u, as: UInt8.self) >= minConfidence
                    } ?? true
                    if confident {
                        let xc = (Float(u) - cx) / fx * d
                        let yc = -(Float(v) - cy) / fy * d
                        let world4 = T * SIMD4<Float>(xc, yc, -d, 1)
                        let rel = SIMD3<Float>(world4.x, world4.y, world4.z) - camPos
                        out.append(GroundSample(forward: simd_dot(rel, fwd),
                                                lateral: simd_dot(rel, right),
                                                height: rel.y))
                    }
                }
                u += stride
            }
            v += stride
        }
        return out
    }
}
