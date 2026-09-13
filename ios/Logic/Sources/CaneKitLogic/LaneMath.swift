//
//  LaneMath.swift
//  CaneKitLogic
//
//  Splits a LiDAR depth map into 3 lanes (L/C/R) × 2 bands (head/torso) and reports the
//  10th-percentile depth per cell, plus a median depth at the image center for mesh lookup.
//  Pure function over raw buffers so the app can pass CVPixelBuffer memory without copying
//  and the tests can pass plain arrays.
//
//  Purpose: the first step of the obstacle pipeline. `DepthFrameProcessor.computeGrid` (app, on
//  its serial depth queue) calls the raw entry point on every frame that passes its `PublishGate`
//  (~30 Hz normal / up to 60 Hz high-rate); the resulting `LaneGrid` goes into a `LaneReport`,
//  which `CueDecider` turns into haptic cues. The same buffers also feed `DepthSnapshot.make`.
//
//  Key invariants:
//    · Depth is Float32 metres; confidence is UInt8 (0 low / 1 medium / 2 high); medium must
//      be accepted. A sample is valid only if finite and > 0.05 m; a sample that is NOT (0, NaN,
//      ≤ 5 cm — what the LiDAR emits inside its saturation range) is counted as *blind*, and the
//      fraction of blind samples per cell travels with the grid (`LaneGrid.headBlind` /
//      `torsoBlind`, Step 48) so `NearHold` can tell "nothing there" from "too close to read".
//    · Both row strides are honoured (CVPixelBuffer rows are padded).
//    · Portrait remap (phone upright on the cane): bufX = sceneY, bufY = bufH − 1 − sceneX.
//    · Output index 0 = left, 1 = centre, 2 = right; band 0 (top) = head, band 1 = torso;
//      `.infinity` = clear / too few samples. The centre window ignores the ground skip.
//    · No allocation per frame: the caller owns `scratch`; one caller at a time.
//    · ⚠ No gravity correction: the ground skip is a fixed image fraction, so the mount must aim
//      the camera 3–8° below the horizon (`MountTilt`, LaneReport.swift).
//  Tests: LaneMathTests.swift (15 tests: 10 for the lane grid, plus `TileLevel`, `MountTilt` and
//  `PublishGate` pins; orientation is only verifiable on hardware).
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
    /// Sample every Nth pixel on both axes (clamped to ≥ 1): 4 reads 1 pixel in 16 of ARKit's
    /// 256 × 192 depth map (the centre window always samples every 2nd pixel).
    public var subsampleStep = 4
    /// Fewer valid samples than this → the cell reports `.infinity` (clear).
    public var minSamplesPerCell = 8
    /// Which percentile of the sorted samples to report (0.10 = "the nearest 10 % of the cell").
    /// Pinned by `tenthPercentileNeedsMoreThanTenPercentOfCell`.
    public var percentile: Float = 0.10
    /// Side of the square window (scene pixels) used for `centerDepth`.
    public var centerWindow = 16
    /// Depth threshold below which low-confidence readings are accepted as an obstacle (m).
    /// At < 35 cm iPhone LiDAR SPAD saturation marks returns confidence 0; treating them as clear
    /// creates an inverted safety gradient where point-blank walls appear clear.
    public var closeOverrideThreshold: Float = 0.35

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
    /// Fraction (0…1) of each head cell's sampled pixels that were blind — 0, NaN or ≤ 5 cm, the
    /// LiDAR's answer inside its saturation range (Step 48). 0 when the cell read normally.
    public var headBlind: [Float]
    /// Same for the torso band.
    public var torsoBlind: [Float]
    /// Per head cell: the value was substituted by `NearHold` (a blind cell right after a near
    /// reading), not measured this frame. Logged so a held STOP is visible as held.
    public var headHeld: [Bool]
    /// Same for the torso band.
    public var torsoHeld: [Bool]

    /// All cells and the centre clear (`.infinity`) — the value before the first depth frame.
    public static let empty = LaneGrid(head: [.infinity, .infinity, .infinity],
                                       torso: [.infinity, .infinity, .infinity],
                                       centerDepth: .infinity)

    /// - Parameters:
    ///   - head: three head-band depths, metres (left, centre, right).
    ///   - torso: three torso-band depths, metres (left, centre, right).
    ///   - centerDepth: centre-window median, metres.
    ///   - headBlind / torsoBlind: blind fractions per cell (default 0: every sample valid).
    ///   - headHeld / torsoHeld: `NearHold` substitution flags (default false).
    public init(head: [Float], torso: [Float], centerDepth: Float,
                headBlind: [Float] = [0, 0, 0], torsoBlind: [Float] = [0, 0, 0],
                headHeld: [Bool] = [false, false, false], torsoHeld: [Bool] = [false, false, false]) {
        self.head = head
        self.torso = torso
        self.centerDepth = centerDepth
        self.headBlind = headBlind
        self.torsoBlind = torsoBlind
        self.headHeld = headHeld
        self.torsoHeld = torsoHeld
    }

    /// Closest thing in a lane across both bands.
    /// - Parameter lane: 0 left, 1 centre, 2 right (not range-checked: other values trap).
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
        // non-finite or ≤ 5 cm. Proximity overrides confidence: returns < closeOverrideThreshold (35 cm)
        // represent near-field physical presence (where LiDAR saturation drops confidence to 0) rather than noise.
        // A non-finite / ≤ 5 cm read also increments `blind` (Step 48): inside ~10 cm the LiDAR
        // returns 0 or NaN, and a cell that is mostly blind is not empty — it is too close to read.
        var blind = 0
        @inline(__always) func sample(sx: Int, sy: Int) -> Float? {
            let bx = rotate ? sy : sx
            let by = rotate ? (bufH - 1 - sx) : sy
            let d = depth.load(fromByteOffset: by * depthBytesPerRow + bx * MemoryLayout<Float>.stride, as: Float.self)
            guard d.isFinite, d > 0.05 else { blind += 1; return nil }
            if d < config.closeOverrideThreshold {
                return d
            }
            if let confidence {
                let c = confidence.load(fromByteOffset: by * confidenceBytesPerRow + bx, as: UInt8.self)
                if c < config.minConfidence { return nil }
            }
            return d
        }

        var head = [Float](repeating: .infinity, count: 3)
        var torso = [Float](repeating: .infinity, count: 3)
        var headBlind = [Float](repeating: 0, count: 3)
        var torsoBlind = [Float](repeating: 0, count: 3)

        for band in 0..<2 {
            let sy0 = band * bandH
            let sy1 = sy0 + bandH
            for lane in 0..<3 {
                let sx0 = lane * laneW
                let sx1 = sx0 + laneW
                scratch.removeAll(keepingCapacity: true)
                blind = 0
                var sampled = 0
                var sy = sy0
                while sy < sy1 {
                    var sx = sx0
                    while sx < sx1 {
                        if let d = sample(sx: sx, sy: sy) { scratch.append(d) }
                        sampled += 1
                        sx += step
                    }
                    sy += step
                }
                // Share of the *readable* samples that were blind: far low-confidence pixels are
                // neither valid nor blind and must not dilute a wall edge (Muse F6). `sampled`
                // is kept for the empty-cell case.
                let readable = blind + scratch.count
                let blindFraction: Float = readable > 0 ? Float(blind) / Float(readable) : (sampled > 0 ? 0 : 0)
                var value: Float = .infinity
                if scratch.count >= config.minSamplesPerCell {
                    scratch.sort()
                    let idx = min(scratch.count - 1, Int(Float(scratch.count) * config.percentile))
                    value = scratch[idx]
                }
                let outLane = config.mirrorLeftRight ? (2 - lane) : lane
                if band == 0 { head[outLane] = value; headBlind[outLane] = blindFraction }
                else { torso[outLane] = value; torsoBlind[outLane] = blindFraction }
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

        return LaneGrid(head: head, torso: torso, centerDepth: center,
                        headBlind: headBlind, torsoBlind: torsoBlind)
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
