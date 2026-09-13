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
//  Two band modes (Step 51, `LaneBandMode`):
//    · **metric** (the phone on the cane, ARKit has a pose): every sample is placed by its height
//      above the ground, `h = cameraHeight + depth · g(u, v)`, where `g` comes from the world-up
//      row of ARKit's camera transform (`LaneGeometry`, the same back-projection as
//      `GroundSampler`). Floor (< 25 cm) is dropped, 25–140 cm is torso, ≥ 140 cm is head. The
//      heights are integer centimetres (owner decision 2026-09-13); the depths stay metres.
//      A cell the camera cannot see at head height (the cane holds the phone ~45° down; at that
//      pitch nothing above ~0.6 m is in view at 1.5 m) reports `.infinity` AND `headCoverage`
//      false — never NaN or −1, so every `.infinity == clear` consumer behaves unchanged and only
//      the readers that must tell "clear" from "cannot see" (`HeadGate`, `TileLevel`, `NearHold`,
//      the Mount card, the trip log) look at the flag.
//    · **rows** (no pose yet, the first few hundred ms of a session, and every pre-Step-51 test):
//      the bottom `groundSkipFraction` of the upright image is ground, the rest is split in half.
//      This is what the first cane walk ran: at 45° the "head" rows looked at knee height and the
//      "torso" rows at the floor 1.45 m away (CHANGELOG Step 51).
//
//  Key invariants:
//    · Depth is Float32 metres; confidence is UInt8 (0 low / 1 medium / 2 high); medium must
//      be accepted. A sample is valid only if finite and > 0.05 m; a sample that is NOT (0, NaN,
//      ≤ 5 cm — what the LiDAR emits inside its saturation range) is counted as *blind*, and the
//      fraction of blind samples per cell travels with the grid (`LaneGrid.headBlind` /
//      `torsoBlind`, Step 48) so `NearHold` can tell "nothing there" from "too close to read".
//      In metric mode a blind pixel counts toward its *nominal* band (where its ray would be at
//      `coverageRangeCm`), so a wall against the lens still blinds the cells it normally feeds.
//    · Both row strides are honoured (CVPixelBuffer rows are padded).
//    · Portrait remap (phone upright on the cane): bufX = sceneY, bufY = bufH − 1 − sceneX.
//    · Output index 0 = left, 1 = centre, 2 = right; band 0 = head, band 1 = torso;
//      `.infinity` = clear / too few samples / no coverage. The centre window ignores the ground
//      skip (rows) and drops floor samples (metric).
//    · No allocation per frame beyond the two band buffers the metric path keeps: the caller owns
//      `scratch`; one caller at a time.
//  Tests: LaneMathTests.swift (rows mode, `TileLevel`, `MountTilt`, `PublishGate` pins) and
//  LaneGeometryTests.swift (metric mode: a synthetic pinhole renders floor / wall / sign / person /
//  box at a given pitch, roll and camera height; orientation is only verifiable on hardware).
//

import Foundation

/// How the two bands were cut: fixed image rows (no pose yet) or gravity-aligned metric heights.
/// The raw value is the trip log's `lanes.bands` field (`ios/scripts/cue_audit.py` reads it).
public enum LaneBandMode: String, Sendable, Codable {
    /// Bottom `groundSkipFraction` skipped, the rest split in half — pre-pose and the old tests.
    case rows
    /// Every sample bucketed by its height above ground (`LaneGeometry`).
    case metric
}

/// Where the camera is and how it looks, reduced to what the height of a depth sample needs:
/// scaled depth-map intrinsics plus the world-up components of the camera's three axes.
///
/// Height above the ground of the sample at buffer pixel `(u, v)` with z-depth `d` (metres):
/// `h = cameraHeight + d · g(u, v)`, `g = upX·(u−cx)/fx − upY·(v−cy)/fy − upZ`. This is the
/// y-component of `T · (xc, yc, −d, 1)` with `xc = (u−cx)/fx · d`, `yc = −(v−cy)/fy · d` — the
/// exact back-projection `GroundSampler` uses — so it compensates roll for free and works in the
/// landscape buffer coordinates `LaneMath` already has; nothing about the portrait remap has to
/// be reasoned about here. `upZ = sin(tilt down)` is what `MountTilt.downDegrees` already reads.
///
/// Built per frame by `DepthFrameProcessor.computeGrid` from `ARFrame.camera.intrinsics`
/// (scaled to the depth map exactly as `GroundSampler` scales them) and `camera.transform`
/// (`columns.0.y`, `.1.y`, `.2.y`); nil while ARKit has no pose. Logged once per distinct set of
/// intrinsics as `depth_geometry`. Pinned by `pitchOnlyGeometryMatchesTheTransformRow` and every
/// LaneGeometryTests case.
public struct LaneGeometry: Sendable, Equatable {
    /// Focal lengths in depth-map pixels (landscape buffer coordinates).
    public var fx, fy: Float
    /// Principal point in depth-map pixels (landscape buffer coordinates).
    public var cx, cy: Float
    /// World-up (gravity) component of the camera's x, y and z axes: `T.columns.0.y`, `.1.y`,
    /// `.2.y` of ARKit's gravity-aligned camera transform. For a portrait-up phone pitched θ down,
    /// `(−cos θ, 0, sin θ)`.
    public var upX, upY, upZ: Float

    /// - Parameters: see the stored properties; all in depth-map pixels / unit vector components.
    public init(fx: Float, fy: Float, cx: Float, cy: Float, upX: Float, upY: Float, upZ: Float) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.upX = upX
        self.upY = upY
        self.upZ = upZ
    }

    /// Tests, docs and offline replay: a camera with no roll, pitched `downDeg` below the horizon.
    /// Portrait (the cane): buffer u runs down the scene, so the camera x axis has up-component
    /// −cos θ, the y axis is horizontal (0) and the z axis (backward) has +sin θ. Landscape:
    /// `(0, cos θ, sin θ)`.
    /// - Parameters:
    ///   - downDeg: pitch below the horizon, degrees (positive = down).
    ///   - portrait: phone upright (default) or landscape.
    ///   - fx / fy / cx / cy: depth-map intrinsics.
    public static func pitchOnly(downDeg: Float, portrait: Bool = true, fx: Float, fy: Float, cx: Float, cy: Float) -> LaneGeometry {
        let rad = downDeg * .pi / 180
        let sinT = sin(rad)
        let cosT = cos(rad)
        if portrait {
            return LaneGeometry(fx: fx, fy: fy, cx: cx, cy: cy, upX: -cosT, upY: 0, upZ: sinT)
        } else {
            return LaneGeometry(fx: fx, fy: fy, cx: cx, cy: cy, upX: 0, upY: cosT, upZ: sinT)
        }
    }

    /// Height gained per metre of z-depth along the ray through buffer pixel `(u, v)`
    /// (dimensionless; positive = the ray climbs). One multiply-add per sample.
    @inline(__always)
    public func heightGain(u: Int, v: Int) -> Float {
        upX * (Float(u) - cx) / fx - upY * (Float(v) - cy) / fy - upZ
    }

    /// Height above the ground, in centimetres, of the sample at `(u, v)` with z-depth `depthM`
    /// metres from a camera `cameraHeightCm` above the ground. The one place the metre depth is
    /// converted (owner decision 2026-09-13: the geometry works in integer-clean centimetres).
    /// Pinned by `heightIsLinearInDepth`.
    @inline(__always)
    public func heightCm(u: Int, v: Int, depthM: Float, cameraHeightCm: Float) -> Float {
        cameraHeightCm + depthM * 100 * heightGain(u: u, v: v)
    }

    /// Pitch below the horizon, degrees (positive = down) — `MountTilt.downDegrees(upZ)`.
    public var pitchDownDeg: Float {
        MountTilt.downDegrees(cameraZColumnY: upZ)
    }
}

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
    /// Rows mode only: bottom fraction of the upright image skipped as ground. Pinned by
    /// `groundBandIsSkippedWithoutGeometry`. Metric mode drops the floor by height instead.
    public var groundSkipFraction: Float = 0.25
    /// Sample every Nth pixel on both axes (clamped to ≥ 1): 4 reads 1 pixel in 16 of ARKit's
    /// 256 × 192 depth map (the centre window always samples every 2nd pixel).
    public var subsampleStep = 4
    /// Fewer valid samples than this → the cell reports `.infinity` (clear). In metric mode also
    /// the coverage bar: fewer than this many rays landing in a band at `coverageRangeCm` → the
    /// band cell is uncovered.
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
    /// Metric mode: camera height above the ground, centimetres. The cane mount holds the phone
    /// at ≈ 95 cm (hardware/mount/DESIGN.md §4 measured 0.97 m on the prototype); a constant
    /// tonight — calibrating it from the ground plane is in docs/todo.md.
    public var cameraHeightCm: Float = 95
    /// Metric mode: a sample lower than this is floor / kerb / cane tip and is dropped from both
    /// bands (the ground detector owns what is under 25 cm). ADA ramps and a ±15 cm camera-height
    /// error stay inside the margin; a two-step stair reads torso at its true distance.
    public var floorMaxHeightCm: Float = 25
    /// Metric mode: a sample at or above this height is the head band ("head height" means at
    /// least 1.4 m above the ground, an overhang a cane cannot find).
    public var headMinHeightCm: Float = 140
    /// Metric mode: the range at which each ray's *nominal* band is judged for coverage and for
    /// blind bucketing — the outdoor head-cue distance (`CueThresholds.head`, 1.5 m).
    public var coverageRangeCm: Float = 150

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
    /// Per lane (L/C/R): at least `minSamplesPerCell` rays of this lane reach head height
    /// (≥ `headMinHeightCm`) at `coverageRangeCm`. False = the camera cannot judge head height
    /// here (too steep a mount) and `head[lane]` is `.infinity` by construction; `HeadGate`,
    /// `TileLevel` ("NO COVER"), `NearHold` and the Mount card read it. Always true in rows mode.
    public var headCoverage: [Bool]
    /// Same for the torso band (25–140 cm at `coverageRangeCm`). Stays true down to a very steep
    /// mount: at 45° the upper third of the image still sees torso height at 1.5 m.
    public var torsoCoverage: [Bool]
    /// How the bands were cut this frame (`.rows` before ARKit has a pose).
    public var bandMode: LaneBandMode

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
    ///   - headCoverage / torsoCoverage: coverage flags per lane (default all true — a grid built
    ///     by hand, or in rows mode, can see every band).
    ///   - bandMode: how the bands were cut (default `.rows`).
    public init(head: [Float], torso: [Float], centerDepth: Float,
                headBlind: [Float] = [0, 0, 0], torsoBlind: [Float] = [0, 0, 0],
                headHeld: [Bool] = [false, false, false], torsoHeld: [Bool] = [false, false, false],
                headCoverage: [Bool] = [true, true, true], torsoCoverage: [Bool] = [true, true, true],
                bandMode: LaneBandMode = .rows) {
        self.head = head
        self.torso = torso
        self.centerDepth = centerDepth
        self.headBlind = headBlind
        self.torsoBlind = torsoBlind
        self.headHeld = headHeld
        self.torsoHeld = torsoHeld
        self.headCoverage = headCoverage
        self.torsoCoverage = torsoCoverage
        self.bandMode = bandMode
    }

    /// Closest thing in a lane across both bands.
    /// - Parameter lane: 0 left, 1 centre, 2 right (not range-checked: other values trap).
    /// - Returns: metres (`.infinity` when clear).
    public func nearest(lane: Int) -> Float { min(head[lane], torso[lane]) }
}

/// The depth-map → lane-grid reduction. Stateless.
public enum LaneMath {

    /// What one depth pixel is once read: a usable distance, a blind return (0 / NaN / ≤ 5 cm —
    /// the LiDAR inside its saturation range), or a far low-confidence pixel that is neither
    /// valid nor blind and must not dilute a wall edge (Muse F6, Step 48).
    private enum Sample {
        case valid(Float)
        case blind
        case rejected
    }

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
    ///   - geometry: the camera's pose and intrinsics for metric bands; nil = rows mode.
    /// - Returns: per-cell 10th-percentile depths and the centre median, metres, plus the blind
    ///   shares, the coverage flags and the band mode.
    /// Pinned by `rawEntrypointHonoursPaddedRowStrides` (and via the array overload, every
    /// LaneMathTests and LaneGeometryTests case).
    public static func computeLanes(
        depth: UnsafeRawPointer,
        depthBytesPerRow: Int,
        confidence: UnsafeRawPointer?,
        confidenceBytesPerRow: Int,
        width bufW: Int,
        height bufH: Int,
        config: LaneConfig,
        scratch: inout [Float],
        geometry: LaneGeometry? = nil
    ) -> LaneGrid {
        let rotate = config.rotateForPortrait
        let step = max(1, config.subsampleStep)

        // Scene-space dimensions (what the pedestrian sees: x left→right, y top→bottom).
        let sceneW = rotate ? bufH : bufW
        let sceneH = rotate ? bufW : bufH
        let laneW = sceneW / 3

        // Reads one buffer pixel. Proximity overrides confidence: returns < closeOverrideThreshold
        // (35 cm) represent near-field physical presence (where LiDAR saturation drops confidence
        // to 0) rather than noise. A non-finite / ≤ 5 cm read is *blind* (Step 48): inside ~10 cm
        // the LiDAR returns 0 or NaN, and a cell that is mostly blind is not empty — it is too
        // close to read. A far low-confidence pixel is `rejected`: neither valid nor blind.
        @inline(__always) func read(bx: Int, by: Int) -> Sample {
            let d = depth.load(fromByteOffset: by * depthBytesPerRow + bx * MemoryLayout<Float>.stride, as: Float.self)
            guard d.isFinite, d > 0.05 else { return .blind }
            if d < config.closeOverrideThreshold {
                return .valid(d)
            }
            if let confidence {
                let c = confidence.load(fromByteOffset: by * confidenceBytesPerRow + bx, as: UInt8.self)
                if c < config.minConfidence { return .rejected }
            }
            return .valid(d)
        }

        // Nearest-10 % rule shared by every cell: `.infinity` under `minSamplesPerCell` samples.
        @inline(__always) func percentile(of samples: inout [Float]) -> Float {
            guard samples.count >= config.minSamplesPerCell else { return .infinity }
            samples.sort()
            let idx = min(samples.count - 1, Int(Float(samples.count) * config.percentile))
            return samples[idx]
        }

        if let geometry {
            return metricLanes(geometry: geometry, config: config, rotate: rotate, step: step,
                               sceneW: sceneW, sceneH: sceneH, laneW: laneW, bufH: bufH,
                               scratch: &scratch, read: read, percentile: percentile)
        }

        // ---- Rows mode: the bottom `groundSkipFraction` is ground, the rest is split in half. ----
        let usableH = max(2, Int(Float(sceneH) * (1 - config.groundSkipFraction)))
        let bandH = usableH / 2

        // Reads one scene-space pixel through the portrait remap; nil when low-confidence,
        // non-finite or ≤ 5 cm, incrementing `blind` for the non-finite / ≤ 5 cm case.
        var blind = 0
        @inline(__always) func sample(sx: Int, sy: Int) -> Float? {
            let bx = rotate ? sy : sx
            let by = rotate ? (bufH - 1 - sx) : sy
            switch read(bx: bx, by: by) {
            case .valid(let d): return d
            case .blind: blind += 1; return nil
            case .rejected: return nil
            }
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
                let value = percentile(of: &scratch)
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
                        headBlind: headBlind, torsoBlind: torsoBlind,
                        headCoverage: [true, true, true], torsoCoverage: [true, true, true],
                        bandMode: .rows)
    }

    /// Metric mode (Step 51): one pass per lane over **all** scene rows; every sample is placed by
    /// its height above the ground, floor dropped. Nominal band (the ray at `coverageRangeCm`)
    /// drives coverage and the blind bucket; actual band (the ray at its measured depth) drives
    /// the distance. ~2× the rows-mode cost (both bands read the whole lane); still well under a
    /// 30 Hz frame. The two band buffers are kept per call rather than borrowed from `scratch`
    /// because both bands fill at once.
    private static func metricLanes(
        geometry: LaneGeometry, config: LaneConfig, rotate: Bool, step: Int,
        sceneW: Int, sceneH: Int, laneW: Int, bufH: Int,
        scratch: inout [Float],
        read: (_ bx: Int, _ by: Int) -> Sample,
        percentile: (_ samples: inout [Float]) -> Float
    ) -> LaneGrid {
        var head = [Float](repeating: .infinity, count: 3)
        var torso = [Float](repeating: .infinity, count: 3)
        var headBlind = [Float](repeating: 0, count: 3)
        var torsoBlind = [Float](repeating: 0, count: 3)
        var headCoverage = [false, false, false]
        var torsoCoverage = [false, false, false]

        var headSamples = [Float]()
        var torsoSamples = [Float]()
        headSamples.reserveCapacity(512)
        torsoSamples.reserveCapacity(512)
        let camCm = config.cameraHeightCm
        let rangeCm = config.coverageRangeCm

        for lane in 0..<3 {
            let sx0 = lane * laneW
            let sx1 = sx0 + laneW
            headSamples.removeAll(keepingCapacity: true)
            torsoSamples.removeAll(keepingCapacity: true)
            var headBlindCount = 0, torsoBlindCount = 0
            var headRays = 0, torsoRays = 0

            var sy = 0
            while sy < sceneH {
                var sx = sx0
                while sx < sx1 {
                    let bx = rotate ? sy : sx
                    let by = rotate ? (bufH - 1 - sx) : sy
                    let g = geometry.heightGain(u: bx, v: by)
                    // Where this ray is at the head-cue distance: its nominal band.
                    let nominalCm = camCm + rangeCm * g
                    let nominalHead = nominalCm >= config.headMinHeightCm
                    let nominalTorso = !nominalHead && nominalCm >= config.floorMaxHeightCm
                    if nominalHead { headRays += 1 } else if nominalTorso { torsoRays += 1 }

                    switch read(bx, by) {
                    case .blind:
                        // Blind pixels keep counting toward the band they normally feed (Step 48
                        // semantics: a wall against the lens blinds the cells it would fill).
                        if nominalHead { headBlindCount += 1 } else if nominalTorso { torsoBlindCount += 1 }
                    case .valid(let d):
                        let hCm = camCm + d * 100 * g
                        if hCm >= config.headMinHeightCm {
                            headSamples.append(d)
                        } else if hCm >= config.floorMaxHeightCm {
                            torsoSamples.append(d)
                        }
                        // Under `floorMaxHeightCm`: floor, kerb, cane tip — dropped.
                    case .rejected:
                        break
                    }
                    sx += step
                }
                sy += step
            }

            let outLane = config.mirrorLeftRight ? (2 - lane) : lane
            let headCovered = headRays >= config.minSamplesPerCell
            let torsoCovered = torsoRays >= config.minSamplesPerCell
            headCoverage[outLane] = headCovered
            torsoCoverage[outLane] = torsoCovered

            // Blind share over the *readable* samples, as in rows mode (Muse F6).
            let readableHead = headBlindCount + headSamples.count
            headBlind[outLane] = readableHead > 0 ? Float(headBlindCount) / Float(readableHead) : 0
            let readableTorso = torsoBlindCount + torsoSamples.count
            torsoBlind[outLane] = readableTorso > 0 ? Float(torsoBlindCount) / Float(readableTorso) : 0
            // An uncovered band is `.infinity` by construction: the few far samples that reach the
            // band beyond the cue distance must not read as a head-height thing at 1.5 m.
            head[outLane] = headCovered ? percentile(&headSamples) : .infinity
            torso[outLane] = torsoCovered ? percentile(&torsoSamples) : .infinity
        }

        // Centre window: the full image centre, floor dropped by height → median.
        scratch.removeAll(keepingCapacity: true)
        let half = max(1, config.centerWindow / 2)
        let cx = sceneW / 2, cy = sceneH / 2
        var csy = max(0, cy - half)
        while csy < min(sceneH, cy + half) {
            var csx = max(0, cx - half)
            while csx < min(sceneW, cx + half) {
                let bx = rotate ? csy : csx
                let by = rotate ? (bufH - 1 - csx) : csy
                if case .valid(let d) = read(bx, by),
                   camCm + d * 100 * geometry.heightGain(u: bx, v: by) >= config.floorMaxHeightCm {
                    scratch.append(d)
                }
                csx += 2
            }
            csy += 2
        }
        var center: Float = .infinity
        if scratch.count >= 4 {
            scratch.sort()
            center = scratch[scratch.count / 2]
        }

        return LaneGrid(head: head, torso: torso, centerDepth: center,
                        headBlind: headBlind, torsoBlind: torsoBlind,
                        headCoverage: headCoverage, torsoCoverage: torsoCoverage,
                        bandMode: .metric)
    }

    /// Convenience for tests and offline replay: arrays instead of raw pointers.
    /// Assumes tight rows (`width × 4` bytes for depth, `width` for confidence).
    /// - Parameters:
    ///   - depth: `width × height` depths in metres, row-major.
    ///   - confidence: optional `width × height` confidence map (0/1/2).
    ///   - width: buffer width in pixels.
    ///   - height: buffer height in pixels.
    ///   - config: tunables (default portrait).
    ///   - geometry: camera pose and intrinsics (nil = rows mode).
    /// - Returns: the same grid the raw entry point would produce.
    /// - Precondition: array sizes equal `width × height`.
    public static func computeLanes(
        depth: [Float],
        confidence: [UInt8]?,
        width: Int,
        height: Int,
        config: LaneConfig = LaneConfig(),
        geometry: LaneGeometry? = nil
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
                                 width: width, height: height, config: config, scratch: &scratch,
                                 geometry: geometry)
                }
            }
            return computeLanes(depth: dbuf.baseAddress!, depthBytesPerRow: width * 4,
                                confidence: nil, confidenceBytesPerRow: 0,
                                width: width, height: height, config: config, scratch: &scratch,
                                geometry: geometry)
        }
    }
}
