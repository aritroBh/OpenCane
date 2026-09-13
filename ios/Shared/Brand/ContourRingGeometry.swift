//
//  ContourRingGeometry.swift
//  CaneKit (app + widget extension)
//
//  The OpenCane contour-ring drawing, shared: the ring path math the voice tile animates
//  (`ContourRings` in ios/CaneKit/UI/VoiceTile.swift, Step 58) and a static few-ring brand mark
//  (`OpenCaneMark`) that the Dynamic Island, lock-screen card, accessory widget and Control Center
//  control draw (Step 64).
//
//  Why `Shared/`: the widget extension does not link the app, so the geometry both targets draw
//  lives here (`ios/project.yml` lists `Shared/Brand` as a source of CaneKit and CaneKitWidget).
//  Moving it — not copying it — keeps the island's mark identical to the Guide's microphone rings.
//
//  Threading / isolation: `nonisolated` value types and pure functions; `Shape.path(in:)` is
//  called by SwiftUI off the main actor in a widget.
//
//  Key invariants:
//    · `SeededNoise` and the per-ring parameters are the Step 58 values bit for bit: the voice
//      tile must look the same after the move (compare `make tour` Guide pictures).
//    · No animation here: widgets do not animate, `OpenCaneMark` is `t = 0`.
//  Tests: none automated for pixels (SwiftUI shapes are not in CaneKitLogic); `make island` and
//  `make tour` pictures.
//

import SwiftUI

/// SplitMix64: a tiny deterministic generator so every ring's wobble is the same on every frame.
nonisolated struct SeededNoise {
    /// Internal state.
    private var state: UInt64
    /// - Parameter seed: any value; ring index scrambled by the caller.
    init(seed: UInt64) { state = seed }
    /// Next 64-bit value.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Next value in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// One ring's seeded shape: three sine harmonics (frequency, phase, amplitude fraction).
nonisolated struct ContourRingParameters: Sendable {
    let k1: Double, k2: Double, k3: Double
    let p1: Double, p2: Double, p3: Double
    /// Amplitude multipliers applied to the ring's base wobble `a`.
    let m1: Double, m2: Double, m3: Double

    /// The Step 58 seeding for ring `index` (0 innermost).
    init(index: Int) {
        var rng = SeededNoise(seed: UInt64(index + 1) &* 0x9E37_79B9_7F4A_7C15)
        k1 = 2 + Double(rng.next() % 3); k2 = 5 + Double(rng.next() % 4); k3 = 9 + Double(rng.next() % 5)
        p1 = rng.unit() * 2 * .pi; p2 = rng.unit() * 2 * .pi; p3 = rng.unit() * 2 * .pi
        m1 = 0.6 + 0.4 * rng.unit(); m2 = 0.45 * rng.unit(); m3 = 0.2 * rng.unit()
    }
}

/// Pure path builder for one contour ring.
nonisolated enum ContourRingGeometry {

    /// The closed path of one wobbly ring.
    /// - Parameters:
    ///   - params: the ring's seeded harmonics.
    ///   - center: ring centre.
    ///   - base: base radius (points).
    ///   - amplitude: wobble amplitude `a` (points) before the per-harmonic multipliers.
    ///   - gain: extra wobble multiplier (ripple crest), 1 when still.
    ///   - drift: phase drift (ripple), 0 when still.
    ///   - steps: polygon segments.
    static func ring(_ params: ContourRingParameters, center: CGPoint, base: Double, amplitude a: Double,
                     gain: Double = 1, drift: Double = 0, steps: Int = 144) -> Path {
        var path = Path()
        let a1 = a * params.m1, a2 = a * params.m2, a3 = a * params.m3
        for s in 0...steps {
            let th = Double(s) / Double(steps) * 2 * .pi
            let r = base + gain * (a1 * sin(params.k1 * th + params.p1 + drift)
                                   + a2 * sin(params.k2 * th + params.p2 - drift)
                                   + a3 * sin(params.k3 * th + params.p3))
            let pt = CGPoint(x: Double(center.x) + r * cos(th), y: Double(center.y) + r * sin(th))
            if s == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        return path
    }
}

/// The OpenCane brand mark: a few static contour rings around a clear centre, from the voice tile's
/// ring math. A `Shape`, so callers `.stroke` it in any tint (the island tints it by alert level).
/// Used by `NavLiveActivity` (compact leading, minimal, expanded, lock screen) and the Step 64
/// accessory widget / control.
nonisolated struct OpenCaneMark: Shape {
    /// Rings drawn. 4 reads as "rings" at 14 pt; the tile's 40 would be a grey disc.
    var ringCount: Int = 4

    /// Rings fill the inscribed circle from 30 % to 96 % of its radius. The wobble is larger than
    /// the tile's (relative to size) so it survives at island scale.
    func path(in rect: CGRect) -> Path {
        let side = Double(min(rect.width, rect.height))
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let inner = side * 0.15, outer = side * 0.46
        var path = Path()
        for i in 0..<max(1, ringCount) {
            let f = ringCount > 1 ? Double(i) / Double(ringCount - 1) : 0
            // Seed from the tile's outer rings (index 20…39) — the loosest, most recognisable wobble.
            let params = ContourRingParameters(index: 20 + i * (19 / max(1, ringCount - 1)))
            path.addPath(ContourRingGeometry.ring(params, center: center,
                                                  base: inner + (outer - inner) * f,
                                                  amplitude: side * (0.012 + 0.02 * f), steps: 72))
        }
        return path
    }
}
