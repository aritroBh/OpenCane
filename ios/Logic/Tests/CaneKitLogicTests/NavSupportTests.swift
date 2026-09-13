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
//  Callers of the pinned code: `NavigationEngine` (app) builds a `TurnSettle` on every waypoint
//  advance; `AppModel` owns the `StraightWalkDetector` (auto-recenter) and `CueSpeechPolicy`
//  (obstacle cue → spoken line, `phoneCannotBuzz` = haptic engine down or silenced);
//  `WatchModel` owns the `CrownAccumulator`. Breaks these catch: a spurious "Veer" at a corner
//  (the old leg released too early by one jittery fix, a curb wait, or a pause short of a
//  crossing), a beacon that clicks during "Listen for traffic", a head-height warning repeated
//  every second under a branch, side cues spoken while the phone can still buzz, and a sleeve
//  brushing the crown skipping waypoints. ⚠ The nine settle tests and the three CueSpeechPolicy
//  tests are named in CODE_REFERENCE ⚠ lines; re-run them before touching those rules.
//

import Foundation
import Testing
@testable import CaneKitLogic

// Corner at the origin of a small local grid; 1e-5° latitude ≈ 1.11 m.
/// The turn waypoint every `TurnSettle` below is anchored on (40.11, −88.224).
private let corner = Coordinate(latitude: 40.11000, longitude: -88.22400)
/// A point `m` metres due south of `corner` (the approach side).
private func south(_ m: Double) -> Coordinate { Coordinate(latitude: 40.11000 - m / 111_195, longitude: -88.22400) }
/// A point `m` metres due north of `corner` (along the new leg, bearing 0°).
private func north(_ m: Double) -> Coordinate { Coordinate(latitude: 40.11000 + m / 111_195, longitude: -88.22400) }
/// A `GeoFix` at `c` and time `t` (s); defaults are a good walking fix (1.2 m/s, 5 m accuracy).
/// Speed 0 or −1 = standing / unknown, which the settle rules treat as not moving.
private func fix(_ c: Coordinate, t: Double, speed: Double = 1.2, acc: Double = 5) -> GeoFix {
    GeoFix(coordinate: c, accuracy: acc, speed: speed, timestamp: t)
}
/// A fresh `TurnSettle` at `corner` with a 12 m fence: `held` is the previous leg's bearing (270°,
/// nil = none), `next` the new leg's (0°), `start` the distance when the fence was entered (12 m),
/// `crossing` a street crossing (beacon silent until the curb), `released` a release time already
/// set (a manual Next or passed-by advance).
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

/// Under a low branch "Head height." is spoken at the onset and once more when the walker gets
/// under 0.6 m, never on the 1.0 m band re-fire and never a third time.
/// History: before Step 52 this fed bare `.head` re-fires at 1 Hz and ended the episode with
/// `cleared()`; the decider now owns the episode and the payload says onset or band re-fire.
@Test func headHeightIsSpokenOncePerEpisode() {
    var p = CueSpeechPolicy()
    let onset = p.line(for: .head(distance: 1.2, onset: true), phoneCannotBuzz: false, now: 0)
    #expect(onset?.text == "Head height.")
    #expect(onset?.tier == .safety)
    let band1 = p.line(for: .head(distance: 0.95, onset: false), phoneCannotBuzz: false, now: 1.5)
    #expect(band1 == nil)                                   // 1.0 m band: haptic only
    let band2 = p.line(for: .head(distance: 0.55, onset: false), phoneCannotBuzz: false, now: 3.0)
    #expect(band2?.text == "Head height.")                  // under 0.6 m: the second line
    let late = p.line(for: .head(distance: 0.3, onset: false), phoneCannotBuzz: false, now: 9)
    #expect(late == nil)                                    // never a third line in one episode
}

/// Stepping in and out under an overhang (two episodes) does not repeat "Head height." inside 4 s.
/// History: the second episode used to be opened with `cleared()`; it is now an onset payload.
@Test func headEpisodesAreRateLimitedAcrossEpisodes() {
    var p = CueSpeechPolicy()
    let r17 = p.line(for: .head(distance: 1.0, onset: true), phoneCannotBuzz: false, now: 0)
    #expect(r17 != nil)
    let r18 = p.line(for: .head(distance: 1.0, onset: true), phoneCannotBuzz: false, now: 2)
    #expect(r18 == nil)   // < 4 s since the last one
    let r19 = p.line(for: .head(distance: 1.0, onset: true), phoneCannotBuzz: false, now: 4.5)
    #expect(r19?.text == "Head height.")
}

/// The second line needs a band re-fire under 0.6 m: a 0.6 m or farther re-fire is silent, a
/// second under-0.6 m fire in the same episode is silent, and a new onset re-arms it.
@Test func secondHeadLineNeedsUnderSixtyCentimetres() {
    var p = CueSpeechPolicy()
    // (`line` is mutating, so each result is bound before `#expect`, as the other tests here do.)
    _ = p.line(for: .head(distance: 1.4, onset: true), phoneCannotBuzz: false, now: 0)
    let atSixty = p.line(for: .head(distance: 0.6, onset: false), phoneCannotBuzz: false, now: 2)
    #expect(atSixty == nil)
    let under = p.line(for: .head(distance: 0.59, onset: false), phoneCannotBuzz: false, now: 2.1)
    #expect(under?.text == "Head height.")
    let again = p.line(for: .head(distance: 0.4, onset: false), phoneCannotBuzz: false, now: 4)
    #expect(again == nil)
    // A new episode: onset (≥ 4 s after the last line) speaks and re-arms the second line.
    let onset2 = p.line(for: .head(distance: 1.2, onset: true), phoneCannotBuzz: false, now: 20)
    #expect(onset2 != nil)
    let second2 = p.line(for: .head(distance: 0.5, onset: false), phoneCannotBuzz: false, now: 22)
    #expect(second2 != nil)
    // The second line even speaks inside the 4 s onset limiter: under 0.6 m is one step away.
    let onset3 = p.line(for: .head(distance: 1.2, onset: true), phoneCannotBuzz: false, now: 40)
    #expect(onset3 != nil)
    let second3 = p.line(for: .head(distance: 0.5, onset: false), phoneCannotBuzz: false, now: 41.5)
    #expect(second3 != nil)
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
    #expect(r22?.text == "One meter ahead.")
    let r23 = p.line(for: .left, phoneCannotBuzz: true, now: 2)
    #expect(r23 == nil)   // per-kind limiter
}

// MARK: CueSpeechPolicy — "Close." (Step 68)

/// Feeds one centre-torso reading (trusted, covered, measured unless `held`).
private func close(_ p: inout CueSpeechPolicy, _ d: Float, at now: TimeInterval, held: Bool = false,
                   trusted: Bool = true, covered: Bool = true) -> String? {
    p.close(torsoCentreM: d, covered: covered, held: held, trusted: trusted, now: now)
}

/// Walking up to a wall: the tile turns red at < 0.7 m → "Close." once; staying red, getting closer,
/// or the point-blank hold that follows says nothing more.
@Test func closeIsSpokenOncePerRedEpisode() {
    var p = CueSpeechPolicy()
    #expect(close(&p, 1.5, at: 0) == nil)                  // orange / yellow: silent
    #expect(close(&p, 0.7, at: 0.5) == nil)                // 0.7 m is still orange (`TileLevel.near`)
    #expect(close(&p, 0.69, at: 1) == "Close.")
    #expect(close(&p, 0.5, at: 2) == nil)
    #expect(close(&p, 0.1, at: 3, held: true) == nil)      // point-blank hold continues the episode
    #expect(close(&p, 0.3, at: 30) == nil)                 // still the same episode
    #expect(CueSpeechPolicy.closeText == "Close.")
}

/// The episode ends only after 3 s out of the red: a reading flapping at the boundary is one line.
@Test func closeNeedsThreeSecondsOutOfTheRed() {
    var p = CueSpeechPolicy()
    #expect(close(&p, 0.6, at: 0) == "Close.")
    #expect(close(&p, 0.75, at: 5) == nil)
    #expect(close(&p, 0.65, at: 7.9) == nil)               // 2.9 s out: same episode
    #expect(close(&p, 0.8, at: 8) == nil)
    #expect(close(&p, 1.2, at: 11) == nil)                 // 3 s out: episode over
    #expect(close(&p, 0.6, at: 11.5) == "Close.")          // a new red episode speaks
}

/// Never two lines within 4 s: a new episode inside the limiter waits, then speaks if still red.
@Test func closeIsRateLimitedToOneEveryFourSeconds() {
    var p = CueSpeechPolicy()
    p.closeClearSeconds = 0.5                               // isolate the 4 s limiter
    #expect(close(&p, 0.6, at: 0) == "Close.")
    #expect(close(&p, 1.0, at: 0.5) == nil)
    #expect(close(&p, 1.0, at: 1.0) == nil)                // episode over after 0.5 s
    #expect(close(&p, 0.6, at: 2.0) == nil)                // new red, 2 s after the line: waits
    #expect(close(&p, 0.6, at: 3.9) == nil)
    #expect(close(&p, 0.6, at: 4.0) == "Close.")           // limiter expired, still red
}

/// `NearHold` can never start an episode: the phone switched on against a wall (point-blank) or a
/// cold-start caution (0.8 m, not red anyway) is silent however long it lasts.
@Test func aPointBlankHoldNeverStartsClose() {
    var p = CueSpeechPolicy()
    for i in 0..<100 {
        #expect(close(&p, 0.1, at: Double(i) * 0.1, held: true) == nil)
    }
    #expect(close(&p, 0.8, at: 20, held: true) == nil)
    #expect(close(&p, 0.4, at: 21) == "Close.")            // the first measured red still speaks
}

/// A sweep (untrusted) frame and an uncovered cell neither start nor end an episode.
@Test func sweepAndUncoveredFramesNeitherStartNorEndClose() {
    var p = CueSpeechPolicy()
    #expect(close(&p, 0.3, at: 0, trusted: false) == nil)
    #expect(close(&p, 0.3, at: 0.1, covered: false) == nil)
    #expect(close(&p, 0.6, at: 1) == "Close.")
    #expect(close(&p, 2.0, at: 2, trusted: false) == nil)  // does not count as out of the red
    #expect(close(&p, 2.0, at: 5, covered: false) == nil)
    #expect(close(&p, 0.6, at: 6) == nil)                  // same episode
    #expect(close(&p, 0.6, at: .nan) == nil)
}

/// Review round Steps 67–68. Antigravity #3: "Close." (< 0.7 m) is an imminent-collision warning;
/// at `.obstacle` it queued behind the 8–10 s route intro and its 3 s TTL dropped it, so it is a
/// `.safety` line now (it cuts `.nav`; "Head height." and "Close." never cut each other — equal
/// priority queues in order of arrival). Muse #2: Quiet renders no torso haptic, so "Close." is
/// the only near-obstacle signal there — it is allowed at every cue level while a route or an
/// indoor script guides, and never otherwise.
@Test func closeIsASafetyLineAtEveryCueLevel() {
    #expect(CueSpeechPolicy.closeTier == .safety)
    for level in CueLevel.allCases {
        #expect(CueSpeechPolicy.closeAllowed(navigating: true, indoorActive: false, level: level), "\(level)")
        #expect(CueSpeechPolicy.closeAllowed(navigating: false, indoorActive: true, level: level), "\(level)")
        #expect(!CueSpeechPolicy.closeAllowed(navigating: false, indoorActive: false, level: level), "\(level)")
    }
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

/// A silent (buzzed) side cue between the head onset and a 1.0 m band re-fire does not re-speak
/// "Head height." History: the Step 10 bug was an `episodeKind` the side cue overwrote; the
/// episode now lives in the decider, and this pins that a side cue still cannot open one here.
@Test func aBuzzedSideCueDoesNotSplitAHeadEpisode() {
    var p = CueSpeechPolicy()
    let first = p.line(for: .head(distance: 1.2, onset: true), phoneCannotBuzz: false, now: 0)
    #expect(first != nil)
    let side = p.line(for: .left, phoneCannotBuzz: false, now: 5)     // buzzed, not spoken
    #expect(side == nil)
    let again = p.line(for: .head(distance: 0.9, onset: false), phoneCannotBuzz: false, now: 6)
    #expect(again == nil)                                            // band re-fire: silent
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
