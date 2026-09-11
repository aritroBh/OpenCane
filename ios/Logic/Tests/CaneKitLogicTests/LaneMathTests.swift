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

@Test func uniformWallReadsSameEverywhere() {
    let d = portraitBuffer { _, _ in 3.0 }
    let g = LaneMath.computeLanes(depth: d, confidence: nil, width: 256, height: 192)
    #expect(g.head == [3, 3, 3])
    #expect(g.torso == [3, 3, 3])
    #expect(g.centerDepth == 3)
}

@Test func leftWallOnlyHitsLeftLanes() {
    let d = portraitBuffer { x, _ in x < 64 ? 1.0 : 4.0 }
    let g = LaneMath.computeLanes(depth: d, confidence: nil, width: 256, height: 192)
    #expect(g.head[0] == 1 && g.torso[0] == 1)
    #expect(g.head[1] == 4 && g.head[2] == 4 && g.torso[1] == 4 && g.torso[2] == 4)
}

@Test func mirrorSwapsLeftAndRight() {
    let d = portraitBuffer { x, _ in x < 64 ? 1.0 : 4.0 }
    var c = LaneConfig()
    c.mirrorLeftRight = true
    let g = LaneMath.computeLanes(depth: d, confidence: nil, width: 256, height: 192, config: c)
    #expect(g.head[2] == 1 && g.torso[2] == 1)
    #expect(g.head[0] == 4 && g.torso[0] == 4)
}

@Test func headRowIsTopBand() {
    // Obstacle only in the top 96 scene rows, centre lane.
    let d = portraitBuffer { x, y in (x >= 64 && x < 128 && y < 96) ? 1.0 : 4.0 }
    let g = LaneMath.computeLanes(depth: d, confidence: nil, width: 256, height: 192)
    #expect(g.head[1] == 1)
    #expect(g.torso[1] == 4)
    #expect(g.head[0] == 4 && g.head[2] == 4)
}

@Test func groundBandIsSkipped() {
    // Bottom 25 % (scene y ≥ 192) is pavement at 0.3 m.
    let d = portraitBuffer { _, y in y >= 192 ? 0.3 : 4.0 }
    let g = LaneMath.computeLanes(depth: d, confidence: nil, width: 256, height: 192)
    #expect(g.head == [4, 4, 4])
    #expect(g.torso == [4, 4, 4])
    #expect(g.centerDepth == 4)
}

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

@Test func tenthPercentileNeedsMoreThanTenPercentOfCell() {
    // 20 % of the centre torso cell at 1 m → reports 1 m; 5 % → reports the 4 m background.
    let twenty = portraitBuffer { x, y in (x >= 64 && x < 128 && y >= 96 && y < 192 && (y - 96) < 20) ? 1.0 : 4.0 }
    let five = portraitBuffer { x, y in (x >= 64 && x < 128 && y >= 96 && y < 192 && (y - 96) < 4) ? 1.0 : 4.0 }
    #expect(LaneMath.computeLanes(depth: twenty, confidence: nil, width: 256, height: 192).torso[1] == 1)
    #expect(LaneMath.computeLanes(depth: five, confidence: nil, width: 256, height: 192).torso[1] == 4)
}

@Test func zeroAndNaNDepthsAreInvalid() {
    let d = portraitBuffer { x, _ in x < 64 ? 0.0 : (x < 128 ? Float.nan : 4.0) }
    let g = LaneMath.computeLanes(depth: d, confidence: nil, width: 256, height: 192)
    #expect(g.torso[0] == .infinity)
    #expect(g.torso[1] == .infinity)
    #expect(g.torso[2] == 4)
}

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

@Test func tileLevels() {
    #expect(TileLevel.level(for: 0.5, hasData: true) == .urgent)
    #expect(TileLevel.level(for: 1.0, hasData: true) == .near)
    #expect(TileLevel.level(for: 1.5, hasData: true) == .far)
    #expect(TileLevel.level(for: 2.5, hasData: true) == .clear)
    #expect(TileLevel.level(for: .infinity, hasData: true) == .clear)
    #expect(TileLevel.level(for: 1.0, hasData: false) == .noData)
}
