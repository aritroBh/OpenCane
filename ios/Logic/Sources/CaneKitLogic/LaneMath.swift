//
//  LaneMath.swift
//  CaneKitLogic
//
//  Splits a LiDAR depth map into 3 lanes (L/C/R) × 2 bands (head/torso) and reports the
//  10th-percentile depth per cell, plus a median depth at the image center for mesh lookup.
//  Pure function over raw buffers so the app can pass CVPixelBuffer memory without copying
//  and the tests can pass plain arrays.
//
//  Purpose: the first step of the obstacle pipeline. `DepthFrameProcessor` (app) calls the raw
//  entry point on every ARKit depth frame (~30 Hz normal / up to 60 Hz high-rate); the resulting `LaneGrid` goes into a
//  `LaneReport`, which `CueDecider` turns into haptic cues.
//
//  Key invariants:
//    · Depth is Float32 metres; confidence is UInt8 (0 low / 1 medium / 2 high); medium must
//      be accepted. A sample is valid only if finite and > 0.05 m.
//    · Both row strides are honoured (CVPixelBuffer rows are padded).
//    · Portrait remap (phone upright on the cane): bufX = sceneY, bufY = bufH − 1 − sceneX.
//    · Output index 0 = left, 1 = centre, 2 = right; band 0 (top) = head, band 1 = torso;
//      `.infinity` = clear / too few samples. The centre window ignores the ground skip.
//    · No allocation per frame: the caller owns `scratch`; one caller at a time.
//  Tests: LaneMathTests.swift (11 tests; orientation is only verifiable on hardware).
//

import Foundation

/// Tunables for `LaneMath.computeLanes`.
public struct LaneConfig: Sendable, Equatable {
    /// Phone held upright → the landscape sensor buffer is the scene rotated 90° CCW (EXIF 6).
    /// Pinned by `landscapeModeUsesBufferAsScene` (off) and every portrait test (on).
    public var rotateForPortrait = true
    /// Swap L/R (phone mounted facing the other way). Pinned by `mirrorSwapsLeftAndRight`.
    public var mirrorLeftRight = false
    /// ARKit confidence: 0 low, 1 medium, 2 high. Pixels below this are ignored.
    /// Pinned by `lowConfidencePixelsAreIgnored`, `rawEntrypointHonoursPaddedRowStrides`.
    public var minConfidence: UInt8 = 1
    /// Bottom fraction of the upright image skipped as ground. Pinned by `groundBandIsSkipped`.
    public var groundSkipFraction: Float = 0.25
    /// Sample every Nth pixel on both axes (clamped to ≥ 1).
    public var subsampleStep = 4
    /// Fewer valid samples than this → the cell reports `.infinity` (clear).
    public var minSamplesPerCell = 8
    /// Which percentile of the sorted samples to report (0.10 = "the nearest 10 % of the cell").
    /// Pinned by `tenthPercentileNeedsMoreThanTenPercentOfCell`.
    public var percentile: Float = 0.10
    /// Side of the square window (scene pixels) used for `centerDepth`.
    public var centerWindow = 16

    /// Creates the default portrait, unmirrored, medium-confidence configuration.
    public init() {}
}

/// Result of one depth frame. Index 0 = left, 1 = center, 2 = right. `.infinity` = clear / no data.
public struct LaneGrid: Sendable, Equatable {
    /// Top band (waist-to-head obstacles the cane cannot find), metres per lane.
    public var head: [Float]
    /// Lower band above the ground skip (torso height), metres per lane.
    public var torso: [Float]
    /// Median depth of the centre window (for the mesh classification lookup). `.infinity` if unknown.
    public var centerDepth: Float

    /// All cells and the centre clear (`.infinity`) — the value before the first depth frame.
    public static let empty = LaneGrid(head: [.infinity, .infinity, .infinity],
                                       torso: [.infinity, .infinity, .infinity],
                                       centerDepth: .infinity)

    /// - Parameters:
    ///   - head: three head-band depths, metres (left, centre, right).
    ///   - torso: three torso-band depths, metres (left, centre, right).
    ///   - centerDepth: centre-window median, metres.
    public init(head: [Float], torso: [Float], centerDepth: Float) {
        self.head = head
        self.torso = torso
        self.centerDepth = centerDepth
    }

    /// Closest thing in a lane across both bands.
    /// - Parameter lane: 0 left, 1 centre, 2 right.
    /// - Returns: metres (`.infinity` when clear).
    public func nearest(lane: Int) -> Float { min(head[lane], torso[lane]) }
}

/// The depth-map → lane-grid reduction. Stateless.
public enum LaneMath {

    /// Reduce one depth frame to a `LaneGrid` (raw entry point used by the app over
    /// CVPixelBuffer memory).
    /// - Parameters:
    ///   - depth: base address of a Float32 depth map (metres), `width` × `height`, row stride `depthBytesPerRow`.
    ///   - depthBytesPerRow: bytes per depth row (≥ width × 4; may include padding).
    ///   - confidence: optional UInt8 map with the same dimensions, row stride `confidenceBytesPerRow`.
    ///   - confidenceBytesPerRow: bytes per confidence row (ignored when `confidence` is nil).
    ///   - width: sensor-buffer width in pixels (landscape).
    ///   - height: sensor-buffer height in pixels (landscape).
    ///   - config: tunables.
    ///   - scratch: reusable sample buffer (avoids per-frame allocation).
    /// - Returns: per-cell 10th-percentile depths and the centre median, metres.
    /// Pinned by `rawEntrypointHonoursPaddedRowStrides` (and via the array overload, every
    /// LaneMathTests case).
    public static func computeLanes(
        depth: UnsafeRawPointer,
        depthBytesPerRow: Int,
        confidence: UnsafeRawPointer?,
        confidenceBytesPerRow: Int,
        width bufW: Int,
        height bufH: Int,
        config: LaneConfig,
        scratch: inout [Float]
    ) -> LaneGrid {
        let rotate = config.rotateForPortrait
        let step = max(1, config.subsampleStep)

        // Scene-space dimensions (what the pedestrian sees: x left→right, y top→bottom).
        let sceneW = rotate ? bufH : bufW
        let sceneH = rotate ? bufW : bufH
        let usableH = max(2, Int(Float(sceneH) * (1 - config.groundSkipFraction)))
        let bandH = usableH / 2
        let laneW = sceneW / 3

        // Reads one scene-space pixel through the portrait remap; nil when low-confidence,
        // non-finite or ≤ 5 cm.
        @inline(__always) func sample(sx: Int, sy: Int) -> Float? {
            let bx = rotate ? sy : sx
            let by = rotate ? (bufH - 1 - sx) : sy
            if let confidence {
                let c = confidence.load(fromByteOffset: by * confidenceBytesPerRow + bx, as: UInt8.self)
                if c < config.minConfidence { return nil }
            }
            let d = depth.load(fromByteOffset: by * depthBytesPerRow + bx * MemoryLayout<Float>.stride, as: Float.self)
            return (d.isFinite && d > 0.05) ? d : nil
        }

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
                        if let d = sample(sx: sx, sy: sy) { scratch.append(d) }
                        sx += step
                    }
                    sy += step
                }
                var value: Float = .infinity
                if scratch.count >= config.minSamplesPerCell {
                    scratch.sort()
                    let idx = min(scratch.count - 1, Int(Float(scratch.count) * config.percentile))
                    value = scratch[idx]
                }
                let outLane = config.mirrorLeftRight ? (2 - lane) : lane
                if band == 0 { head[outLane] = value } else { torso[outLane] = value }
            }
        }

        // Centre window (full image centre, independent of the ground skip) → median.
        scratch.removeAll(keepingCapacity: true)
        let half = max(1, config.centerWindow / 2)
        let cx = sceneW / 2, cy = sceneH / 2
        var sy = max(0, cy - half)
        while sy < min(sceneH, cy + half) {
            var sx = max(0, cx - half)
            while sx < min(sceneW, cx + half) {
                if let d = sample(sx: sx, sy: sy) { scratch.append(d) }
                sx += 2
            }
            sy += 2
        }
        var center: Float = .infinity
        if scratch.count >= 4 {
            scratch.sort()
            center = scratch[scratch.count / 2]
        }

        return LaneGrid(head: head, torso: torso, centerDepth: center)
    }

    /// Convenience for tests and offline replay: arrays instead of raw pointers.
    /// Assumes tight rows (`width × 4` bytes for depth, `width` for confidence).
    /// - Parameters:
    ///   - depth: `width × height` depths in metres, row-major.
    ///   - confidence: optional `width × height` confidence map (0/1/2).
    ///   - width: buffer width in pixels.
    ///   - height: buffer height in pixels.
    ///   - config: tunables (default portrait).
    /// - Returns: the same grid the raw entry point would produce.
    /// - Precondition: array sizes equal `width × height`.
    public static func computeLanes(
        depth: [Float],
        confidence: [UInt8]?,
        width: Int,
        height: Int,
        config: LaneConfig = LaneConfig()
    ) -> LaneGrid {
        precondition(depth.count == width * height)
        var scratch = [Float]()
        scratch.reserveCapacity(1024)
        return depth.withUnsafeBytes { dbuf in
            if let confidence {
                precondition(confidence.count == width * height)
                return confidence.withUnsafeBytes { cbuf in
                    computeLanes(depth: dbuf.baseAddress!, depthBytesPerRow: width * 4,
                                 confidence: cbuf.baseAddress!, confidenceBytesPerRow: width,
                                 width: width, height: height, config: config, scratch: &scratch)
                }
            }
            return computeLanes(depth: dbuf.baseAddress!, depthBytesPerRow: width * 4,
                                confidence: nil, confidenceBytesPerRow: 0,
                                width: width, height: height, config: config, scratch: &scratch)
        }
    }
}
