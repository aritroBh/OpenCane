//
//  LaneGeometryTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins the metric lane bands of LaneMath.swift (Step 51): `LaneGeometry` (height of a
//  depth sample above the ground from ARKit's world-up row), the floor / torso / head split in
//  centimetres (floor < 25 cm dropped, 25–140 cm torso, ≥ 140 cm head, camera 95 cm), the coverage
//  flags (a band the camera cannot see at 150 cm is `.infinity` + flag false), blind samples
//  counted toward their nominal band, plus the three consumers of coverage that live in
//  LaneReport.swift (`MountTilt.status(downDeg:headCover:)`, `MountTilt.headCoverLimitDeg`,
//  `TileLevel.noCover`) and `HeadCoverNotice`.
//
//  Why: the first cane walk (`canekit-2026-09-13T04-36-32Z.jsonl`) held the phone 45° down. The row
//  bands then read knee-high things as "head" and the floor 1.45 m away as "torso": "Head height"
//  for the whole walk and a centre Geiger on bare floor. 0 of 503 head cells could have been 1.4 m
//  above the ground.
//
//  Fixture: `syntheticDepth(pitchDeg:rollDeg:camH:surfaces:)` renders a 256 × 192 landscape depth
//  buffer through a pinhole (f = 128 / tan 33.5° ≈ 193.4 px, principal point at the centre) for a
//  portrait phone pitched `pitchDeg` below the horizon and rolled `rollDeg`, `camH` metres above a
//  flat floor, and returns the `LaneGeometry` built from the *same* rotation. Depth is z-depth
//  (along the optical axis, as ARKit's `sceneDepth` and `GroundSampler`). Surfaces: a wall, a
//  hanging sign, a standing person, a box; the nearest hit wins; a ray that hits nothing (sky)
//  gets 6 m at confidence 0 (a real far low-confidence return: neither valid nor blind).
//  World frame as ARKit: x right, y up, z back (forward = −z). Camera axes for a portrait-up
//  phone pitched θ down: x (buffer u, runs down the scene) = (0, −cos θ, sin θ), y (buffer −v, the
//  walker's right) = (1, 0, 0), z (backward) = (0, sin θ, cos θ); roll turns x and y about z.
//  Orientation on the real phone is only verifiable on hardware (the `depth_geometry` log record).
//

import Foundation
import Testing
@testable import CaneKitLogic

/// Something the synthetic camera can see. Distances metres, heights metres above the floor,
/// `lateral` metres to the walker's right (negative = left).
private enum Surface {
    /// A vertical plane across the whole view `forward` metres ahead, floor to sky.
    case wall(forward: Float)
    /// A flat board `forward` ahead spanning `bottom…top` in height and `lateral` sideways.
    case hangingSign(forward: Float, bottom: Float, top: Float, lateral: ClosedRange<Float>)
    /// A person-sized board from the floor to `top`, `lateral` wide.
    case person(forward: Float, lateral: ClosedRange<Float>, top: Float)
    /// A box face `forward` ahead from the floor to `top`, `lateral` wide.
    case box(forward: Float, top: Float, lateral: ClosedRange<Float>)
}

private let bufW = 256
private let bufH = 192
private let focal: Float = 128 / tan(33.5 * .pi / 180)
private let cx: Float = 128
private let cy: Float = 96

/// Renders `surfaces` (plus the floor) into a z-depth buffer and a confidence map, and returns the
/// matching `LaneGeometry`. See the file header for the frame conventions.
private func syntheticDepth(pitchDeg: Float, rollDeg: Float = 0, camH: Float = 0.95,
                            surfaces: [Surface] = []) -> (depth: [Float], confidence: [UInt8], geometry: LaneGeometry) {
    let t = pitchDeg * .pi / 180, r = rollDeg * .pi / 180
    let (s, c) = (sin(t), cos(t))
    // Unrolled axes as (right, up, back).
    let x0 = SIMD3<Float>(0, -c, s), y0 = SIMD3<Float>(1, 0, 0), z = SIMD3<Float>(0, s, c)
    let x = cos(r) * x0 + sin(r) * y0
    let y = -sin(r) * x0 + cos(r) * y0
    let geometry = LaneGeometry(fx: focal, fy: focal, cx: cx, cy: cy, upX: x.y, upY: y.y, upZ: z.y)
    var depth = [Float](repeating: 6, count: bufW * bufH)
    var conf = [UInt8](repeating: 0, count: bufW * bufH)
    for v in 0..<bufH {
        for u in 0..<bufW {
            let a = (Float(u) - cx) / focal, b = -(Float(v) - cy) / focal
            let dir = a * x + b * y - z                 // world offset per metre of z-depth
            let right = dir.x, up = dir.y, fwd = -dir.z
            var best = Float.infinity
            if up < 0 { best = min(best, camH / -up) }                       // floor
            for surface in surfaces {
                let f: Float, inside: (Float, Float) -> Bool                  // (height, lateral) at the hit
                switch surface {
                case .wall(let w): f = w; inside = { _, _ in true }
                case .hangingSign(let w, let lo, let hi, let lat): f = w; inside = { h, l in h >= lo && h <= hi && lat.contains(l) }
                case .person(let w, let lat, let top): f = w; inside = { h, l in h >= 0 && h <= top && lat.contains(l) }
                case .box(let w, let top, let lat): f = w; inside = { h, l in h >= 0 && h <= top && lat.contains(l) }
                }
                guard fwd > 0 else { continue }
                let d = f / fwd
                if d < best, inside(camH + d * up, d * right) { best = d }
            }
            if best.isFinite, best < 6 {
                depth[v * bufW + u] = best
                conf[v * bufW + u] = 2
            }
        }
    }
    return (depth, conf, geometry)
}

/// `LaneMath.computeLanes` over a synthetic scene with the default `LaneConfig`.
private func lanes(_ scene: (depth: [Float], confidence: [UInt8], geometry: LaneGeometry)) -> LaneGrid {
    LaneMath.computeLanes(depth: scene.depth, confidence: scene.confidence, width: bufW, height: bufH,
                          geometry: scene.geometry)
}

@Suite("Lane geometry and metric bands")
struct LaneGeometryTests {

    private let inf: [Float] = [.infinity, .infinity, .infinity]

    // MARK: Floor

    /// The first cane walk's Geiger: at 45° the torso rows read the floor 1.45 m ahead. Metric bands
    /// drop it; the head band cannot be seen at all.
    @Test func metricBandsDropTheFloorAtFortyFiveDegrees() {
        let g = lanes(syntheticDepth(pitchDeg: 45))
        #expect(g.bandMode == .metric)
        #expect(g.head == inf && g.torso == inf)
        #expect(g.headCoverage == [false, false, false])
        #expect(g.torsoCoverage == [true, true, true])
        #expect(g.centerDepth.isInfinite)
    }

    /// The design pitch: floor dropped, both bands covered.
    @Test func metricBandsDropTheFloorAtFiveDegrees() {
        let g = lanes(syntheticDepth(pitchDeg: 5))
        #expect(g.bandMode == .metric)
        #expect(g.head == inf && g.torso == inf)
        #expect(g.headCoverage == [true, true, true] && g.torsoCoverage == [true, true, true])
    }

    // MARK: Walls, signs, people, boxes

    /// At the mount tilt a wall 1 m ahead fills both bands (which is why Step 52's overhang
    /// signature hands it to the torso logic).
    @Test func aWallIsTorsoAndHeadAtMountTilt() {
        let g = lanes(syntheticDepth(pitchDeg: 5, surfaces: [.wall(forward: 1.0)]))
        #expect(g.bandMode == .metric)
        for lane in 0..<3 {
            #expect(abs(g.head[lane] - 1.0) < 0.1)
            #expect(abs(g.torso[lane] - 1.0) < 0.1)
        }
    }

    /// At 45° the same wall is torso only (z-depth of the upper rows ≈ 0.85–1.2 m) and the head band
    /// is uncovered, not "clear".
    @Test func aWallAtFortyFiveDegreesIsTorsoOnly() {
        let g = lanes(syntheticDepth(pitchDeg: 45, surfaces: [.wall(forward: 1.0)]))
        #expect(g.bandMode == .metric)
        #expect(g.torso[1] > 0.8 && g.torso[1] < 1.1)
        #expect(g.head == inf && g.headCoverage == [false, false, false])
    }

    /// The case the head cue exists for: a sign 1.3 m ahead, 1.5–1.9 m high, over the centre lane.
    @Test func aHangingSignIsHeadOnlyAtMountTilt() {
        let g = lanes(syntheticDepth(pitchDeg: 5, surfaces: [.hangingSign(forward: 1.3, bottom: 1.5, top: 1.9, lateral: -0.2...0.2)]))
        #expect(abs(g.head[1] - 1.3) < 0.1)
        #expect(g.torso[1].isInfinite)
        #expect(g.head[0].isInfinite && g.head[2].isInfinite)
    }

    /// The risk the app now admits: at 45° the same sign is invisible, and coverage says so.
    @Test func aHangingSignIsInvisibleAtFortyFiveDegrees() {
        let g = lanes(syntheticDepth(pitchDeg: 45, surfaces: [.hangingSign(forward: 1.3, bottom: 1.5, top: 1.9, lateral: -0.2...0.2)]))
        #expect(g.head == inf && g.torso == inf)
        #expect(g.headCoverage == [false, false, false])
    }

    /// A standing person fills both bands at about the same distance (the decider calls it torso).
    @Test func aPersonIsTorsoAndHead() {
        let g = lanes(syntheticDepth(pitchDeg: 5, surfaces: [.person(forward: 1.5, lateral: -0.3...0.3, top: 1.75)]))
        #expect(abs(g.head[1] - 1.5) < 0.1)
        #expect(abs(g.torso[1] - 1.5) < 0.1)
    }

    /// Tonight's 260 frames: a knee-high box 1 m ahead at 45° is torso, never head.
    @Test func kneeHighBoxAtFortyFiveDegreesIsTorsoNotHead() {
        let g = lanes(syntheticDepth(pitchDeg: 45, surfaces: [.box(forward: 1.0, top: 0.5, lateral: -2...2)]))
        #expect(abs(g.torso[1] - 1.0) < 0.2)
        #expect(g.head == inf)
    }

    // MARK: Coverage

    /// Head cover is an output of the geometry: covered to ≈ 19° (camera 95 cm, 140 cm at 150 cm
    /// z-depth), gone beyond, and never comes back as the pitch steepens.
    @Test func headCoverageFallsOffPastTheGeometryLimit() {
        var previous = true
        for pitch in stride(from: Float(0), through: 40, by: 2) {
            let covered = lanes(syntheticDepth(pitchDeg: pitch)).headCoverage.contains(true)
            if pitch <= 12 { #expect(covered, "pitch \(pitch)") }
            if pitch >= 20 { #expect(!covered, "pitch \(pitch)") }
            #expect(previous || !covered, "coverage came back at \(pitch)°")
            previous = covered
        }
    }

    /// `MountTilt.headCoverLimitDeg` (the z-depth formula) agrees with the per-lane flag sweep to
    /// within a degree: covered one degree under the limit, uncovered one degree over.
    @Test func headCoverLimitFollowsTheGeometry() {
        let limit = MountTilt.headCoverLimitDeg()
        #expect(abs(limit - 19.0) < 0.3)
        #expect(lanes(syntheticDepth(pitchDeg: limit - 1)).headCoverage == [true, true, true])
        #expect(lanes(syntheticDepth(pitchDeg: limit + 1)).headCoverage == [false, false, false])
        // A taller camera sees head height from a steeper pitch.
        #expect(MountTilt.headCoverLimitDeg(cameraHeightCm: 110) > limit)
    }

    /// Step 48 semantics survive: a blind (0 m) left third blinds the cells its rays normally feed —
    /// both bands at 5°, torso only at 45° (the head band has no rays there to be blind).
    @Test func blindSamplesCountTowardTheirNominalBand() {
        for pitch: Float in [5, 45] {
            var scene = syntheticDepth(pitchDeg: pitch)
            for v in 0..<bufH {
                for u in 0..<bufW where bufH - 1 - v < 64 {       // scene x 0…63 = left lane
                    scene.depth[v * bufW + u] = 0
                }
            }
            let g = lanes(scene)
            #expect(g.torsoBlind[0] > 0.95, "pitch \(pitch)")
            if pitch == 5 { #expect(g.headBlind[0] > 0.95) } else { #expect(g.headBlind[0] == 0) }
        }
    }

    /// Roll is compensated by the world-up row for free: a 10° rolled floor is still no obstacle.
    @Test func rollDoesNotBreakTheBands() {
        let g = lanes(syntheticDepth(pitchDeg: 5, rollDeg: 10))
        #expect(g.head == inf && g.torso == inf)
    }

    // MARK: Geometry primitives

    /// `pitchOnly` (tests, docs, offline replay) is exactly the fixture's rotation with no roll, and
    /// reads its own pitch back.
    @Test func pitchOnlyGeometryMatchesTheTransformRow() {
        for pitch: Float in [0, 5, 30, 45] {
            let fromRotation = syntheticDepth(pitchDeg: pitch).geometry
            let pitchOnly = LaneGeometry.pitchOnly(downDeg: pitch, fx: focal, fy: focal, cx: cx, cy: cy)
            #expect(abs(fromRotation.upX - pitchOnly.upX) < 1e-5)
            #expect(abs(fromRotation.upY - pitchOnly.upY) < 1e-5)
            #expect(abs(fromRotation.upZ - pitchOnly.upZ) < 1e-5)
            #expect(abs(pitchOnly.pitchDownDeg - pitch) < 0.01)
        }
        let landscape = LaneGeometry.pitchOnly(downDeg: 10, portrait: false, fx: focal, fy: focal, cx: cx, cy: cy)
        #expect(landscape.upX == 0 && landscape.upY > 0.98)
    }

    /// Height is linear in depth and starts at the camera: 95 cm at 0 m, and the principal-point ray
    /// of a level camera stays at 95 cm at any depth; one metre along a 45°-down optical axis loses
    /// 70.7 cm.
    @Test func heightIsLinearInDepth() {
        let level = LaneGeometry.pitchOnly(downDeg: 0, fx: focal, fy: focal, cx: cx, cy: cy)
        #expect(level.heightCm(u: 128, v: 96, depthM: 0, cameraHeightCm: 95) == 95)
        #expect(abs(level.heightCm(u: 128, v: 96, depthM: 3, cameraHeightCm: 95) - 95) < 1e-3)
        let steep = LaneGeometry.pitchOnly(downDeg: 45, fx: focal, fy: focal, cx: cx, cy: cy)
        let h1 = steep.heightCm(u: 128, v: 96, depthM: 1, cameraHeightCm: 95)
        let h2 = steep.heightCm(u: 128, v: 96, depthM: 2, cameraHeightCm: 95)
        #expect(abs(h1 - (95 - 70.71)) < 0.05)
        #expect(abs((h2 - 95) - 2 * (h1 - 95)) < 0.05)
    }

    // MARK: Consumers of coverage (LaneReport.swift)

    /// The Mount card: steep and uncovered says so (ok false); covered is good; up / level unchanged.
    @Test func mountTiltStatusSaysTooSteepForHeadCover() {
        let steep = MountTilt.status(downDeg: 45, headCover: false)
        #expect(!steep.ok && steep.text == "Camera tilt 45° down: too steep for head-height cover")
        let good = MountTilt.status(downDeg: 14, headCover: true)
        #expect(good.ok && good.text == "Camera tilt 14° down, good")
        #expect(MountTilt.status(downDeg: -3, headCover: true).text == "Camera tilt 3° up: tilt the phone down")
        #expect(MountTilt.status(downDeg: 0.2, headCover: true).text == "Camera level: tilt the phone down")
    }

    /// A band the camera cannot see is NO COVER — never CLEAR, whatever its value — and no data
    /// still wins over no cover.
    @Test func tileNoCoverIsNotClear() {
        #expect(TileLevel.level(for: .infinity, hasData: true, covered: false) == .noCover)
        #expect(TileLevel.level(for: 1.0, hasData: true, covered: false) == .noCover)
        #expect(TileLevel.level(for: 1.0, hasData: true, covered: true) == .near)
        #expect(TileLevel.level(for: .infinity, hasData: true) == .clear)
        #expect(TileLevel.level(for: .infinity, hasData: false, covered: false) == .noData)
    }

    // MARK: HeadCoverNotice (the route-start admission)

    /// "Camera too steep for head-height cover. Torso obstacles only." once per route, after 2 s of
    /// trusted, metric, uncovered frames; a new route re-arms it.
    @Test func headCoverNoticeSpeaksOncePerRouteAfterTheHold() {
        var n = HeadCoverNotice()                       // `update` is mutating: bind, then expect
        let s1 = n.update(metric: true, trusted: true, headCovered: false, now: 0)
        #expect(!s1)
        let s2 = n.update(metric: true, trusted: true, headCovered: false, now: 1.9)
        #expect(!s2)
        let s3 = n.update(metric: true, trusted: true, headCovered: false, now: 2.0)
        #expect(s3)
        let s4 = n.update(metric: true, trusted: true, headCovered: false, now: 10)
        #expect(!s4)      // once per route
        n.routeStarted()
        let s5 = n.update(metric: true, trusted: true, headCovered: false, now: 20)
        #expect(!s5)
        let s6 = n.update(metric: true, trusted: true, headCovered: false, now: 22)
        #expect(s6)
        #expect(HeadCoverNotice.line == "Camera too steep for head-height cover. Torso obstacles only.")
    }

    /// Rows-mode frames (no pose) say nothing about coverage; a covered frame restarts the hold (the
    /// walker picked the phone up to tap Start); a sweep frame neither counts nor resets.
    @Test func headCoverNoticeIgnoresRowsModeAndTransients() {
        var n = HeadCoverNotice()                       // `update` is mutating: bind, then expect
        let s7 = n.update(metric: false, trusted: true, headCovered: false, now: 0)
        #expect(!s7)
        let s8 = n.update(metric: false, trusted: true, headCovered: false, now: 5)
        #expect(!s8)
        let s9 = n.update(metric: true, trusted: true, headCovered: false, now: 6)
        #expect(!s9)
        let s10 = n.update(metric: true, trusted: true, headCovered: true, now: 7)
        #expect(!s10)        // resets
        let s11 = n.update(metric: true, trusted: true, headCovered: false, now: 7.5)
        #expect(!s11)
        let s12 = n.update(metric: true, trusted: false, headCovered: false, now: 9)
        #expect(!s12)      // sweep: ignored
        let s13 = n.update(metric: true, trusted: true, headCovered: false, now: 9.5)
        #expect(s13)
    }
}
