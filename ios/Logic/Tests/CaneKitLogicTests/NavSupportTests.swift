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

@Test func settleDoesNotReleaseOnOneJitteryFix() {
    var s = settle()
    _ = s.update(fix(south(12), t: 0))
    _ = s.update(fix(south(19), t: 1))                 // one 7 m jump: not enough
    _ = s.update(fix(south(11), t: 2))
    #expect(s.releaseAt == nil)
    #expect(s.bearing(live: 0, at: 10) == 270)
}

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

@Test func stationaryOrPoorFixesNeverReleaseByDistance() {
    var s = settle()
    _ = s.update(fix(south(12), t: 0))
    _ = s.update(fix(south(3), t: 1, speed: 0))         // wander near the corner while standing
    _ = s.update(fix(south(3), t: 2, speed: -1))
    _ = s.update(fix(south(3), t: 3, acc: 40))          // poor accuracy
    #expect(s.releaseAt == nil)
}

@Test func settleCapCountsMovingTimeOnly() {
    var s = settle()
    var t = 0.0
    for _ in 0..<60 { _ = s.update(fix(south(12), t: t, speed: 0)); t += 1 }   // a minute at the curb
    #expect(!s.isLive(at: t))
    for _ in 0..<26 { _ = s.update(fix(south(12), t: t)); t += 1 }            // 25 s of walking
    #expect(s.isLive(at: t))
}

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

@Test func turningTheBodyReleasesImmediately() {
    var s = settle(held: 270, next: 0)
    s.update(heading: 300, now: 1)                      // not yet
    #expect(s.releaseAt == nil)
    s.update(heading: 350, now: 2)                      // within 30° of north
    #expect(s.releaseAt == 2)
}

@Test func manualOrPassedByAdvanceIsLiveAtOnce() {
    let s = settle(released: 5)
    #expect(s.isLive(at: 5))
    #expect(s.bearing(live: 10, at: 5) == 10)
}

@Test func noHeldBearingFallsBackToLive() {
    let s = settle(held: nil)
    #expect(s.bearing(live: 42, at: 0) == 42)
}

// MARK: StraightWalkDetector

@Test func straightWalkNeedsThreeSteadyFixesCountingTheFirst() {
    var d = StraightWalkDetector()
    let r4 = d.update(speed: 1.2, accuracy: 5, heading: 0, headYaw: 0)
    #expect(!r4)
    let r5 = d.update(speed: 1.2, accuracy: 5, heading: 2, headYaw: 1)
    #expect(!r5)
    let r6 = d.update(speed: 1.2, accuracy: 5, heading: -3, headYaw: -2)
    #expect(r6)
}

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

@Test func headEpisodesAreRateLimitedAcrossEpisodes() {
    var p = CueSpeechPolicy()
    let r17 = p.line(for: .head, phoneCannotBuzz: false, now: 0)
    #expect(r17 != nil)
    p.cleared()
    let r18 = p.line(for: .head, phoneCannotBuzz: false, now: 2)
    #expect(r18 == nil)   // < 4 s since the last one
}

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

@Test func crownFiresOnThreeDetentsWithinASecond() {
    var c = CrownAccumulator()
    let r24 = c.move(delta: 1, now: 0)
    #expect(!r24)
    let r25 = c.move(delta: -1, now: 0.3)
    #expect(!r25)   // either direction
    let r26 = c.move(delta: 1, now: 0.6)
    #expect(r26)
}

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

@Test func aBuzzedSideCueDoesNotSplitAHeadEpisode() {
    var p = CueSpeechPolicy()
    let first = p.line(for: .head, phoneCannotBuzz: false, now: 0)
    #expect(first != nil)
    let side = p.line(for: .left, phoneCannotBuzz: false, now: 5)     // buzzed, not spoken
    #expect(side == nil)
    let again = p.line(for: .head, phoneCannotBuzz: false, now: 6)    // same episode: silent
    #expect(again == nil)
}

@Test func aPauseShortOfTheCurbDoesNotReleaseACrossing() {
    var s = settle(crossing: true)
    _ = s.update(fix(south(12), t: 0))
    _ = s.update(fix(south(11), t: 1, speed: 0))                    // tying a shoe 11 m short
    _ = s.update(fix(south(11), t: 2, speed: -1))
    #expect(s.releaseAt == nil)
    #expect(s.bearing(live: 270, at: 2) == nil)                     // still silent
}
