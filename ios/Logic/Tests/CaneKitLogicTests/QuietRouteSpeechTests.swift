//
//  QuietRouteSpeechTests.swift
//  CaneKitLogicTests
//
//  Step 68 ("talk about 50 % less, but tell us when something is close"). Pins `GPSAnnouncer`
//  (GPS weak / back hysteresis; retuned in the Steps 67–68 review round: 10 s, a 12 s fix age,
//  weak again after 60 s, back at most once per 120 s, the indoor clock kept), `RouteStatusLines` (one status line at route start at most, the
//  short screen-lock line) and `HeadphoneNotice` (a mid-route disconnect said once).
//  Evidence: phone log canekit-2026-09-13T15-48-34Z.jsonl — a 145 s indoor route with the phone
//  standing still, where CoreLocation delivered a fix every ~6 s, the retained fix went stale after
//  5 s (`NavigationHealth.maxFixAge`) and the old engine said "GPS weak. Waypoint cues paused until
//  it recovers." ×12 and "GPS back." ×13, alternating every 3–9 s.
//

import Foundation
import Testing
@testable import CaneKitLogic

// MARK: GPSAnnouncer

/// The route-relative fix times (seconds) of that log's route (start t = 249.616, end 393.517):
/// accuracy 6.6–8.7 m throughout, so "bad" only ever meant "no fresh fix for 5 s" to the engine.
private let flapLogFixTimes: [TimeInterval] = [
    0.0, 0.0, 0.0, 0.0, 6.0, 12.0, 18.1, 23.4, 24.1, 29.7, 30.1, 31.6, 31.6, 31.6, 31.6, 35.0, 35.0,
    35.0, 35.0, 37.0, 37.0, 37.0, 37.0, 43.0, 54.4, 58.0, 66.4, 73.0, 84.4, 88.0, 96.4, 96.7, 96.7,
    96.7, 102.7, 113.9, 117.7, 125.9, 129.7, 132.7, 143.9,
]

/// Replays fixes (time, accuracy) through `GPSAnnouncer.badOnset` at the 10 Hz ticker, like
/// `NavigationEngine.announceGPS` does from `tick`; returns every line with its time.
/// - Parameters:
///   - fixes: (fix timestamp, horizontal accuracy m), in time order.
///   - end: last ticker beat (s).
///   - outdoors: a closure of the ticker time, true while a route guides outdoors.
private func replay(fixes: [(TimeInterval, Double)], until end: TimeInterval,
                    outdoors: (TimeInterval) -> Bool = { _ in true }) -> [(TimeInterval, String)] {
    var announcer = GPSAnnouncer()
    var said: [(TimeInterval, String)] = []
    var now: TimeInterval = 0
    while now <= end {
        let last = fixes.last(where: { $0.0 <= now })
        let onset = GPSAnnouncer.badOnset(lastFixAt: last?.0, accuracy: last?.1, routeStartedAt: 0, now: now)
        if let line = announcer.update(badOnset: onset, outdoors: outdoors(now), now: now) { said.append((now, line)) }
        now = (now * 10 + 1).rounded() / 10
    }
    return said
}

/// The owner's log: 25 GPS lines in 145 s before Step 68; none now. Its longest gap between fixes
/// was 11.4 s with 6.6–8.7 m accuracy, which the announcer's 12 s fix age does not call bad.
@Test func theFlappingLogSaysNoGPSLines() {
    let said = replay(fixes: flapLogFixTimes.map { ($0, 7.5) }, until: 145)
    #expect(said.isEmpty, "\(said)")
}

/// The numbers (review round Steps 67–68, Antigravity #2): weak after 10 s, back after 10 s, weak
/// again no sooner than 60 s, back no more than once per 120 s, a fix older than 12 s or worse than
/// 20 m is bad, and a route with no fix at all is bad from 10 s after its start.
@Test func gpsAnnouncerNumbersArePinned() {
    let a = GPSAnnouncer()
    #expect(a.weakAfter == 10)
    #expect(a.backAfter == 10)
    #expect(a.weakRepeatInterval == 60)
    #expect(a.backInterval == 120)
    #expect(GPSAnnouncer.maxFixAge == 12)
    #expect(GPSAnnouncer.maxAccuracyM == 20)
    #expect(GPSAnnouncer.noFixGrace == 10)
}

/// When GPS became bad for the announcer: a fix worse than 20 m (or with invalid, negative
/// accuracy) is bad now; a fix older than 12 s is bad since it went stale for the engine (5 s, when
/// guidance paused); a fresh good fix, or a 6–12 s old one, is good; no fix at all is bad from 10 s
/// after the route started.
@Test func badOnsetFollowsAccuracyAgeAndNoFix() {
    #expect(GPSAnnouncer.badOnset(lastFixAt: 100, accuracy: 8, routeStartedAt: 0, now: 101) == nil)
    #expect(GPSAnnouncer.badOnset(lastFixAt: 100, accuracy: 8, routeStartedAt: 0, now: 112) == nil)   // 12 s old: still good
    #expect(GPSAnnouncer.badOnset(lastFixAt: 100, accuracy: 8, routeStartedAt: 0, now: 112.1) == 105)
    #expect(GPSAnnouncer.badOnset(lastFixAt: 100, accuracy: 20, routeStartedAt: 0, now: 101) == nil)
    #expect(GPSAnnouncer.badOnset(lastFixAt: 100, accuracy: 20.5, routeStartedAt: 0, now: 101) == 101)
    #expect(GPSAnnouncer.badOnset(lastFixAt: 100, accuracy: -1, routeStartedAt: 0, now: 101) == 101)
    #expect(GPSAnnouncer.badOnset(lastFixAt: 100, accuracy: 8, routeStartedAt: 0, now: 99) == 99)      // clock backwards
    #expect(GPSAnnouncer.badOnset(lastFixAt: nil, accuracy: nil, routeStartedAt: 50, now: 59.9) == nil)
    #expect(GPSAnnouncer.badOnset(lastFixAt: nil, accuracy: nil, routeStartedAt: 50, now: 60) == 60)
    #expect(GPSAnnouncer.badOnset(lastFixAt: 100, accuracy: 8, routeStartedAt: 0, now: .nan) == nil)
}

/// A walker standing still outdoors with good accuracy gets a fix every ~6 s (and gaps up to
/// 11.4 s): never "GPS weak." for the announcer, however long they stand.
@Test func aStationaryWalkerWithGoodAccuracyIsSilent() {
    var fixes: [(TimeInterval, Double)] = []
    var t: TimeInterval = 0
    var i = 0
    while t < 600 {
        fixes.append((t, 6.5))
        t += (i % 5 == 4) ? 11.4 : 6.0
        i += 1
    }
    #expect(replay(fixes: fixes, until: 600).isEmpty)
}

/// True outdoor loss, accuracy: fixes keep coming but at 45 m from t = 30 → "GPS weak." 10 s later
/// (t = 40), within 10 s of the first bad fix; "GPS back." 10 s after good fixes return.
@Test func trueOutdoorLossByAccuracyIsSpokenWithinTenSeconds() {
    let fixes = stride(from: 0.0, through: 120, by: 1).map { t -> (TimeInterval, Double) in (t, (30..<80).contains(t) ? 45 : 5) }
    let said = replay(fixes: fixes, until: 120)
    #expect(said.map(\.1) == ["GPS weak.", "GPS back."], "\(said)")
    #expect(said.first?.0 == 40)
    #expect(said.last?.0 == 90)
}

/// True outdoor loss, silence: fixes stop after t = 30. The engine pauses guidance at 35 (5 s
/// stale); the announcer calls it bad once the fix is 12 s old and dates the stretch from 35, so
/// "GPS weak." is said at 45 — 10 s after guidance paused (was 55 before this round). Back 10 s
/// after fixes return at 90.
@Test func aRealOutageIsOnePairTenSecondsAfterGuidancePaused() {
    let fixes = (Array(stride(from: 0.0, through: 30, by: 1)) + Array(stride(from: 90.0, through: 200, by: 1))).map { ($0, 5.0) }
    let said = replay(fixes: fixes, until: 200)
    #expect(said.map(\.1) == ["GPS weak.", "GPS back."], "\(said)")
    #expect(said.first?.0 == 45)
    #expect(said.last?.0 == 100)
}

/// Repeated dropouts (urban canyon): the second "GPS weak." is not held for 2 minutes any more —
/// it is said once 60 s have passed since the first, while GPS is still bad. "GPS back." is the one
/// with the 120 s limit: inside it the recovery stays unsaid but pending, and is said once the limit
/// allows (the walker, who last heard "weak", is never told "back" early or twice).
@Test func repeatedDropoutsSayWeakAgainAfterSixtySeconds() {
    var a = GPSAnnouncer()
    var said: [(TimeInterval, String)] = []
    var now: TimeInterval = 0
    while now <= 200 {
        // bad 0–15, good 15–30, bad 30–100, good from 100
        let bad = now < 15 || (now >= 30 && now < 100)
        if let line = a.update(badOnset: bad ? now : nil, outdoors: true, now: now) { said.append((now, line)) }
        now = (now * 10 + 1).rounded() / 10
    }
    #expect(said.map(\.0) == [10, 25, 70, 145], "\(said)")
    #expect(said.map(\.1) == ["GPS weak.", "GPS back.", "GPS weak.", "GPS back."])
}

/// While "GPS back." waits for its 120 s limit, a new bad stretch says nothing: the walker has not
/// heard "back" since the last "weak", so they still believe GPS is weak.
@Test func aPendingBackIsNotFollowedByASecondWeak() {
    var a = GPSAnnouncer()
    let w1 = a.update(badOnset: 0, outdoors: true, now: 10)
    #expect(w1 == "GPS weak.")
    _ = a.update(badOnset: nil, outdoors: true, now: 11)
    let b1 = a.update(badOnset: nil, outdoors: true, now: 21)
    #expect(b1 == "GPS back.")
    _ = a.update(badOnset: 80, outdoors: true, now: 80)
    let w2 = a.update(badOnset: 80, outdoors: true, now: 90)
    #expect(w2 == "GPS weak.")                                // 80 s after the first weak
    _ = a.update(badOnset: nil, outdoors: true, now: 91)
    let pendingBack = a.update(badOnset: nil, outdoors: true, now: 101)
    #expect(pendingBack == nil)                               // 80 s after the first back: held
    _ = a.update(badOnset: 102, outdoors: true, now: 102)
    let noSecondWeak = a.update(badOnset: 102, outdoors: true, now: 170)
    #expect(noSecondWeak == nil)                              // walker still believes "weak"
    _ = a.update(badOnset: nil, outdoors: true, now: 171)
    let b2 = a.update(badOnset: nil, outdoors: true, now: 181)
    #expect(b2 == "GPS back.")                                // 160 s after the first back
}

/// A bad stretch shorter than 10 s is never announced, and so never followed by "GPS back.".
@Test func backIsNeverSaidWithoutWeak() {
    var a = GPSAnnouncer()
    let s0 = a.update(badOnset: 0, outdoors: true, now: 0)
    let s1 = a.update(badOnset: 0, outdoors: true, now: 9.9)
    let s2 = a.update(badOnset: nil, outdoors: true, now: 10)
    let s3 = a.update(badOnset: nil, outdoors: true, now: 40)
    #expect(s0 == nil && s1 == nil && s2 == nil && s3 == nil)
}

/// Never spoken while an indoor step script is active (GPS is expected to be bad indoors), but the
/// bad clock keeps running (Muse #8): a walker who leaves the building while GPS has been bad all
/// along hears "GPS weak." at once, not after another full wait.
@Test func neverWhileIndoorsButTheBadClockKeepsRunning() {
    #expect(replay(fixes: [], until: 300, outdoors: { _ in false }).isEmpty)
    var a = GPSAnnouncer()
    _ = a.update(badOnset: 0, outdoors: false, now: 0)
    let i1 = a.update(badOnset: 0, outdoors: false, now: 30)
    #expect(i1 == nil)
    let o1 = a.update(badOnset: 0, outdoors: true, now: 31)
    #expect(o1 == "GPS weak.")
    // A good fix indoors ends the stretch: stepping out later needs its own 10 s.
    var b = GPSAnnouncer()
    _ = b.update(badOnset: 0, outdoors: false, now: 0)
    _ = b.update(badOnset: nil, outdoors: false, now: 20)
    let o2 = b.update(badOnset: 21, outdoors: true, now: 21)
    #expect(o2 == nil)
    let o3 = b.update(badOnset: 21, outdoors: true, now: 31)
    #expect(o3 == "GPS weak.")
}

/// A route started with no fix at all hears "GPS weak." once, 20 s in (10 s grace + 10 s; the same
/// moment the engine's `noFixAfter` shows the pill), and nothing after a non-finite clock.
@Test func noFixAtAllIsAnnouncedOnceAtTwentySeconds() {
    let said = replay(fixes: [], until: 100)
    #expect(said.count == 1)
    #expect(said.first?.0 == 20)
    var a = GPSAnnouncer()
    let n = a.update(badOnset: 0, outdoors: true, now: .nan)
    #expect(n == nil)
}

// MARK: RouteStatusLines

/// At most one status line at route start, and only when it changes what the walker does: no
/// headphones and an unreachable watch are shown on the Guide card and answered by "status", not
/// spoken; unhealthy haptics are (obstacle cues moved to the watch or to speech).
@Test func routeStartSaysOnlyTheHapticsLine() {
    #expect(RouteStatusLines.routeStartLine(headphonesConnected: false, watchPaired: true,
                                            watchReachable: false, hapticsHealthy: true) == nil)
    #expect(RouteStatusLines.routeStartLine(headphonesConnected: true, watchPaired: false,
                                            watchReachable: false, hapticsHealthy: true) == nil)
    #expect(RouteStatusLines.routeStartLine(headphonesConnected: false, watchPaired: true,
                                            watchReachable: false, hapticsHealthy: false)
            == "Haptics unavailable. Obstacle cues will be spoken.")
    #expect(RouteStatusLines.routeStartLine(headphonesConnected: false, watchPaired: true,
                                            watchReachable: true, hapticsHealthy: false)
            == "Haptics unavailable. Obstacle cues on the watch.")
}

/// The screen-lock line is short; every Step 68 line is in the prefetched set (AppModel.commonLines
/// appends `allSpokenLines`), matched by bytes.
@Test func step68LinesAreShortAndPrefetched() {
    #expect(RouteStatusLines.screenLockedLine == "Screen locked. Obstacle warnings off.")
    #expect(HeadphoneNotice.routeDisconnectLine == "AirPods disconnected.")
    let all = Set(RouteStatusLines.allSpokenLines)
    for line in [GPSAnnouncer.weakLine, GPSAnnouncer.backLine, RouteStatusLines.screenLockedLine,
                 RouteStatusLines.hapticsOnWatchLine, RouteStatusLines.hapticsSpokenLine,
                 HeadphoneNotice.routeDisconnectLine, HeadphoneNotice.idleDisconnectLine,
                 CueSpeechPolicy.closeText] {
        #expect(all.contains(line), "not prefetched: \(line)")
    }
    #expect(RouteStatusLines.allSpokenLines.count == all.count)
}

// MARK: HeadphoneNotice

/// A disconnect during a route is said once per route as "AirPods disconnected."; with no route the
/// old line stays; a new route re-arms it.
@Test func aMidRouteDisconnectIsSaidOnce() {
    var n = HeadphoneNotice()
    let idle = n.disconnected(navigating: false)
    #expect(idle == "Headphones disconnected. Beacon paused.")
    n.routeStarted()
    let d1 = n.disconnected(navigating: true)
    #expect(d1 == "AirPods disconnected.")
    let d2 = n.disconnected(navigating: true)
    #expect(d2 == nil)
    n.routeStarted()
    let d3 = n.disconnected(navigating: true)
    #expect(d3 == "AirPods disconnected.")
}
