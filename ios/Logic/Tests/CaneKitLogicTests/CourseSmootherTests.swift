//
//  CourseSmootherTests.swift
//  CaneKitLogicTests
//
//  Pins CourseSmoother: jittery GPS must not look like a turn, a real turn must show up.
//
//  Source pinned: `ios/Logic/Sources/CaneKitLogic/CourseSmoother.swift` (15 m trail / 5-fix ends,
//  accuracy-gated). Caller: `NavigationEngine` (app), which feeds the smoothed course into the
//  `OffCourseDetector` veer decision while walking (Step 11 "jitter-proof veer").
//  Breaks these catch: a per-fix GPS course reaching the veer cue again (±6 m jitter at walking
//  pace fires "Veer right." constantly), a smoother so sluggish a real 90° turn never shows, and a
//  course computed from 40 m fixes or from a couple of metres of travel.
//  Must pass on Linux CI (`swift:6.2`), hence the hand-rolled `LCG` instead of a seeded RNG.
//

import Foundation
import Testing
@testable import CaneKitLogic

/// Local grid origin on the UIUC campus; `at(north:east:)` offsets from here.
private let origin = Coordinate(latitude: 40.1100, longitude: -88.2240)

/// Metres north/east of the origin → coordinate.
private func at(north: Double, east: Double) -> Coordinate {
    Coordinate(latitude: origin.latitude + north / 111_195,
               longitude: origin.longitude + east / (111_195 * cos(origin.latitude * .pi / 180)))
}

/// Deterministic pseudo-random jitter in [-a, a] (no Foundation RNG seeding on Linux needed).
private struct LCG {
    /// Generator state; the fixed seed 42 makes every run (macOS and Linux) see the same jitter.
    var state: UInt64 = 42
    /// Advances the 64-bit LCG (Knuth MMIX constants) and maps its top 53 bits to [-a, a] metres.
    mutating func next(_ a: Double) -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return (Double(state >> 11) / Double(1 << 53) * 2 - 1) * a
    }
}

/// Walking due north at 1.3 m/s with ±6 m jitter on every fix: the smoothed course never exceeds
/// the 25° veer threshold on 3 consecutive fixes (what OffCourseDetector needs to fire), and its
/// median error stays under 10°. A per-fix course fails this constantly.
@Test func jitterOnAStraightWalkNeverLooksLikeAVeer() {
    var s = CourseSmoother()
    var rng = LCG()
    var errors: [Double] = []
    for t in 0..<120 {
        let p = at(north: Double(t) * 1.3 + rng.next(6), east: rng.next(6))
        let c = s.update(GeoFix(coordinate: p, accuracy: 8, speed: 1.3, timestamp: Double(t)))
        if t > 30, let c { errors.append(abs(GeoMath.wrap180(c))) }
    }
    let triples = zip(zip(errors, errors.dropFirst()), errors.dropFirst(2)).filter { $0.0 > 25 && $0.1 > 25 && $1 > 25 }
    #expect(triples.isEmpty, "a veer would have fired")
    let median = errors.sorted()[errors.count / 2]
    #expect(median < 10, "median smoothed error \(median)°")
}

/// A clean 90° right turn: once the walker is well into the new leg the course reads east.
@Test func aRealTurnShowsUpAfterTheBaseline() {
    var s = CourseSmoother()
    var last: Double?
    for t in 0..<20 { last = s.update(GeoFix(coordinate: at(north: Double(t) * 1.3, east: 0), accuracy: 5, speed: 1.3, timestamp: Double(t))) }
    #expect(last.map { abs(GeoMath.wrap180($0)) < 5 } == true)
    for t in 1...25 {
        last = s.update(GeoFix(coordinate: at(north: 19 * 1.3, east: Double(t) * 1.3), accuracy: 5, speed: 1.3, timestamp: Double(19 + t)))
    }
    #expect(last.map { abs(GeoMath.wrap180($0 - 90)) < 10 } == true)
}

/// Poor fixes are ignored and too little travel gives no answer.
@Test func poorFixesAndShortTracksGiveNothing() {
    var s = CourseSmoother()
    for t in 0..<10 {
        let r = s.update(GeoFix(coordinate: at(north: Double(t), east: 0), accuracy: 40, speed: 1, timestamp: Double(t)))
        #expect(r == nil)
    }
    var s2 = CourseSmoother()
    for t in 0..<6 {
        let r = s2.update(GeoFix(coordinate: at(north: Double(t) * 0.5, east: 0), accuracy: 5, speed: 0.5, timestamp: Double(t)))
        #expect(r == nil)                                            // only 2.5 m of travel
    }
}
