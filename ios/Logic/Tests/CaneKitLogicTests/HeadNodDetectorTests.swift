//
//  HeadNodDetectorTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins HeadNodDetector.swift — the AirPods "double nod to talk" gesture. Every case is
//  either the gesture itself or a head movement a walker makes all day that must stay silent
//  (walking sway, looking down at a curb). The numbers exercised here are the detector's
//  **untuned placeholders**; when they are re-measured on the cane, change them and these fixtures
//  together.
//
//  Key invariants / fixtures:
//    · Samples are synthesised at 50 Hz (CMHeadphoneMotionManager delivers ~25–50 Hz).
//    · `nod(at:)` is a half-sine excursion of `amplitude` degrees over `duration` seconds that
//      starts and ends at `rest`. Negative amplitude = chin down (assumed sign; unmeasured — the
//      detector is direction-agnostic, see the ponytail note in HeadNodDetector.swift).
//    · `fires(_:_:)` feeds a sample list in order and returns the times `update` returned true.
//

import Foundation
import Testing
@testable import CaneKitLogic

private let hz = 50.0

/// Half-sine nod: leaves `rest`, reaches `rest + amplitude` at mid-duration, back at `rest` at the end.
private func nod(at start: Double, amplitude: Double = -20, duration: Double = 0.5, rest: Double = 0) -> [(Double, Double)] {
    let n = Int(duration * hz)
    return (0...n).map { i in
        (start + Double(i) / hz, rest + amplitude * sin(.pi * Double(i) / Double(n)))
    }
}

/// Head still at `pitch` from `from` to `to` (exclusive), 50 Hz.
private func still(from: Double, to: Double, pitch: Double = 0) -> [(Double, Double)] {
    stride(from: from, to: to, by: 1 / hz).map { ($0, pitch) }
}

/// Linear ramp of pitch from `a` to `b` over [`from`, `to`).
private func ramp(from: Double, to: Double, pitch a: Double, _ b: Double) -> [(Double, Double)] {
    stride(from: from, to: to, by: 1 / hz).map { t in (t, a + (b - a) * (t - from) / (to - from)) }
}

/// Feeds every sample and returns the times at which the detector fired.
private func fires(_ d: inout HeadNodDetector, _ samples: [(Double, Double)]) -> [Double] {
    var out: [Double] = []
    for (t, p) in samples where d.update(pitchDeg: p, now: t) { out.append(t) }
    return out
}

/// One nod is a glance at the pavement, not a request to talk.
@Test func singleNodIsSilent() {
    var d = HeadNodDetector()
    let f = fires(&d, still(from: 0, to: 1) + nod(at: 1) + still(from: 1.52, to: 5))
    #expect(f.isEmpty)
}

/// Two quick nods fire exactly once, on the second nod, and nothing afterwards.
@Test func doubleNodFiresOnceOnTheSecondNod() {
    var d = HeadNodDetector()
    let f = fires(&d, still(from: 0, to: 1) + nod(at: 1) + still(from: 1.52, to: 2) + nod(at: 2) + still(from: 2.52, to: 6))
    #expect(f.count == 1)
    #expect(f.first.map { $0 >= 2 && $0 <= 2.5 } == true)
}

/// Two nods 3 s apart are two single nods (pair window 2.5 s).
@Test func nodsTooFarApartAreSilent() {
    var d = HeadNodDetector()
    let f = fires(&d, still(from: 0, to: 1) + nod(at: 1) + still(from: 1.52, to: 4) + nod(at: 4) + still(from: 4.52, to: 8))
    #expect(f.isEmpty)
}

/// Walking bobs the head ±5° at about step rate; that is far below the 15° amplitude.
@Test func walkingSwayIsSilent() {
    var d = HeadNodDetector()
    let sway = (0..<Int(10 * hz)).map { i -> (Double, Double) in
        let t = Double(i) / hz
        return (t, 5 * sin(2 * .pi * 2 * t))
    }
    #expect(fires(&d, sway).isEmpty)
}

/// Looking down at a curb and back up is big but slow: never a nod, whether the tilt down is slow
/// with a quick return, or quick with a hold at the bottom — either way the return completes more
/// than 0.8 s after the head left rest. Each pattern is done twice within 2.5 s so that, were the
/// timing rule broken, the two would pair up and fire (the fixture was checked to do so).
@Test func aLargeSlowTiltIsSilent() {
    var slow = HeadNodDetector()
    let ramps = still(from: 0, to: 1) + ramp(from: 1, to: 2.5, pitch: 0, -30) + ramp(from: 2.5, to: 2.8, pitch: -30, 0)
        + still(from: 2.8, to: 3.2) + ramp(from: 3.2, to: 4.7, pitch: 0, -30) + ramp(from: 4.7, to: 5, pitch: -30, 0)
        + still(from: 5, to: 8)
    #expect(fires(&slow, ramps).isEmpty)

    var held = HeadNodDetector()
    let hold = still(from: 0, to: 1) + ramp(from: 1, to: 1.3, pitch: 0, -30) + still(from: 1.3, to: 2.5, pitch: -30)
        + ramp(from: 2.5, to: 2.8, pitch: -30, 0) + still(from: 2.8, to: 3.5)
        + ramp(from: 3.5, to: 3.8, pitch: 0, -30) + still(from: 3.8, to: 4.8, pitch: -30)
        + ramp(from: 4.8, to: 5.1, pitch: -30, 0) + still(from: 5.1, to: 8)
    #expect(fires(&held, hold).isEmpty)
}

/// After a fire, nods inside the 3 s refractory are swallowed (they do not fire and do not start a
/// new pair); a fresh double nod after the refractory fires again.
@Test func refractoryHoldsAfterAFire() {
    var d = HeadNodDetector()
    let f = fires(&d, still(from: 0, to: 1) + nod(at: 1) + still(from: 1.52, to: 2) + nod(at: 2)      // fires ≈ 2.4
        + still(from: 2.52, to: 3) + nod(at: 3) + still(from: 3.52, to: 4) + nod(at: 4)          // 3rd, 4th: refractory
        + still(from: 4.52, to: 6) + nod(at: 6) + still(from: 6.52, to: 7) + nod(at: 7)          // fresh pair
        + still(from: 7.52, to: 10))
    #expect(f.count == 2)
    #expect(f.map { $0 < 3 } == [true, false])
    #expect(f.last.map { $0 >= 7 } == true)
}

/// `reset()` forgets a pending first nod: a nod, a reset, a nod is two single nods.
@Test func resetClearsAPendingFirstNod() {
    var d = HeadNodDetector()
    let before = fires(&d, still(from: 0, to: 1) + nod(at: 1) + still(from: 1.52, to: 1.8))
    d.reset()
    let after = fires(&d, still(from: 1.8, to: 2) + nod(at: 2) + still(from: 2.52, to: 5))
    #expect(before.isEmpty)
    #expect(after.isEmpty)
}
