//
//  DepthSnapshotTests.swift
//  CaneKitLogicTests
//
//  Pins the depth grid that gives a Vision detection its distance: the portrait remap (the same
//  one `LaneMath` uses), the confidence floor, the per-cell median, and the box lookup — including
//  the two places it must refuse to answer rather than guess (no valid cell, and a median outside
//  the range ARKit's LiDAR can be trusted over). Speaking a wrong distance to a blind walker is
//  worse than speaking none.
//
//  Boxes are Vision's: normalized, **bottom-left** origin, on the upright portrait frame.
//
//  Source pinned: `ios/Logic/Sources/CaneKitLogic/DepthSnapshot.swift` (`DepthSnapshot.make` →
//  16 × 24 grid of per-cell medians; `distance(inVisionBox:sampleFraction:)` → median of the middle
//  40 % of the box, nil outside `DepthSnapshot.trusted` 0.3…5 m). Callers: `DepthFrameProcessor`
//  (app) builds the snapshot from each ARKit depth map; `OnDeviceVision` reads a distance for every
//  `PeopleAhead` sighting. Breaks these catch: a remap that puts a person on the wrong side, a
//  flipped Vision y reading the ground instead of the head, an edge spike halving the spoken
//  distance, an extrapolated (> 5 m) or mount-itself (< 0.3 m) depth spoken as fact, and a trap
//  (`Int(nan)`, out-of-bounds index, nil `baseAddress`) on the cane.
//  Grid fixtures below use 96 × 64 landscape buffers → a 64 × 96 portrait scene → 4 × 4 px cells.
//

import Testing
@testable import CaneKitLogic

/// A grid filled by a closure over (col, row); row 0 is the top of the image.
private func grid(cols: Int = DepthSnapshot.defaultCols, rows: Int = DepthSnapshot.defaultRows,
                  _ f: (Int, Int) -> Float) -> DepthSnapshot {
    var v = [Float](repeating: .infinity, count: cols * rows)
    for r in 0..<rows { for c in 0..<cols { v[r * cols + c] = f(c, r) } }
    return DepthSnapshot(cols: cols, rows: rows, values: v)
}

/// A landscape sensor buffer written through the portrait remap, so the test can think in
/// scene space (x left→right, y top→bottom) exactly as the walker sees it.
private func landscape(bufW: Int, bufH: Int, _ f: (_ sx: Int, _ sy: Int) -> Float) -> [Float] {
    var buf = [Float](repeating: 0, count: bufW * bufH)
    for sy in 0..<bufW {            // sceneH == bufW
        for sx in 0..<bufH {        // sceneW == bufH
            buf[(bufH - 1 - sx) * bufW + sy] = f(sx, sy)
        }
    }
    return buf
}

/// A full-height body box centred at `x`.
private func box(x: Float, y: Float = 0.5, w: Float = 0.2, h: Float = 0.6) -> NormalizedBox {
    NormalizedBox(minX: x - w / 2, minY: y - h / 2, width: w, height: h)
}

// MARK: - Box lookup

/// Baseline: a uniform 3 m grid gives 3 m for a centred body box (the lookup returns a depth, not
/// an index or a mean of infinities).
@Test func boxDepthIsTheMedianOfItsMiddle() {
    let g = grid { _, _ in 3.0 }
    #expect(g.distance(inVisionBox: box(x: 0.5)) == 3.0)
}

/// Columns map left → right: a box on the left half reads the near left half (2 m), on the right
/// half the far right half (4 m). Catches a mirrored column index.
@Test func boxDepthFollowsTheBoxAcrossTheFrame() {
    let g = grid { c, _ in c < 8 ? 2.0 : 4.0 }
    #expect(g.distance(inVisionBox: box(x: 0.2)) == 2.0)
    #expect(g.distance(inVisionBox: box(x: 0.8)) == 4.0)
}

/// Vision's y grows upward, grid rows grow downward; forgetting the flip reads the wrong band.
@Test func boxDepthFlipsVisionsBottomLeftOrigin() {
    // Rows grow downward; Vision's y grows upward. A box high in Vision's frame (midY 0.8) must
    // read the *top* rows.
    let g = grid { _, r in r < 12 ? 2.0 : 4.0 }
    #expect(g.distance(inVisionBox: box(x: 0.5, y: 0.8, h: 0.1)) == 2.0)
    #expect(g.distance(inVisionBox: box(x: 0.5, y: 0.2, h: 0.1)) == 4.0)
}

/// A whole-frame box whose border cells are a 0.31 m spike still reads the 3 m middle
/// (`sampleFraction` 0.4 + median).
@Test func boxDepthIgnoresEdgeSpikes() {
    // Only the middle 40 % of the box is read: a person's outline is background, and one LiDAR
    // spike on the edge would otherwise halve the spoken distance.
    let g = grid { c, r in (4...11).contains(c) && (7...16).contains(r) ? 3.0 : 0.31 }
    #expect(g.distance(inVisionBox: NormalizedBox(minX: 0, minY: 0, width: 1, height: 1)) == 3.0)
}

/// No valid cell (all `.infinity`) or an empty snapshot answers nil, never `.infinity` spoken as a
/// distance; `DepthSnapshot.empty` is the value used before the first depth frame.
@Test func boxDepthIsNilWhenUnknown() {
    let g = grid { _, _ in .infinity }
    #expect(g.distance(inVisionBox: box(x: 0.5)) == nil)
    #expect(DepthSnapshot.empty.distance(inVisionBox: box(x: 0.5)) == nil)
    #expect(DepthSnapshot.empty.isEmpty)
}

/// `DepthSnapshot.trusted` is inclusive at both ends (0.3 m and 5 m answer; 0.1 m and 8 m do not).
@Test func boxDepthRejectsOutOfRangeLidar() {
    // Beyond ~5 m ARKit's sceneDepth is extrapolation and under 0.3 m it is the mount itself:
    // the walker hears the direction with no number instead.
    #expect(grid { _, _ in 8.0 }.distance(inVisionBox: box(x: 0.5)) == nil)
    #expect(grid { _, _ in 0.1 }.distance(inVisionBox: box(x: 0.5)) == nil)
    #expect(grid { _, _ in 5.0 }.distance(inVisionBox: box(x: 0.5)) == 5.0)
    #expect(grid { _, _ in 0.3 }.distance(inVisionBox: box(x: 0.5)) == 0.3)
}

/// A 0.001-wide box still covers at least one cell, so a distant person keeps their distance.
@Test func boxDepthSurvivesATinyBox() {
    // A far-away person is a few pixels tall; the window must still cover at least one cell.
    let g = grid { _, _ in 4.5 }
    #expect(g.distance(inVisionBox: NormalizedBox(minX: 0.5, minY: 0.5, width: 0.001, height: 0.001)) == 4.5)
}

/// Boxes partly or wildly outside [0, 1] are clamped to the grid rather than indexing past it.
@Test func boxDepthClampsBoxesOffTheEdge() {
    let g = grid { _, _ in 2.0 }
    #expect(g.distance(inVisionBox: NormalizedBox(minX: -0.4, minY: -0.4, width: 0.5, height: 0.5)) == 2.0)
    #expect(g.distance(inVisionBox: NormalizedBox(minX: 0.9, minY: 0.9, width: 0.5, height: 0.5)) == 2.0)
    // Absurdly large, and exactly on the far edge: neither may trap `Int(_:)` or index past the end.
    #expect(g.distance(inVisionBox: NormalizedBox(minX: -50, minY: -50, width: 200, height: 200)) == 2.0)
    #expect(g.distance(inVisionBox: NormalizedBox(minX: 1, minY: 1, width: 0, height: 0)) == 2.0)
}

/// A NaN or infinite box coordinate answers nil instead of trapping in `Int(_:)`.
@Test func boxDepthRefusesANonFiniteBox() {
    // Nothing should ever hand us a NaN box, but `Int(nan)` traps and this runs on the cane.
    let g = grid { _, _ in 2.0 }
    #expect(g.distance(inVisionBox: NormalizedBox(minX: .nan, minY: 0.1, width: 0.2, height: 0.2)) == nil)
    #expect(g.distance(inVisionBox: NormalizedBox(minX: 0.1, minY: 0.1, width: .infinity, height: 0.2)) == nil)
}

// MARK: - Building from a depth map

/// `make` uses the same landscape → portrait remap as `LaneMath` (96 × 64 buffer → 16 × 24 grid),
/// so a near object on the scene's left lands in the left columns on every row.
@Test func snapshotHonoursPortraitRemap() {
    // Scene-left quarter is near; everything else is far. The remap must put it in the left columns.
    let buf = landscape(bufW: 96, bufH: 64) { sx, _ in sx < 16 ? 1.0 : 4.0 }
    let s = DepthSnapshot.make(depth: buf, width: 96, height: 64)
    #expect(s.cols == 16 && s.rows == 24)
    for r in [0, 11, 23] {
        for c in 0..<4 { #expect(s.value(col: c, row: r) == 1.0) }
        for c in 5..<16 { #expect(s.value(col: c, row: r) == 4.0) }
    }
}

/// A cell whose pixels are all ≤ 5 cm depth, or all below the confidence floor (default 1 =
/// medium; 0 here), is `.infinity` (unknown), never a 0 m obstacle; its neighbour is unaffected.
@Test func snapshotDropsLowConfidencePixelsAndBadDepths() {
    var buf = landscape(bufW: 96, bufH: 64) { _, _ in 2.0 }
    // A whole cell of unusable depth (≤ 5 cm is ARKit's "no answer") reports .infinity.
    for sy in 0..<4 { for sx in 0..<4 { buf[(64 - 1 - sx) * 96 + sy] = 0.0 } }
    let s = DepthSnapshot.make(depth: buf, width: 96, height: 64)
    #expect(s.value(col: 0, row: 0) == .infinity)
    #expect(s.value(col: 1, row: 0) == 2.0)

    // Same cell, this time rejected by the confidence map.
    let flat = landscape(bufW: 96, bufH: 64) { _, _ in 2.0 }
    var conf = [UInt8](repeating: 2, count: 96 * 64)
    for sy in 0..<4 { for sx in 0..<4 { conf[(64 - 1 - sx) * 96 + sy] = 0 } }
    let t = DepthSnapshot.make(depth: flat, confidence: conf, width: 96, height: 64)
    #expect(t.value(col: 0, row: 0) == .infinity)
    #expect(t.value(col: 1, row: 0) == 2.0)
}

/// Each cell is the median of its 3 × 3 quarter-point probe, not the minimum or mean.
@Test func snapshotCellIsTheMedianOfItsSamples() {
    // Cell (0,0) covers scene 4x4 px and probes sx, sy in {1,2,3}; three rows of 1, 2 and 3 m
    // give a median of 2 — one bad pixel cannot move the cell.
    let buf = landscape(bufW: 96, bufH: 64) { _, sy in Float(sy % 4) }
    let s = DepthSnapshot.make(depth: buf, width: 96, height: 64)
    #expect(s.value(col: 0, row: 0) == 2.0)
}

/// A 0 × 0 buffer (with or without confidence) gives an empty snapshot instead of force-unwrapping
/// a nil `baseAddress`.
@Test func snapshotOfAnEmptyBufferIsEmptyNotACrash() {
    // Zero dimensions satisfy the preconditions and leave `baseAddress` nil (Muse review).
    #expect(DepthSnapshot.make(depth: [], width: 0, height: 0).isEmpty)
    #expect(DepthSnapshot.make(depth: [], confidence: [], width: 0, height: 0).isEmpty)
}

/// With `rotateForPortrait: false` (a landscape mount) the buffer itself is the scene: the default
/// 16 × 24 grid is laid straight over the 96 × 64 buffer, so the near first 24 pixel columns land
/// in grid column 0 and column 15 stays far. Catches the remap being applied unconditionally.
@Test func snapshotWorksUnrotated() {
    // Landscape mount (rotateForPortrait off): scene space is the buffer itself.
    var buf = [Float](repeating: 4.0, count: 96 * 64)
    for by in 0..<64 { for bx in 0..<24 { buf[by * 96 + bx] = 1.0 } }
    let s = DepthSnapshot.make(depth: buf, width: 96, height: 64, rotateForPortrait: false)
    #expect(s.value(col: 0, row: 0) == 1.0)
    #expect(s.value(col: 15, row: 0) == 4.0)
}
