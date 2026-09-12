//
//  DepthSnapshot.swift
//  CaneKitLogic
//
//  A tiny scene-space grid of LiDAR depths, kept alongside the retained camera frame so that
//  anything Vision finds *in the image* (a person, an animal) can be given a real distance.
//
//  Why it exists: `LaneGrid` is 3 lanes x 2 bands — enough to buzz the cane, far too coarse to
//  answer "how far is that person?". Reading the depth inside a detection's own bounding box is
//  the difference between "Two people ahead, about 3 meters." and a number borrowed from
//  whatever else happens to be in the same lane. Speaking a wrong distance to a blind walker is
//  worse than speaking none, so every lookup can return nil and the caller then says the
//  direction alone (AGENTS.md "never speak something the sensors did not see").
//
//  Geometry, identical to `LaneMath`: values are in **scene space** — what the pedestrian sees,
//  x left→right, y top→bottom — after the portrait remap (`bufX = sceneY`, `bufY = bufH-1-sceneX`).
//  `DepthFrameProcessor.jpegSnapshot` rotates the camera buffer the same way (`.oriented(.right)`),
//  so a Vision bounding box on that JPEG and this grid describe the same pixels. Vision's boxes
//  are **bottom-left** origin, so `distance(inVisionBox:)` flips y itself.
//
//  Cost, **measured** (release build, Apple silicon, 256x192 depth + confidence, 2,000 calls):
//  `make` takes **19.3 us** per published depth frame against `LaneMath.computeLanes`'s 47.0 us
//  on the same buffers — 0.06 % of a 33 ms frame at the 30 Hz publish cap, and it allocates one
//  384-Float array (1.5 kB). `distance(inVisionBox:)` is **0.1 us** and runs once per "Where am
//  I", not per frame. (A19 numbers will differ; the ratio to the lane pass is the thing to watch
//  if `thermal` in the trip log ever moves.)
//
//  Tests: DepthSnapshotTests.swift.
//

import Foundation

/// A normalized rectangle in Vision's convention: origin **bottom-left**, 0…1 on both axes,
/// measured on the upright (portrait) image Vision was handed.
///
/// Mirrors only the four numbers the app needs; `SignPolicy.SeenText.Box` is the older,
/// text-specific version and stays as it is. Built by `OnDeviceVision` from
/// `HumanObservation.boundingBox.cgRect`; consumed by `DepthSnapshot` and `PeopleAhead`.
public struct NormalizedBox: Sendable, Equatable {
    /// Left edge, 0 = image left.
    public var minX: Float
    /// Bottom edge, 0 = image **bottom** (Vision's origin).
    public var minY: Float
    /// Width as a fraction of the image width.
    public var width: Float
    /// Height as a fraction of the image height.
    public var height: Float

    /// - Parameters:
    ///   - minX: left edge (0…1).
    ///   - minY: bottom edge (0…1, Vision's bottom-left origin).
    ///   - width: width (0…1).
    ///   - height: height (0…1).
    public init(minX: Float, minY: Float, width: Float, height: Float) {
        self.minX = minX
        self.minY = minY
        self.width = width
        self.height = height
    }

    /// Horizontal centre (0 = image left, 1 = image right). Drives `PeopleAhead.bearing`.
    public var midX: Float { minX + width / 2 }
    /// Vertical centre in Vision's bottom-left space (0 = bottom, 1 = top).
    public var midY: Float { minY + height / 2 }
}

/// A coarse grid of LiDAR depths in scene space, `.infinity` where depth is unknown.
///
/// Produced by `DepthFrameProcessor` on every published depth frame (see `make`), handed to the
/// on-device describer through `SceneContext`, and queried once per "Where am I".
public struct DepthSnapshot: Sendable, Equatable {

    /// Grid width used by the app. 16 columns over a ~50 deg horizontal field is ~3 deg per cell:
    /// finer than the direction bands `PeopleAhead` speaks, so a body never straddles the grid.
    public static let defaultCols = 16
    /// Grid height used by the app (portrait frames are the taller axis).
    public static let defaultRows = 24

    /// Number of columns, x left→right.
    public let cols: Int
    /// Number of rows, y top→bottom.
    public let rows: Int
    /// `cols * rows` depths in metres, row-major from the top-left; `.infinity` = unknown.
    public let values: [Float]

    /// The "no depth yet" grid (non-LiDAR device, ARKit paused, or a frame without depth).
    public static let empty = DepthSnapshot(cols: 0, rows: 0, values: [])

    /// True when there is nothing to look up (the caller then speaks a direction with no distance).
    public var isEmpty: Bool { values.count != cols * rows || values.isEmpty }

    /// - Parameters:
    ///   - cols: columns, x left→right.
    ///   - rows: rows, y top→bottom.
    ///   - values: `cols * rows` metres, row-major from the top-left (`.infinity` = unknown).
    public init(cols: Int, rows: Int, values: [Float]) {
        self.cols = cols
        self.rows = rows
        self.values = values
    }

    /// One cell, or `.infinity` when the indices are outside the grid.
    /// - Parameters:
    ///   - col: 0 = leftmost.
    ///   - row: 0 = topmost.
    public func value(col: Int, row: Int) -> Float {
        guard col >= 0, col < cols, row >= 0, row < rows else { return .infinity }
        return values[row * cols + col]
    }

    /// Metres to whatever fills a Vision bounding box, or nil when the depth is unknown or
    /// outside the range LiDAR can be trusted over (`DepthSnapshot.trusted`).
    ///
    /// Only the middle `sampleFraction` of the box is read: the edges of a person's rectangle are
    /// mostly background, and the median of the middle is the body rather than the wall behind it.
    /// The median (not the minimum) is deliberate — a single LiDAR spike on a box edge would
    /// otherwise halve the spoken distance.
    /// - Parameters:
    ///   - box: the detection's normalized box (Vision's bottom-left origin; y is flipped here).
    ///   - sampleFraction: fraction of the box side read around its centre (0…1).
    /// - Returns: metres, or nil when no cell in the window has a trustworthy depth.
    /// ⚠ Pinned by `boxDepthIsTheMedianOfItsMiddle`, `boxDepthIgnoresEdgeSpikes`,
    ///   `boxDepthIsNilWhenUnknown`, `boxDepthRejectsOutOfRangeLidar`.
    public func distance(inVisionBox box: NormalizedBox, sampleFraction: Float = 0.4) -> Float? {
        guard !isEmpty else { return nil }
        // A non-finite box would trap in `Int(_:)`, and this runs on a blind walker's phone.
        guard box.midX.isFinite, box.midY.isFinite, box.width.isFinite, box.height.isFinite else { return nil }
        let f = min(max(sampleFraction, 0.05), 1)
        // Scene space: Vision's y grows upward, the grid's rows grow downward.
        let cx = box.midX
        let cy = 1 - box.midY
        let halfW = max(box.width * f, 1 / Float(cols)) / 2
        let halfH = max(box.height * f, 1 / Float(rows)) / 2

        let c0 = index((cx - halfW) * Float(cols), limit: cols)
        let c1 = index((cx + halfW) * Float(cols), limit: cols)
        let r0 = index((cy - halfH) * Float(rows), limit: rows)
        let r1 = index((cy + halfH) * Float(rows), limit: rows)

        var window: [Float] = []
        window.reserveCapacity((c1 - c0 + 1) * (r1 - r0 + 1))
        for r in r0...r1 {
            for c in c0...c1 {
                let v = values[r * cols + c]
                if v.isFinite { window.append(v) }
            }
        }
        guard !window.isEmpty else { return nil }
        window.sort()
        let median = window[window.count / 2]
        return Self.trusted.contains(median) ? median : nil
    }

    /// Distances LiDAR is worth quoting over. ARKit's `sceneDepth` is specified to roughly 5 m;
    /// beyond that the map is extrapolation, and under 0.3 m it is the mount itself. Outside this
    /// range `distance(inVisionBox:)` returns nil and the walker hears a direction with no number.
    public static let trusted: ClosedRange<Float> = 0.3...5.0

    /// A grid index from a float coordinate, clamped to `0…limit-1` **before** the conversion, so
    /// a box that runs off the frame (or arrives absurd) can never trap `Int(_:)` or index out of
    /// bounds. `limit` is `cols` or `rows`.
    private func index(_ v: Float, limit: Int) -> Int {
        if !(v > 0) { return 0 }                     // also catches NaN
        if v >= Float(limit) { return limit - 1 }
        return Int(v)
    }

    // MARK: Building from a depth map

    /// Reduce one ARKit depth map to the grid (raw entry point, used by `DepthFrameProcessor`
    /// over locked `CVPixelBuffer` memory — no copy).
    ///
    /// Each cell takes the median of up to 9 samples spread over the cell, so one bad LiDAR pixel
    /// cannot move it. Samples are rejected exactly as `LaneMath` rejects them: below
    /// `minConfidence`, non-finite, or ≤ 5 cm.
    /// - Parameters:
    ///   - depth: base address of a Float32 depth map (metres), `width` x `height`.
    ///   - depthBytesPerRow: bytes per depth row (may include padding).
    ///   - confidence: optional UInt8 map, same dimensions.
    ///   - confidenceBytesPerRow: bytes per confidence row (ignored when `confidence` is nil).
    ///   - width: sensor-buffer width in pixels (landscape).
    ///   - height: sensor-buffer height in pixels (landscape).
    ///   - rotateForPortrait: same flag the lanes use (`LaneConfig.rotateForPortrait`).
    ///   - minConfidence: ARKit confidence floor (0 low, 1 medium, 2 high).
    ///   - cols: grid width (default `defaultCols`).
    ///   - rows: grid height (default `defaultRows`).
    /// - Returns: the grid; cells with no valid sample are `.infinity`.
    /// ⚠ Pinned through the array overload by `snapshotHonoursPortraitRemap`,
    ///   `snapshotDropsLowConfidencePixels`, `snapshotCellIsTheMedianOfItsSamples`.
    public static func make(
        depth: UnsafeRawPointer,
        depthBytesPerRow: Int,
        confidence: UnsafeRawPointer?,
        confidenceBytesPerRow: Int,
        width bufW: Int,
        height bufH: Int,
        rotateForPortrait: Bool,
        minConfidence: UInt8,
        cols: Int = defaultCols,
        rows: Int = defaultRows
    ) -> DepthSnapshot {
        guard cols > 0, rows > 0, bufW > 0, bufH > 0 else { return .empty }
        let sceneW = rotateForPortrait ? bufH : bufW
        let sceneH = rotateForPortrait ? bufW : bufH

        // Same remap as LaneMath.sample; kept local so both stay allocation-free.
        @inline(__always) func sample(sx: Int, sy: Int) -> Float? {
            let bx = rotateForPortrait ? sy : sx
            let by = rotateForPortrait ? (bufH - 1 - sx) : sy
            guard bx >= 0, bx < bufW, by >= 0, by < bufH else { return nil }
            if let confidence {
                let c = confidence.load(fromByteOffset: by * confidenceBytesPerRow + bx, as: UInt8.self)
                if c < minConfidence { return nil }
            }
            let d = depth.load(fromByteOffset: by * depthBytesPerRow + bx * MemoryLayout<Float>.stride,
                               as: Float.self)
            return (d.isFinite && d > 0.05) ? d : nil
        }

        var values = [Float](repeating: .infinity, count: cols * rows)
        var cell = [Float]()
        cell.reserveCapacity(9)
        for r in 0..<rows {
            for c in 0..<cols {
                cell.removeAll(keepingCapacity: true)
                // 3 x 3 probe at the quarter points of the cell (never on its border, which is
                // where a body's outline and the background meet).
                for j in 1...3 {
                    let sy = min(sceneH - 1, (r * sceneH + j * sceneH / 4) / rows)
                    for i in 1...3 {
                        let sx = min(sceneW - 1, (c * sceneW + i * sceneW / 4) / cols)
                        if let d = sample(sx: sx, sy: sy) { cell.append(d) }
                    }
                }
                guard !cell.isEmpty else { continue }
                cell.sort()
                values[r * cols + c] = cell[cell.count / 2]
            }
        }
        return DepthSnapshot(cols: cols, rows: rows, values: values)
    }

    /// Convenience for tests and offline replay: arrays instead of raw pointers (tight rows).
    /// - Parameters:
    ///   - depth: `width * height` depths in metres, row-major.
    ///   - confidence: optional `width * height` confidence map (0/1/2).
    ///   - width: buffer width in pixels.
    ///   - height: buffer height in pixels.
    ///   - rotateForPortrait: portrait remap on/off.
    ///   - minConfidence: ARKit confidence floor.
    ///   - cols: grid width.
    ///   - rows: grid height.
    /// - Returns: the same grid the raw entry point would produce.
    /// - Precondition: array sizes equal `width * height`.
    public static func make(
        depth: [Float],
        confidence: [UInt8]? = nil,
        width: Int,
        height: Int,
        rotateForPortrait: Bool = true,
        minConfidence: UInt8 = 1,
        cols: Int = defaultCols,
        rows: Int = defaultRows
    ) -> DepthSnapshot {
        precondition(depth.count == width * height, "depth must be width * height")
        precondition(confidence == nil || confidence?.count == width * height,
                     "confidence must be width * height")
        // An empty buffer satisfies both preconditions, and `baseAddress` is then nil: the raw
        // entry point answers `.empty` for zero dimensions, so this overload must too rather than
        // trap on a force unwrap (Muse review).
        guard !depth.isEmpty, width > 0, height > 0 else { return .empty }
        return depth.withUnsafeBytes { d -> DepthSnapshot in
            let build = { (conf: UnsafeRawPointer?) in
                make(depth: d.baseAddress!, depthBytesPerRow: width * MemoryLayout<Float>.stride,
                     confidence: conf, confidenceBytesPerRow: width,
                     width: width, height: height,
                     rotateForPortrait: rotateForPortrait, minConfidence: minConfidence,
                     cols: cols, rows: rows)
            }
            guard let confidence else { return build(nil) }
            return confidence.withUnsafeBytes { c in build(c.baseAddress!) }
        }
    }
}
