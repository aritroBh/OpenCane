//
//  NavSupportTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins NavSupport.swift — `TurnSettle` (when a new leg may drive the beacon / veer
//  cues), `StraightWalkDetector` (AirPods auto-recenter), `CueSpeechPolicy` (which obstacle
//  cues are spoken) and `CrownAccumulator` (watch crown "Next"). Each case is a walk bug the
//  Step 10 review found or a spec'd behaviour of the corner / curb / crown.
//
//  Key invariants / fixtures:
//    · `corner` sits at 40.11, −88.224; `south(m)` / `north(m)` offset it by metres
//      (1° lat ≈ 111 195 m), so the user approaches from the south and the new leg is north.
//    · `settle(...)` = radius 12 m, held bearing 270°, next bearing 0°, start 12 m away.
//    · `fix(_:t:speed:acc:)` defaults to a good walking fix: 1.2 m/s, 5 m accuracy.
//    · Results of `mutating` calls are bound to locals (`r1`, `first`, …) and then checked
//      with `#expect`, rather than calling the mutating method inside the macro.
//

import Foundation
import Testing
@testable import CaneKitLogic

// Corner at the origin of a small local grid; 1e-5° latitude ≈ 1.11 m.
private let corner = Coordinate(latitude: 40.11000, longitude: -88.22400)
private func south(_ m: Double) -> Coordinate { Coordinate(latitude: 40.11000 - m / 111_195, longitude: -88.22400) }
private func north(_ m: Double) -> Coordinate { Coordinate(latitude: 40.11000 + m / 111_195, longitude: -88.22400) }
private func fix(_ c: Coordinate, t: Double, speed: Double = 1.2, acc: Double = 5) -> GeoFix {
    GeoFix(coordinate: c, accuracy: acc, speed: speed, timestamp: t)
}
private func settle(crossing: Bool = false, held: Double? = 270, next: Double? = 0, start: Double = 12,
                    released: Double? = nil) -> TurnSettle {
    TurnSettle(anchor: corner, radiusM: 12, heldBearing: held, nextBearing: next,
               isCrossing: crossing, startDistance: start, releasedAt: released)
}

// MARK: TurnSettle

/// Entering a turn fence early keeps the old leg's bearing until 6 m from the corner plus 4 s.
@Test func settleHoldsThePreviousLegUntilNearTheCornerPlusGrace() {
    var s = settle()
    let r1 = s.update(fix(south(12), t: 0))
    #expect(!r1)
    let r2 = s.update(fix(south(9), t: 1))
    #expect(!r2)
    let r3 = s.update(fix(south(5), t: 2))
    #expect(!r3)   // near → release at 2 + 4
    #expect(s.bearing(live: 0, at: 5.9) == 270)        // still holding
    #expect(s.bearing(live: 0, at: 6) == 0)            // live
    #expect(s.isLive(at: 6))
}

/// One GPS jump away from the corner does not release the turn early (spurious "Veer").
@Test func settleDoesNotReleaseOnOneJitteryFix() {
    var s = settle()
    _ = s.update(fix(south(12), t: 0))
    _ = s.update(fix(south(19), t: 1))                 // one 7 m jump: not enough
    _ = s.update(fix(south(11), t: 2))
    #expect(s.releaseAt == nil)
    #expect(s.bearing(live: 0, at: 10) == 270)
}

/// GPS offset never gets within 6 m, but two receding fixes show the user rounded the corner.
@Test func settleReleasesAfterTwoConsecutiveRecedingFixes() {
    var s = settle()
    // GPS offset keeps the fix > 6 m from the corner: closest approach 8 m, then receding.
    _ = s.update(fix(south(12), t: 0))
    _ = s.update(fix(south(8), t: 3))
    _ = s.update(fix(north(15), t: 10))                 // 15 ≥ 8 + 6: first receding hit
    #expect(s.releaseAt == nil)
    _ = s.update(fix(north(16), t: 11))                 // second consecutive hit
    #expect(s.releaseAt == 15)                          // 11 + 4 s grace
}

/// A fix drifting near the corner while the user stands or has poor GPS is not a turn.
@Test func stationaryOrPoorFixesNeverReleaseByDistance() {
    var s = settle()
    _ = s.update(fix(south(12), t: 0))
    _ = s.update(fix(south(3), t: 1, speed: 0))         // wander near the corner while standing
    _ = s.update(fix(south(3), t: 2, speed: -1))
    _ = s.update(fix(south(3), t: 3, acc: 40))          // poor accuracy
    #expect(s.releaseAt == nil)
}

/// A minute waiting at a curb does not burn the 25 s cap; 25 s of walking does release.
@Test func settleCapCountsMovingTimeOnly() {
    var s = settle()
    var t = 0.0
    for _ in 0..<60 { _ = s.update(fix(south(12), t: t, speed: 0)); t += 1 }   // a minute at the curb
    #expect(!s.isLive(at: t))
    for _ in 0..<26 { _ = s.update(fix(south(12), t: t)); t += 1 }            // 25 s of walking
    #expect(s.isLive(at: t))
}

/// At a street crossing the beacon is silent ("Listen for traffic") until two stationary fixes at the curb.
@Test func crossingSilencesTheBeaconAndReleasesAtTheCurb() {
    var s = settle(crossing: true)
    _ = s.update(fix(south(10), t: 0))
    #expect(s.bearing(live: 270, at: 0) == nil)         // "Listen for traffic": no clicks
    _ = s.update(fix(south(4), t: 1, speed: 0))
    #expect(s.releaseAt == nil)
    _ = s.update(fix(south(4), t: 2, speed: -1))        // second stationary fix → at the curb
    #expect(s.releaseAt == 2)
    #expect(s.bearing(live: 270, at: 2) == 270)
}

/// Turning the body (cane) to within 30° of the new leg releases the settle at once.
@Test func turningTheBodyReleasesImmediately() {
    var s = settle(held: 270, next: 0)
    s.update(heading: 300, now: 1)                      // not yet
    #expect(s.releaseAt == nil)
    s.update(heading: 350, now: 2)                      // within 30° of north
    #expect(s.releaseAt == 2)
}

/// After a manual Next or passed-by, the user is already past the corner: the new leg is live immediately.
@Test func manualOrPassedByAdvanceIsLiveAtOnce() {
    let s = settle(released: 5)
    #expect(s.isLive(at: 5))
    #expect(s.bearing(live: 10, at: 5) == 10)
}

/// With no previous leg bearing to hold, the beacon uses the live bearing while settling.
@Test func noHeldBearingFallsBackToLive() {
    let s = settle(held: nil)
    #expect(s.bearing(live: 42, at: 0) == 42)
}

// MARK: StraightWalkDetector

/// Three steady walking fixes with a still head trigger the AirPods auto-recenter.
@Test func straightWalkNeedsThreeSteadyFixesCountingTheFirst() {
    var d = StraightWalkDetector()
    let r4 = d.update(speed: 1.2, accuracy: 5, heading: 0, headYaw: 0)
    #expect(!r4)
    let r5 = d.update(speed: 1.2, accuracy: 5, heading: 2, headYaw: 1)
    #expect(!r5)
    let r6 = d.update(speed: 1.2, accuracy: 5, heading: -3, headYaw: -2)
    #expect(r6)
}

/// A course change, a curb stop, a head turn, no heading or bad GPS each restart the recenter count.
@Test func straightWalkRestartsOnATurnAStopOrAHeadTurn() {
    var d = StraightWalkDetector()
    _ = d.update(speed: 1.2, accuracy: 5, heading: 0, headYaw: 0)
    _ = d.update(speed: 1.2, accuracy: 5, heading: 2, headYaw: 0)
    let r7 = d.update(speed: 1.2, accuracy: 5, heading: 40, headYaw: 0)
    #expect(!r7)   // course jump: count = 1
    let r8 = d.update(speed: 0.3, accuracy: 5, heading: 40, headYaw: 0)
    #expect(!r8)   // stopped at a curb
    let r9 = d.update(speed: 1.2, accuracy: 5, heading: 40, headYaw: 0)
    #expect(!r9)
    let r10 = d.update(speed: 1.2, accuracy: 5, heading: 41, headYaw: 12)
    #expect(!r10)   // head turned
    let r11 = d.update(speed: 1.2, accuracy: 5, heading: nil, headYaw: 12)
    #expect(!r11)
    #expect(d.count == 0)
    let r12 = d.update(speed: 1.2, accuracy: 25, heading: 41, headYaw: 12)
    #expect(!r12)   // poor fix
}

// MARK: CueSpeechPolicy

/// Under a low branch "Head height." is spoken once while the haptic re-fires every second.
@Test func headHeightIsSpokenOncePerEpisode() {
    var p = CueSpeechPolicy()
    let r13 = p.line(for: .head, phoneCannotBuzz: false, now: 0)
    #expect(r13?.text == "Head height.")
    let r14 = p.line(for: .head, phoneCannotBuzz: false, now: 1)
    #expect(r14 == nil)   // same episode, 1 Hz re-fire
    let r15 = p.line(for: .head, phoneCannotBuzz: false, now: 9)
    #expect(r15 == nil)   // still the same episode
    p.cleared()
    let r16 = p.line(for: .head, phoneCannotBuzz: false, now: 9.5)
    #expect(r16?.tier == .safety)   // new episode
}

/// Stepping in and out under an overhang does not repeat "Head height." inside 4 s.
@Test func headEpisodesAreRateLimitedAcrossEpisodes() {
    var p = CueSpeechPolicy()
    let r17 = p.line(for: .head, phoneCannotBuzz: false, now: 0)
    #expect(r17 != nil)
    p.cleared()
    let r18 = p.line(for: .head, phoneCannotBuzz: false, now: 2)
    #expect(r18 == nil)   // < 4 s since the last one
}

/// Left / right / ahead are spoken only when haptics are down or silenced, each at most every 4 s.
@Test func sideCuesAreSpokenOnlyWhenThePhoneCannotBuzz() {
    var p = CueSpeechPolicy()
    let r19 = p.line(for: .left, phoneCannotBuzz: false, now: 0)
    #expect(r19 == nil)
    let r20 = p.line(for: .left, phoneCannotBuzz: true, now: 0)
    #expect(r20?.text == "Left.")
    let r21 = p.line(for: .right, phoneCannotBuzz: true, now: 0.5)
    #expect(r21?.tier == .obstacle)
    let r22 = p.line(for: .centerApproach(distance: 1.0), phoneCannotBuzz: true, now: 1)
    #expect(r22?.text == "Ahead, one meter.")
    let r23 = p.line(for: .left, phoneCannotBuzz: true, now: 2)
    #expect(r23 == nil)   // per-kind limiter
}

// MARK: CrownAccumulator

/// A deliberate three-detent crown turn (either direction) within 1 s means Next.
@Test func crownFiresOnThreeDetentsWithinASecond() {
    var c = CrownAccumulator()
    let r24 = c.move(delta: 1, now: 0)
    #expect(!r24)
    let r25 = c.move(delta: -1, now: 0.3)
    #expect(!r25)   // either direction
    let r26 = c.move(delta: 1, now: 0.6)
    #expect(r26)
}

/// A sleeve brushing the crown once per arm swing never adds up to a Next.
@Test func crownIgnoresARhythmicSleeve() {
    var c = CrownAccumulator()
    let r27 = c.move(delta: 1, now: 0)
    #expect(!r27)
    let r28 = c.move(delta: 1, now: 0.9)
    #expect(!r28)
    let r29 = c.move(delta: 1, now: 1.8)
    #expect(!r29)   // window from t=0 expired
    let r30 = c.move(delta: 1, now: 2.7)
    #expect(!r30)
}

/// Two quick crown gestures inside 0.8 s skip only one waypoint.
@Test func crownDebouncesBackToBackGestures() {
    var c = CrownAccumulator()
    let r31 = c.move(delta: 3, now: 0.6)
    #expect(r31)
    let r32 = c.move(delta: 3, now: 0.9)
    #expect(!r32)   // inside 0.8 s
    let r33 = c.move(delta: 3, now: 1.5)
    #expect(r33)
}

// MARK: Step 10 round 3 (Muse review)

/// A silent (buzzed) side cue between head re-fires does not re-speak "Head height."
@Test func aBuzzedSideCueDoesNotSplitAHeadEpisode() {
    var p = CueSpeechPolicy()
    let first = p.line(for: .head, phoneCannotBuzz: false, now: 0)
    #expect(first != nil)
    let side = p.line(for: .left, phoneCannotBuzz: false, now: 5)     // buzzed, not spoken
    #expect(side == nil)
    let again = p.line(for: .head, phoneCannotBuzz: false, now: 6)    // same episode: silent
    #expect(again == nil)
}

/// Stopping 11 m short of a crossing (tying a shoe) keeps the beacon silent.
@Test func aPauseShortOfTheCurbDoesNotReleaseACrossing() {
    var s = settle(crossing: true)
    _ = s.update(fix(south(12), t: 0))
    _ = s.update(fix(south(11), t: 1, speed: 0))                    // tying a shoe 11 m short
    _ = s.update(fix(south(11), t: 2, speed: -1))
    #expect(s.releaseAt == nil)
    #expect(s.bearing(live: 270, at: 2) == nil)                     // still silent
}
