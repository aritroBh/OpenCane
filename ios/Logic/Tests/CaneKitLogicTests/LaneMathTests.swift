//
//  LaneMathTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins LaneMath.swift — the LiDAR depth → 3 lanes × 2 bands reduction: portrait
//  remap, left / right and head / torso orientation, mirroring, ground skip, confidence
//  filtering, the 10th-percentile rule, invalid depths and padded CVPixelBuffer strides. Also pins
//  three small types from LaneReport.swift that ride on the same pipeline: the debug-grid
//  `TileLevel` colours, `MountTilt` (aim window 3–8° down, down-positive sign, ground usable 0–15°)
//  and `PublishGate` (a 15 Hz cap must really publish 15 Hz from 30 / 60 Hz ARKit frames).
//
//  Callers: `DepthFrameProcessor` (app) runs `LaneMath.computeLanes(depth:depthBytesPerRow:…)` on
//  every ARKit depth map, gates publication with `PublishGate` and ground hazards with
//  `MountTilt.groundUsable`; `ContentView` shows `MountTilt.status`. Breaks these catch: lanes
//  swapped or rotated (a wall on the left buzzing right), pavement or a 5 % noise speck read as an
//  obstacle, NaN / 0 / row-padding bytes read as a 0 m hit, and the 10 Hz publish bug seen on the
//  real phone. ⚠ Re-run these plus a clamped-phone device test before touching the rotation, ground
//  skip, percentile or stride handling (CODE_REFERENCE `LaneMath.swift`).
//
//  Key invariants / fixtures: `portraitBuffer` builds a 256 × 192 landscape buffer from a
//  scene-space function with the engine's remap (bufX = sceneY, bufY = bufH − 1 − sceneX).
//  Scene = 192 wide × 256 tall; lanes 64 px; usable height 192 → head / torso bands of 96 px.
//  Depths in metres.
//

import Foundation
import Testing
@testable import CaneKitLogic

/// Builds a landscape sensor buffer (bufW × bufH) from a scene-space function, using the
/// same portrait remap the engine uses (bufX = sceneY, bufY = bufH-1-sceneX).
private func portraitBuffer(bufW: Int = 256, bufH: Int = 192,
                            _ f: (_ sceneX: Int, _ sceneY: Int) -> Float) -> [Float] {
    var d = [Float](repeating: 0, count: bufW * bufH)
    for by in 0..<bufH {
        for bx in 0..<bufW {
            let sceneY = bx
            let sceneX = bufH - 1 - by
            d[by * bufW + bx] = f(sceneX, sceneY)
        }
    }
    return d
}

// Scene space in portrait: 192 wide × 256 tall. Lanes are 64 px wide; usable height 192 → bands of 96.
// (The bottom 25 %, scene y ≥ 192, is the `groundSkipFraction` band and is never read.)

/// Facing a flat wall 3 m away, every cell and the centre read 3 m.
@Test func uniformWallReadsSameEverywhere() {
    let d = portraitBuffer { _, _ in 3.0 }
    let g = LaneMath.computeLanes(depth: d, confidence: nil, width: 256, height: 192)
    #expect(g.head == [3, 3, 3])
    #expect(g.torso == [3, 3, 3])
    #expect(g.centerDepth == 3)
}

/// A wall on the left (phone upright on the cane) shows only in the left lane.
@Test func leftWallOnlyHitsLeftLanes() {
    let d = portraitBuffer { x, _ in x < 64 ? 1.0 : 4.0 }
    let g = LaneMath.computeLanes(depth: d, confidence: nil, width: 256, height: 192)
    #expect(g.head[0] == 1 && g.torso[0] == 1)
    #expect(g.head[1] == 4 && g.head[2] == 4 && g.torso[1] == 4 && g.torso[2] == 4)
}

/// With the phone mounted the other way, the mirror setting puts a left wall back on the left.
@Test func mirrorSwapsLeftAndRight() {
    let d = portraitBuffer { x, _ in x < 64 ? 1.0 : 4.0 }
    var c = LaneConfig()
    c.mirrorLeftRight = true
    let g = LaneMath.computeLanes(depth: d, confidence: nil, width: 256, height: 192, config: c)
    #expect(g.head[2] == 1 && g.torso[2] == 1)
    #expect(g.head[0] == 4 && g.torso[0] == 4)
}

/// An overhanging sign in the top of the view registers in the head row, not the torso.
@Test func headRowIsTopBand() {
    // Obstacle only in the top 96 scene rows, centre lane.
    let d = portraitBuffer { x, y in (x >= 64 && x < 128 && y < 96) ? 1.0 : 4.0 }
    let g = LaneMath.computeLanes(depth: d, confidence: nil, width: 256, height: 192)
    #expect(g.head[1] == 1)
    #expect(g.torso[1] == 4)
    #expect(g.head[0] == 4 && g.head[2] == 4)
}

/// Pavement in the bottom quarter of the view is never reported as an obstacle.
@Test func groundBandIsSkipped() {
    // Bottom 25 % (scene y ≥ 192) is pavement at 0.3 m.
    let d = portraitBuffer { _, y in y >= 192 ? 0.3 : 4.0 }
    let g = LaneMath.computeLanes(depth: d, confidence: nil, width: 256, height: 192)
    #expect(g.head == [4, 4, 4])
    #expect(g.torso == [4, 4, 4])
    #expect(g.centerDepth == 4)
}

/// Low-confidence LiDAR pixels (glass, sunlight) are dropped, leaving the lane clear.
@Test func lowConfidencePixelsAreIgnored() {
    let d = portraitBuffer { x, _ in x < 64 ? 1.0 : 4.0 }
    // Confidence 0 (low) on the left third → no valid samples there → clear.
    var conf = [UInt8](repeating: 2, count: 256 * 192)
    for by in 0..<192 {
        for bx in 0..<256 where (192 - 1 - by) < 64 { conf[by * 256 + bx] = 0 }
    }
    let g = LaneMath.computeLanes(depth: d, confidence: conf, width: 256, height: 192)
    #expect(g.head[0] == .infinity && g.torso[0] == .infinity)
    #expect(g.torso[1] == 4)
}

/// At point-blank range (< 35 cm, e.g. 15 cm against a wall), SPAD saturation marks returns
/// confidence 0. Proximity overrides confidence so the wall registers as an urgent obstacle rather than clear.
@Test func pointBlankLowConfidenceObstacleIsDetected() {
    // 15 cm return across the left third with confidence 0 (low).
    let d = portraitBuffer { x, _ in x < 64 ? 0.15 : 4.0 }
    var conf = [UInt8](repeating: 2, count: 256 * 192)
    for by in 0..<192 {
        for bx in 0..<256 where (192 - 1 - by) < 64 { conf[by * 256 + bx] = 0 }
    }
    let g = LaneMath.computeLanes(depth: d, confidence: conf, width: 256, height: 192)
    #expect(abs(g.head[0] - 0.15) < 0.01)
    #expect(abs(g.torso[0] - 0.15) < 0.01)
    #expect(g.torso[1] == 4)
}

/// A thin pole covering 20 % of a cell registers; a 5 % speck of noise does not.
@Test func tenthPercentileNeedsMoreThanTenPercentOfCell() {
    // 20 % of the centre torso cell at 1 m → reports 1 m; 5 % → reports the 4 m background.
    let twenty = portraitBuffer { x, y in (x >= 64 && x < 128 && y >= 96 && y < 192 && (y - 96) < 20) ? 1.0 : 4.0 }
    let five = portraitBuffer { x, y in (x >= 64 && x < 128 && y >= 96 && y < 192 && (y - 96) < 4) ? 1.0 : 4.0 }
    #expect(LaneMath.computeLanes(depth: twenty, confidence: nil, width: 256, height: 192).torso[1] == 1)
    #expect(LaneMath.computeLanes(depth: five, confidence: nil, width: 256, height: 192).torso[1] == 4)
}

/// Zero and NaN depth pixels (no return) never read as an obstacle at 0 m.
@Test func zeroAndNaNDepthsAreInvalid() {
    let d = portraitBuffer { x, _ in x < 64 ? 0.0 : (x < 128 ? Float.nan : 4.0) }
    let g = LaneMath.computeLanes(depth: d, confidence: nil, width: 256, height: 192)
    #expect(g.torso[0] == .infinity)
    #expect(g.torso[1] == .infinity)
    #expect(g.torso[2] == 4)
}

/// With portrait rotation off, buffer columns map straight to lanes.
@Test func landscapeModeUsesBufferAsScene() {
    // rotate off: buffer x = scene x, so a left wall is buffer columns < bufW/3.
    var d = [Float](repeating: 4, count: 256 * 192)
    for by in 0..<192 { for bx in 0..<85 { d[by * 256 + bx] = 1 } }
    var c = LaneConfig()
    c.rotateForPortrait = false
    let g = LaneMath.computeLanes(depth: d, confidence: nil, width: 256, height: 192, config: c)
    #expect(g.head[0] == 1 && g.torso[0] == 1)
    #expect(g.head[1] == 4 && g.torso[2] == 4)
}

/// On the phone a stride bug would shift the lanes or read NaN row padding as obstacles.
/// The app passes CVPixelBuffer memory whose rows are padded (bytesPerRow > width × bytes). The
/// raw entrypoint must honour both strides, and confidence == 1 (medium) must be accepted.
@Test func rawEntrypointHonoursPaddedRowStrides() {
    let W = 256, H = 192, dbpr = 1088, cbpr = 320          // 1024 + 64 and 256 + 64 padding
    let scene = portraitBuffer { x, _ in x < 64 ? 1.0 : 4.0 }   // left wall, tight (W×H) layout
    var dbuf = [UInt8](repeating: 0xFF, count: dbpr * H)     // 0xFF padding = NaN if ever read
    var cbuf = [UInt8](repeating: 0, count: cbpr * H)        // 0 = low confidence in the padding
    for by in 0..<H {
        for bx in 0..<W {
            var v = scene[by * W + bx]
            withUnsafeBytes(of: &v) { src in
                for k in 0..<4 { dbuf[by * dbpr + bx * 4 + k] = src[k] }
            }
            cbuf[by * cbpr + bx] = 1                         // medium everywhere
        }
    }
    var scratch = [Float]()
    let g = dbuf.withUnsafeBytes { d in
        cbuf.withUnsafeBytes { c in
            LaneMath.computeLanes(depth: d.baseAddress!, depthBytesPerRow: dbpr,
                                  confidence: c.baseAddress!, confidenceBytesPerRow: cbpr,
                                  width: W, height: H, config: LaneConfig(), scratch: &scratch)
        }
    }
    #expect(g.head[0] == 1 && g.torso[0] == 1)
    #expect(g.head[1] == 4 && g.head[2] == 4 && g.torso[1] == 4 && g.torso[2] == 4)
    #expect(g.centerDepth == 4)
}

/// The debug grid colours cells urgent < 0.7 m, near < 1.2 m, far < 2.0 m, else clear.
@Test func tileLevels() {
    #expect(TileLevel.level(for: 0.5, hasData: true) == .urgent)
    #expect(TileLevel.level(for: 1.0, hasData: true) == .near)
    #expect(TileLevel.level(for: 1.5, hasData: true) == .far)
    #expect(TileLevel.level(for: 2.5, hasData: true) == .clear)
    #expect(TileLevel.level(for: .infinity, hasData: true) == .clear)
    #expect(TileLevel.level(for: 1.0, hasData: false) == .noData)
}

/// The mount aim window (hardware/mount/DESIGN.md): 3–8° below the horizon is good; steeper
/// makes the torso lanes read pavement, shallower loses the ground reference.
@Test func mountTiltWindow() {
    #expect(MountTilt.status(downDeg: 5).ok)
    #expect(MountTilt.status(downDeg: 5).text == "Camera tilt 5° down, good")
    #expect(!MountTilt.status(downDeg: 12).ok)
    #expect(MountTilt.status(downDeg: 12).text == "Camera tilt 12° down: tilt the phone up")
    #expect(MountTilt.status(downDeg: -2).text == "Camera tilt 2° up: tilt the phone down")
    #expect(MountTilt.status(downDeg: 0.3).text == "Camera level: tilt the phone down")
    #expect(MountTilt.status(downDeg: 2.6).ok)          // shows "3°", so it must say good
    #expect(!MountTilt.status(downDeg: 8.6).ok)         // shows "9°"
}

/// Camera pitched down 5°: look = (0, −sin 5°, −cos 5°), so the transform's Z column (= −look) has
/// y = +sin 5° → +5 (down). Pitched up → negative. Level → 0.
@Test func tiltSignIsDownPositive() {
    let down5 = Float(sin(5.0 * Double.pi / 180))
    #expect(abs(MountTilt.downDegrees(cameraZColumnY: down5) - 5) < 0.01)
    #expect(MountTilt.downDegrees(cameraZColumnY: -down5) < 0)
    #expect(MountTilt.downDegrees(cameraZColumnY: 0) == 0)
}

/// 30 Hz ARKit frames through a 15 Hz cap publish every second frame (15 Hz), not every third
/// (10 Hz, the real-phone bug); 60 Hz frames publish every fourth.
@Test func publishGateHitsFifteenHertzFromThirtyHertzFrames() {
    var g = PublishGate(maxRate: 15)
    let published30 = (0..<300).filter { g.shouldPublish(at: 1000 + Double($0) / 30) }.count
    #expect(published30 == 150)          // 10 s of 30 Hz input → 15 Hz
    var h = PublishGate(maxRate: 15)
    let published60 = (0..<600).filter { h.shouldPublish(at: 1000 + Double($0) / 60) }.count
    #expect(published60 == 150)          // 10 s of 60 Hz input → 15 Hz
}

/// Ground hazards are judged only when the camera looks 0-15 deg below the horizon: the real
/// phone's false "Hole ahead" calls came at 10-57 deg with the phone in the hand.
@Test func groundHazardsNeedAMountLikeTilt() {
    #expect(MountTilt.groundUsable(downDeg: 5))
    #expect(MountTilt.groundUsable(downDeg: 14))
    #expect(!MountTilt.groundUsable(downDeg: 30))
    #expect(!MountTilt.groundUsable(downDeg: -4))
}
