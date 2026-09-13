//
//  QuietRouteSpeech.swift
//  CaneKitLogic
//
//  Step 68 — "talk about fifty percent less, but if something comes close, tell us." The rules that
//  decide which route status lines are spoken at all:
//    · `GPSAnnouncer` — "GPS weak." after 10 s of continuously bad GPS (a fix worse than 20 m or
//      older than 12 s, or none) while a route guides outdoors, again no sooner than 60 s; "GPS
//      back." after 10 s continuously good, only after "GPS weak.", at most once per 2 minutes
//      (review round Steps 67–68; Step 68 had 20 s and one pair per 2 minutes). The route engine's own state (`NavigationEngine.gpsWeak`,
//      the paused fences, the GuideCard pill) is unchanged; only the speech moved here.
//    · `RouteStatusLines` — at route start at most one status line, and only one that changes what
//      the walker does (haptics unavailable); the short screen-lock line; the prefetch list.
//    · `HeadphoneNotice` — a headphone disconnect during a route is said once, "AirPods disconnected.".
//  Evidence: phone log canekit-2026-09-13T15-48-34Z.jsonl (145 s route, 36 lines / 1,333 characters,
//  25 of them GPS weak / back flapping while the phone stood still indoors).
//
//  Pure, Foundation-only value types. Owners: `NavigationEngine.gpsAnnouncer` (fed from `update(fix:)`
//  and the 10 Hz `tick`, wall clock), `AppModel.announceChannels` / `scenePhaseChanged` /
//  `wireAudioRoute` (`AppModel.headphoneNotice`). ⚠ Every line is in `allSpokenLines`, which
//  `AppModel.commonLines` appends (natural-voice prefetch, matched by bytes).
//  Tests: `QuietRouteSpeechTests.swift`.
//

import Foundation

// MARK: - GPSAnnouncer

/// When the route engine says "GPS weak." / "GPS back.". Fed on every fix and every ticker beat with
/// `badOnset` — when GPS became bad for the announcer, or nil while it is good.
/// Step 68: a phone standing still indoors gets a fix every ~6 s and a stale fix (to the engine)
/// after 5 s, so the engine's "bad" flaps every few seconds; the old engine spoke every flap.
/// Review round Steps 67–68 (Antigravity #2, Muse #1 / #8): 20 s of silence with guidance paused
/// was too long, and the 2-minute pair limit could hide a real second outage. Now:
///   · bad = a fix worse than `maxAccuracyM` (20 m), a fix older than `maxFixAge` (12 s — longer
///     than the 6–11.4 s cadence of a walker standing still with good accuracy), or no fix at all
///     `noFixGrace` (10 s) after the route started. A stale fix's stretch is dated from when the
///     engine paused guidance (`NavigationHealth.maxFixAge`, 5 s), so "GPS weak." comes 10 s after
///     the pause. The engine's own pause (`NavigationHealth.maxFixAge`, Step 51a) is unchanged.
///   · "GPS weak." after `weakAfter` (10 s) of continuous bad, again no sooner than
///     `weakRepeatInterval` (60 s) after the previous one.
///   · "GPS back." after `backAfter` (10 s) of continuous good, only after "GPS weak.", at most once
///     per `backInterval` (120 s) — inside that limit the recovery stays pending (said when allowed,
///     if still good), and while it is pending no second "GPS weak." is said: the walker's last word
///     was "weak".
///   · The bad clock keeps running while indoors / suppressed, but nothing is spoken then.
/// Pinned by `theFlappingLogSaysNoGPSLines`, `gpsAnnouncerNumbersArePinned`,
/// `badOnsetFollowsAccuracyAgeAndNoFix`, `aStationaryWalkerWithGoodAccuracyIsSilent`,
/// `trueOutdoorLossByAccuracyIsSpokenWithinTenSeconds`, `aRealOutageIsOnePairTenSecondsAfterGuidancePaused`,
/// `repeatedDropoutsSayWeakAgainAfterSixtySeconds`, `aPendingBackIsNotFollowedByASecondWeak`,
/// `backIsNeverSaidWithoutWeak`, `neverWhileIndoorsButTheBadClockKeepsRunning`,
/// `noFixAtAllIsAnnouncedOnceAtTwentySeconds`.
public struct GPSAnnouncer: Sendable, Equatable {
    /// Spoken when GPS has been bad long enough to matter. ⚠ In `RouteStatusLines.allSpokenLines`.
    public static let weakLine = "GPS weak."
    /// Spoken when GPS has been good long enough after `weakLine`.
    public static let backLine = "GPS back."

    /// Metres: a fix with a worse horizontal accuracy (or a negative, invalid one) is bad. The fence
    /// gate (`NavigationEngine.veerMaxAccuracy`, `GeofenceTracker.maxAccuracy`).
    public static let maxAccuracyM: Double = 20
    /// Seconds: a fix older than this is bad for the announcer. [H] 12 s: the 15-48-34Z log's longest
    /// gap between fixes of a phone standing still was 11.4 s (accuracy 6.6–8.7 m).
    public static let maxFixAge: TimeInterval = 12
    /// Seconds after the route started before "no fix at all" counts as bad (10 + `weakAfter` = the
    /// engine's 20 s `noFixAfter`, cc04946).
    public static let noFixGrace: TimeInterval = 10

    /// Seconds GPS must be continuously bad (outdoors) before `weakLine`. [H] 10 s (was 20).
    public var weakAfter: TimeInterval = 10
    /// Seconds GPS must be continuously good before `backLine`.
    public var backAfter: TimeInterval = 10
    /// Seconds between two `weakLine`s. [H] 60 s.
    public var weakRepeatInterval: TimeInterval = 60
    /// Seconds between two `backLine`s. [H] 120 s.
    public var backInterval: TimeInterval = 120

    /// Start of the current continuous bad stretch (runs indoors too); nil while good.
    private var badSince: TimeInterval?
    /// Start of the current continuous good stretch; nil while bad.
    private var goodSince: TimeInterval?
    /// True after `weakLine` until `backLine`.
    private var weakSpoken = false
    /// When `weakLine` was last spoken; nil before the first.
    private var lastWeakAt: TimeInterval?
    /// When `backLine` was last spoken; nil before the first.
    private var lastBackAt: TimeInterval?

    /// A fresh announcer (the engine makes one per route).
    public init() {}

    /// When GPS became bad for the announcer, or nil while it is good.
    /// - Parameters:
    ///   - lastFixAt: the retained fix's timestamp (`NavigationEngine.lastFix`); nil = no fix.
    ///   - accuracy: that fix's horizontal accuracy, metres (negative = invalid); nil = no fix.
    ///   - routeStartedAt: when the route started, same clock.
    ///   - now: the caller's wall clock.
    /// - Returns: nil (good, or a non-finite clock); `now` for bad accuracy or a clock that runs
    ///   backwards; `lastFixAt + NavigationHealth.maxFixAge` for a fix older than `maxFixAge`;
    ///   `routeStartedAt + noFixGrace` for no fix once that moment has passed.
    public static func badOnset(lastFixAt: TimeInterval?, accuracy: Double?,
                                routeStartedAt: TimeInterval, now: TimeInterval) -> TimeInterval? {
        guard now.isFinite else { return nil }
        guard let fixAt = lastFixAt, let accuracy else {
            let onset = routeStartedAt + noFixGrace
            return now >= onset ? onset : nil
        }
        let age = now - fixAt
        if age < 0 { return now }
        if age > maxFixAge { return fixAt + NavigationHealth.maxFixAge }
        if accuracy < 0 || accuracy > maxAccuracyM { return now }
        return nil
    }

    /// Feed one observation.
    /// - Parameters:
    ///   - badOnset: `badOnset(...)` for this moment — nil while GPS is good.
    ///   - outdoors: a route is guiding outdoors — false while an indoor step script is active (bad
    ///     GPS is expected there) or while the more specific "Location access is off" line owns the
    ///     failure. The bad clock keeps running while false; nothing is spoken.
    ///   - now: seconds (wall clock in the app); non-finite → nothing.
    /// - Returns: `weakLine`, `backLine` or nil.
    public mutating func update(badOnset: TimeInterval?, outdoors: Bool, now: TimeInterval) -> String? {
        guard now.isFinite else { return nil }
        if let onset = badOnset {
            goodSince = nil
            let since = min(badSince ?? onset, onset)
            badSince = since
            guard outdoors, !weakSpoken, now - since >= weakAfter else { return nil }
            if let last = lastWeakAt, now - last < weakRepeatInterval { return nil }
            weakSpoken = true
            lastWeakAt = now
            return Self.weakLine
        }
        badSince = nil
        let since = goodSince ?? now
        goodSince = since
        guard weakSpoken, now - since >= backAfter else { return nil }
        if let last = lastBackAt, now - last < backInterval { return nil }
        weakSpoken = false
        lastBackAt = now
        return Self.backLine
    }
}

// MARK: - RouteStatusLines

/// Route status lines that survive Step 68. Namespace only.
public enum RouteStatusLines {
    /// Said at route start when the cane cannot buzz but the watch can.
    public static let hapticsOnWatchLine = "Haptics unavailable. Obstacle cues on the watch."
    /// Said at route start when neither the cane nor the watch can buzz.
    public static let hapticsSpokenLine = "Haptics unavailable. Obstacle cues will be spoken."
    /// Said once per route when the screen locks mid-route (ARKit pauses). Was "Screen locked.
    /// Obstacle warnings are paused until you unlock." (61 characters → 37).
    public static let screenLockedLine = "Screen locked. Obstacle warnings off."

    /// The one status line a route start may speak, or nil. Only a fact that changes what the walker
    /// does is spoken: with haptics down, obstacle cues arrive on the watch or as speech. No
    /// headphones ("No headphones. Beacon paused until AirPods connect.") and an unreachable watch
    /// ("Watch not reachable. Open OpenCane on the watch.") are no longer spoken — the Guide card and
    /// the "status" answer still say them. Caller: `AppModel.announceChannels`.
    /// - Parameters:
    ///   - headphonesConnected: `AudioRouteMonitor.headphonesConnected` (not spoken either way).
    ///   - watchPaired: `PhoneWatchLink.isPaired` (not spoken either way).
    ///   - watchReachable: `PhoneWatchLink.isReachable` (picks the haptics wording).
    ///   - hapticsHealthy: `HapticPlayer.isHealthy`.
    /// Pinned by `routeStartSaysOnlyTheHapticsLine`.
    public static func routeStartLine(headphonesConnected: Bool, watchPaired: Bool,
                                      watchReachable: Bool, hapticsHealthy: Bool) -> String? {
        guard !hapticsHealthy else { return nil }
        return watchReachable ? hapticsOnWatchLine : hapticsSpokenLine
    }

    /// Every Step 68 line, deduplicated, for the natural-voice prefetch (`AppModel.commonLines`).
    /// Pinned by `step68LinesAreShortAndPrefetched`.
    public static let allSpokenLines: [String] = [
        GPSAnnouncer.weakLine, GPSAnnouncer.backLine, screenLockedLine, hapticsOnWatchLine,
        hapticsSpokenLine, HeadphoneNotice.routeDisconnectLine, HeadphoneNotice.idleDisconnectLine,
        CueSpeechPolicy.closeText,
    ]
}

// MARK: - HeadphoneNotice

/// What a headphone disconnect says. During a route: "AirPods disconnected." once per route (a
/// pocketed case flapping the route must not repeat it). With no route: the old
/// "Headphones disconnected. Beacon paused." every time. Owner: `AppModel.headphoneNotice`
/// (`routeStarted()` in `startRouteNow`, `disconnected` in `wireAudioRoute`).
/// Pinned by `aMidRouteDisconnectIsSaidOnce`.
public struct HeadphoneNotice: Sendable, Equatable {
    /// The mid-route line.
    public static let routeDisconnectLine = "AirPods disconnected."
    /// The line with no route running (unchanged from before Step 68).
    public static let idleDisconnectLine = "Headphones disconnected. Beacon paused."
    /// True once `routeDisconnectLine` was said on this route.
    private var spokenThisRoute = false

    /// Armed for the first route.
    public init() {}

    /// A new route: the mid-route line may be said again.
    public mutating func routeStarted() { spokenThisRoute = false }

    /// A headphone disconnect happened.
    /// - Parameter navigating: a route is guiding (`NavigationEngine.isNavigating`).
    /// - Returns: the line to speak, or nil.
    public mutating func disconnected(navigating: Bool) -> String? {
        guard navigating else { return Self.idleDisconnectLine }
        guard !spokenThisRoute else { return nil }
        spokenThisRoute = true
        return Self.routeDisconnectLine
    }
}
