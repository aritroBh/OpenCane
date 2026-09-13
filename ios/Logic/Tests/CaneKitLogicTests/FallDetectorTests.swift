//
//  FallDetectorTests.swift
//  CaneKitLogicTests
//
//  Pins the free fall → impact → still-and-tilted sequence. Most of these tests are about what
//  must NOT fire: a cane is tapped, swung and set down hundreds of times a walk, and a detector
//  that reports any of those as a fall teaches a family to ignore the one that matters.
//
//  ⚠ The thresholds themselves are unvalidated guesses (see FallDetector.swift). These tests pin
//  the *shape* of the decision, not that the numbers are right for a real cane.
//

import Foundation
import Testing
@testable import CaneKitLogic

/// Feeds a sequence of (seconds, g, tilt°) samples and returns the falls reported.
private func run(_ samples: [(TimeInterval, Double, Double)],
                 detector: inout FallDetector) -> [Fall] {
    var out: [Fall] = []
    for (t, g, tilt) in samples {
        if let fall = detector.update(magnitudeG: g, tiltDegrees: tilt, now: t) { out.append(fall) }
    }
    return out
}

/// Steady samples at one value, every 50 ms.
private func steady(from: TimeInterval, seconds: TimeInterval, g: Double,
                    tilt: Double) -> [(TimeInterval, Double, Double)] {
    stride(from: from, through: from + seconds, by: 0.05).map { ($0, g, tilt) }
}

/// The whole sequence: upright, free fall, impact, then lying still on its side.
@Test func aRealFallIsReported() {
    var detector = FallDetector()
    var samples = steady(from: 0, seconds: 1, g: 1.0, tilt: 5)
    samples += steady(from: 1.05, seconds: 0.2, g: 0.2, tilt: 20)     // free fall
    samples.append((1.30, 3.4, 70))                                    // impact
    samples += steady(from: 1.35, seconds: 2.0, g: 1.0, tilt: 88)      // lying still

    let falls = run(samples, detector: &detector)
    #expect(falls.count == 1)
    #expect(falls.first?.impactG == 3.4)
    #expect((falls.first?.restTiltDegrees ?? 0) > 80)
}

/// ⚠ One fall per episode: a cane lying on the ground being nudged must not re-alert.
@Test func onlyOneFallPerEpisode() {
    var detector = FallDetector()
    var samples = steady(from: 0, seconds: 0.3, g: 0.2, tilt: 20)
    samples.append((0.35, 3.0, 70))
    samples += steady(from: 0.4, seconds: 5.0, g: 1.0, tilt: 88)       // stays down a long time
    let reported = run(samples, detector: &detector)
    #expect(reported.count == 1)
}

/// …and it re-arms once the cane is picked up and upright again.
@Test func pickingTheCaneUpReArmsTheDetector() {
    var detector = FallDetector()
    var first = steady(from: 0, seconds: 0.3, g: 0.2, tilt: 20)
    first.append((0.35, 3.0, 70))
    first += steady(from: 0.4, seconds: 2.0, g: 1.0, tilt: 88)
    let reported = run(first, detector: &detector)
    #expect(reported.count == 1)

    var second = steady(from: 3.0, seconds: 0.5, g: 1.0, tilt: 5)      // upright again: re-arm
    second += steady(from: 3.6, seconds: 0.3, g: 0.2, tilt: 20)
    second.append((3.95, 3.0, 70))
    second += steady(from: 4.0, seconds: 2.0, g: 1.0, tilt: 88)
    let afterPickUp = run(second, detector: &detector)
    #expect(afterPickUp.count == 1)
}

/// A tap, a sweep or a knock is a spike with no free fall before it. Not a fall.
@Test func anImpactWithoutFreeFallIsNotAFall() {
    var detector = FallDetector()
    var samples = steady(from: 0, seconds: 1, g: 1.0, tilt: 5)
    samples.append((1.05, 4.0, 10))                                    // hard tap
    samples += steady(from: 1.1, seconds: 2.0, g: 1.0, tilt: 5)
    let falls = run(samples, detector: &detector)
    #expect(falls.isEmpty)
}

/// A drop the walker catches: free fall, impact, but the cane is upright and moving after.
@Test func aCaughtDropIsNotAFall() {
    var detector = FallDetector()
    var samples = steady(from: 0, seconds: 0.3, g: 0.2, tilt: 15)
    samples.append((0.35, 3.0, 40))
    samples += steady(from: 0.4, seconds: 2.0, g: 1.0, tilt: 10)       // upright again, not tilted
    let falls = run(samples, detector: &detector)
    #expect(falls.isEmpty)
}

/// Free fall too brief to be a real drop (one noisy sample) is ignored.
@Test func aSingleNoisySampleIsNotFreeFall() {
    var detector = FallDetector()
    var samples: [(TimeInterval, Double, Double)] = [(0, 1.0, 5), (0.02, 0.3, 5)]
    samples.append((0.04, 3.0, 70))                                    // impact 20 ms later
    samples += steady(from: 0.1, seconds: 2.0, g: 1.0, tilt: 88)
    let falls = run(samples, detector: &detector)
    #expect(falls.isEmpty)
}

/// Free fall that never lands (the cane was lifted, not dropped) expires instead of arming.
@Test func freeFallWithoutImpactExpires() {
    var detector = FallDetector()
    var samples = steady(from: 0, seconds: 0.3, g: 0.2, tilt: 20)
    samples += steady(from: 0.4, seconds: 2.0, g: 1.0, tilt: 10)       // back to normal, no spike
    let falls = run(samples, detector: &detector)
    #expect(falls.isEmpty)
}

/// The cane goes down but is picked straight back up: it never rests long enough.
@Test func aQuickPickUpIsNotAFall() {
    var detector = FallDetector()
    var samples = steady(from: 0, seconds: 0.3, g: 0.2, tilt: 20)
    samples.append((0.35, 3.0, 70))
    samples += steady(from: 0.4, seconds: 0.5, g: 1.0, tilt: 88)       // still, but only 0.5 s
    samples += steady(from: 1.0, seconds: 1.0, g: 1.4, tilt: 20)       // moving again, upright
    let falls = run(samples, detector: &detector)
    #expect(falls.isEmpty)
}

/// `reset()` abandons an episode in progress (route start / stop).
@Test func resetAbandonsTheEpisode() {
    var detector = FallDetector()
    _ = run(steady(from: 0, seconds: 0.3, g: 0.2, tilt: 20), detector: &detector)
    detector.reset()
    var after: [(TimeInterval, Double, Double)] = [(0.35, 3.0, 70)]
    after += steady(from: 0.4, seconds: 2.0, g: 1.0, tilt: 88)
    let falls = run(after, detector: &detector)
    #expect(falls.isEmpty)   // the impact has no free fall before it now
}

/// Garbage samples (NaN from a stalled sensor) are ignored rather than crashing or firing.
@Test func nonFiniteSamplesAreIgnored() {
    var detector = FallDetector()
    let nan = detector.update(magnitudeG: .nan, tiltDegrees: 5, now: 0)
    let inf = detector.update(magnitudeG: 1.0, tiltDegrees: .infinity, now: 0.1)
    #expect(nan == nil)
    #expect(inf == nil)
}
