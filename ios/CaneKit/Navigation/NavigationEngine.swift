//
//  NavigationEngine.swift
//  CaneKit
//
//  Walks a `Route` waypoint by waypoint: geofence entry speaks the waypoint's line once, sends
//  the wrist cue (crossing / turn), advances, and re-aims the beacon. Off-bearing for 3 s →
//  "veer left/right". Pure decisions live in CaneKitLogic (GeofenceTracker, OffCourseDetector,
//  TurnSettle); this class owns state, timing and the outputs.
//
//  Veer cues are muted when any of these holds (each one produced a false "Veer" on the route):
//    · the turn at the last waypoint is still settling (TurnSettle: fence entered before the corner);
//    · the fix is still inside the fence of the corner just reached (the course smoother is kept
//      empty there: its first course would be a diagonal across the corner);
//    · the fix is inside the current waypoint's passed-by zone (live bearing swings / points back);
//    · the current leg is `curved` in the route file (chord bearing ≠ walking direction);
//    · the fix is poor (> 20 m), stale (> 5 s) or the user is not walking (≤ 0.5 m/s).
//  How a muted moment reaches the off-course episode depends on *why* it was muted:
//    · Settling, a curved leg, the zone beside the current waypoint, and a fix that positively
//      reports the walker standing are a different *situation*, not a hole: they call
//      `endEpisode()`, so a drift before a corner — or before a stop — is never added to the
//      drift after it.
//    · A missing fix / target bearing / smoothed course, or a poor or stale fix, or one whose
//      speed CoreLocation does not know, is a hole in the evidence and is reported as
//      `OffCourseDetector.gated(at:)` — one missed beat must not restart the 3 s hold (a walker
//      drifting off course under bad GPS would then never be warned), while a hole longer than
//      the detector's `maxEvidenceGap` (2 s) does drop the history, so GPS coming back after a
//      gap cannot fire a veer from what the walker was doing before it.
//  The two kinds interleave, so `update(heading:now:)` tests them in a fixed order (no fix →
//  route situation → fix quality → speed → position situation → target bearing); the ⚠ comment
//  there says why each guard sits where it does. Do not merge them back into one `guard`.
//
//  Owner: `AppModel.nav` (one instance). Module `navigation-trip` in docs/CODE_REFERENCE.md.
//  Inputs arrive from `AppModel.wireNavigation()` (fixes from LocationService, gyro-gated
//  headings); outputs are the `on…` callbacks, all installed by AppModel. The UI (GuideCard)
//  reads the published state; Next goes through `AppModel.nextWaypoint()` → `next()`; the 10 Hz
//  ticker (`AppModel.startTicker`) reads `targetBearing` and calls `tick(now:)`.
//  Since bf03253 GPS runs for the whole foreground session (not only during a route), so
//  `update(fix:)` is called while idle too — its `isNavigating` guard drops those fixes, which is
//  why `lastFix` only ever holds a fix seen *during* a route.
//
//  Threading / isolation: `@MainActor @Observable`. Every input and callback runs on the main
//  actor. Clocks: `GeoFix.timestamp` and the heading `now` are both wall clock
//  (`timeIntervalSinceReferenceDate`) — keep them on the same clock (TurnSettle compares them).
//
//  Key invariants (AGENTS.md "Things that look wrong but are deliberate"):
//    · Fences fire up to `radius_m` before the corner; TurnSettle holds the previous leg's
//      bearing and mutes veer until the turn is made. A fixed timer here caused spurious "Veer".
//    · At a crossing the beacon is silent while settling ("Listen for traffic").
//    · Passed-by never speaks the passed waypoint's own line; skip-ahead says "Passed one waypoint."
//    · Repeat speaks the last line actually spoken, via `onRepeat` (bypasses queue coalescing).
//    · Arrival is irreversible.
//    · A route started with no fix at all says "GPS weak." after 20 s instead of going silent
//      (cc04946: the demo run sheet starts the route indoors). A retained fix also stops driving
//      the route once `NavigationHealth.maxFixAge` elapses, even if the stream fails without
//      delivering a diagnostic.
//    · Step 68: the GPS lines are decided by `GPSAnnouncer` (CaneKitLogic), not by `gpsWeak`.
//      `gpsWeak` (the pill, the paused fences, the withdrawn target) flips exactly as before. Review
//      round Steps 67–68: the speech comes 10 s after GPS turned bad for the announcer (a fix worse
//      than 20 m or older than 12 s — a stale fix dated from the 5 s guidance pause), "GPS weak."
//      again after 60 s, "GPS back." after 10 s good and at most once per 2 min.
//      Before it, a phone standing still indoors (a fix every ~6 s, stale after 5 s) said
//      "GPS weak…" / "GPS back." 25 times in 145 s (log 2026-09-13T15-48-34Z).
//  Tests: ⚠ no unit test covers this class (app target). The decisions it delegates are pinned by
//  `GeoMathTests` (GeofenceTracker, OffCourseDetector incl. `aStopMidDriftRestartsTheHold`),
//  `NavSupportTests` (TurnSettle), `CourseSmootherTests`; the class itself only end to end, by
//  `make e2e` (clean / missed_fence / gps_jitter / wrong_turn replay its trip-log lines).
//  Do not change the ±30° turn delta, the veer gate or its mute conditions, or the settle
//  construction in `reached` without re-running those tests, `make e2e` and the step-10 device walk.
//

import CaneKitLogic
import Foundation
import Observation

/// Owner of route-following state and timing; delegates every numeric decision to CaneKitLogic.
@MainActor
@Observable
final class NavigationEngine {

    // MARK: Published

    /// The route being (or last) walked. Not cleared by `stop()`: `AppModel`'s `onArrived` handler
    /// reads its last waypoint's `say` for the spoken trip summary after `isNavigating` went false.
    private(set) var route: Route?
    /// True from `start` until arrival or `stop()`. Gates every input (`update(fix:)`,
    /// `update(heading:now:)`, `tick`, `next`). Read by AppModel (ticker, Live Activity, watch
    /// status, hands-free status, conversation context) and GuideCard.
    private(set) var isNavigating = false
    /// True once the last waypoint is reached (irreversible until the next `start`). GuideCard and
    /// ContentView show the arrival card / Repeat on it; `repeatInstruction()` still works.
    private(set) var arrived = false
    /// Text of the *next* waypoint's line ("Goodwin Avenue. Crossing.") for the UI, the watch
    /// status and the Live Activity. "No route" when idle or stopped, "Arrived: <say>" after
    /// arrival (`reached`), bare "Arrived" when the tracker has no current waypoint.
    private(set) var instruction = "No route"
    /// Metres to the next waypoint, rounded; nil when unknown (no fix yet this route, or after
    /// `stop()`); 0 after arrival. The watch status sends nil as -1.
    private(set) var distanceToNext: Int?
    /// Bearing to walk right now (degrees true), nil when unknown or deliberately silent (settling
    /// at a crossing, curved leg). While a turn is settling this is the *previous* leg's bearing.
    /// Read by AppModel's 10 Hz ticker → `BeaconEngine.setTarget(bearing:)`; nil = no clicks.
    private(set) var targetBearing: Double?
    /// Signed error target − heading in (−180, 180], nil when either is unknown.
    /// Positive = the target is to the user's right. Degrees.
    private(set) var bearingError: Double?
    /// Number of waypoints reached so far (= index of the current target waypoint). Logged as the
    /// `waypoint` record's `index` by AppModel.
    private(set) var waypointIndex = 0
    /// Wall-clock time `start` ran; `tick` measures `noFixAfter` from it.
    private(set) var startedAt: Date?
    /// True while "GPS weak" is in force: accuracy worse than `veerMaxAccuracy` for ≥ `gpsWeakAfter`
    /// seconds (`update(fix:)`), or no fix at all for `noFixAfter` seconds after `start` (`tick`).
    /// Cleared, with "GPS back.", by the next fix inside the accuracy gate. GuideCard shows a pill.
    private(set) var gpsWeak = false
    /// True between a waypoint being reached and the user having actually made the turn
    /// (`TurnSettle` not yet live). Veer is muted and `targetBearing` is the held (or nil) bearing.
    /// Read by `AppModel.autoRecenterIfWalkingStraight` (no recenter mid-turn).
    private(set) var isSettling = false
    /// The waypoint reached most recently (auto-recenter needs to know if it was a crossing; the
    /// course smoother is kept empty while a fix is inside its fence). Kept by `stop()`, cleared by
    /// `start`.
    private(set) var lastReached: Waypoint?
    /// True while the walker is settling at a street crossing: the waypoint just reached is a
    /// crossing and `TurnSettle` has not released (no curb stop yet, no turn, not live). The cue
    /// router (`AppModel.handle`) passes it to `TorsoHapticPolicy` so no torso tap interrupts
    /// "Listen for traffic" (cue design v2 §3.4, Step 41); the head cue is not affected. False
    /// after `stop()` (`isSettling` is cleared there) and for a passed-by / manual advance (an
    /// immediate settle is live at once, so `isSettling` never turns on).
    var isCrossingSettle: Bool { isSettling && (lastReached?.crossing ?? false) }

    // Outputs, all invoked synchronously on the main actor; all installed by
    // `AppModel.wireNavigation()`.
    /// Every waypoint / GPS / veer / arrival-hint line; priority is always `.nav`.
    /// GPS lines are only `GPSAnnouncer.weakLine` / `backLine` (Step 68).
    /// AppModel → `speech.say(ttl: 12)` + a `speech` trip-log record.
    @ObservationIgnored var onSpeak: ((String, SpeechPriority) -> Void)?
    /// True while an indoor step script is active (`AppModel` installs `indoor.isActive`): GPS is
    /// expected to be bad indoors, so `GPSAnnouncer` never says "GPS weak." then (Step 68; its bad clock
    /// keeps running, review round Steps 67–68). nil = outdoors.
    @ObservationIgnored var isIndoorActive: (() -> Bool)?
    /// "Say that again": must bypass the queue's coalescing (the line may still be playing).
    /// AppModel → `speech.sayAgain(_, .nav)` + a `speech` record with `repeat: true`.
    @ObservationIgnored var onRepeat: ((String) -> Void)?
    /// Wrist + cane cue: `.crossing`, `.turnLeft/.turnRight` (a turn at a waypoint *or* a veer),
    /// `.arrived`. AppModel sends it to the watch, buzzes the cane (`haptics.playNav`), stores it
    /// as the Live Activity glyph kind and logs `navcue`.
    @ObservationIgnored var onNavCue: ((NavCue) -> Void)?
    /// Fired after every advance (fence, passed-by or manual), after `instruction` is refreshed so
    /// the watch / Live Activity see the new leg. AppModel logs `waypoint`, pushes the watch status
    /// and marks a head recenter pending here.
    @ObservationIgnored var onWaypointAdvanced: (() -> Void)?
    /// Fired once when the last waypoint is reached, after `onWaypointAdvanced`. AppModel stops the
    /// beacon / head / ticker, ends the Live Activity and speaks the trip summary (GPS stays on).
    @ObservationIgnored var onArrived: (() -> Void)?

    // MARK: Tunables

    /// Veer cues need a fix at least this good (metres). Matches `GeofenceTracker.maxAccuracy`
    /// so "GPS weak" is announced exactly when the fences stop firing.
    /// Copied into the tracker in `start()`. ⚠ Do not change independently of
    /// `GeofenceTracker.maxAccuracy` (20 m) — the "GPS weak" line promises the fences are paused
    /// (AGENTS.md: "GPS weak" is spoken at the same 20 m).
    var veerMaxAccuracy: Double = 20
    /// Seconds of continuously bad accuracy (fix clock) before `gpsWeak` turns on (pill, fences).
    /// Long enough that one blurry fix under a tree never withdraws guidance. Since Step 68 the
    /// spoken line has its own clock (`GPSAnnouncer`: 10 s, review round Steps 67–68).
    var gpsWeakAfter: TimeInterval = 10
    /// Seconds after a route starts with NO fix at all before `gpsWeak` turns on. (Step 68: the
    /// walker is told by `GPSAnnouncer`, also after 20 s of no fix: `noFixGrace` 10 s + `weakAfter` 10 s.)
    ///
    /// Every other GPS-health line lives inside `update(fix:)`, which only runs when a fix arrives —
    /// so a route started indoors said "Route started…" and then went **permanently silent**: no
    /// waypoints, no veer, no beacon, and nothing to say why. The demo run sheet starts the route
    /// indoors, which reproduces it exactly. 20 s is long enough that a normal outdoor start never
    /// hears it (a first fix takes a few seconds) and short enough that nobody walks half a block
    /// believing they are being guided. (cc04946; measured from `startedAt` on the wall clock.)
    var noFixAfter: TimeInterval = 20

    // MARK: Private

    /// Geofence state machine for the current route (lookahead 2, passed-by, arrival streak,
    /// 20 m accuracy gate copied from `veerMaxAccuracy`). Built by `start`, dropped by `stop()`.
    @ObservationIgnored private var tracker: GeofenceTracker?
    /// "Veer" decider: 25° off for 3 s, 10 s cooldown, holes in the evidence up to
    /// `maxEvidenceGap` (2 s) bridged (CaneKitLogic defaults). Fed `update(error:now:)`,
    /// `gated(at:)` (a hole) or `endEpisode()` (a change of situation) by `update(heading:now:)`;
    /// `reset()` at start, every waypoint and every settle release.
    @ObservationIgnored private let offCourse = OffCourseDetector()
    /// Most recent fix seen *while navigating* (idle fixes are dropped by the guard in
    /// `update(fix:)`). Kept across `stop()`; `start()` keeps it only if < 30 s old. Used for
    /// distances, the veer gate, the clock-driven arrival hint (`tick`) and by
    /// `AppModel.recordHazard` (when < 120 s old) to geotag hazards.
    @ObservationIgnored private(set) var lastFix: GeoFix?
    /// Latest gyro-gated body heading, degrees true (compass when slow, GPS course when walking).
    /// Cleared by `start` so a previous route's heading cannot aim the new one (Muse).
    @ObservationIgnored private var heading: Double?
    /// Direction of travel over ≥ 15 m (CaneKitLogic.CourseSmoother). Veer decisions use this
    /// while walking, so a few metres of GPS jitter never becomes "Veer left/right"
    /// (e2e gps_jitter: 28 false veers with the per-fix course).
    @ObservationIgnored private var courseSmoother = CourseSmoother()
    /// The smoother's latest output, degrees true; nil until ≥ 15 m of good track on this leg,
    /// inside the fence of the corner just reached, and right after a veer cue. While walking
    /// (> 0.7 m/s) nil means no veer judgement at all (reported as a hole).
    @ObservationIgnored private var smoothedCourse: Double?
    /// Standing near the last waypoint without the two plausible arrival fixes (GPS under the
    /// entrance overhang): after 20 s say so once, so the walker is never left wondering.
    /// When the current standing-near-the-door stretch began (caller's clock); nil otherwise.
    @ObservationIgnored private var nearArrivalSince: TimeInterval?
    /// The arrival hint has been spoken on this route (once per route; reset by `start`).
    @ObservationIgnored private var arrivalHintGiven = false
    /// Fix timestamp at which accuracy first went bad; nil while accuracy is good.
    @ObservationIgnored private var weakSince: TimeInterval?
    /// Decides the spoken "GPS weak." / "GPS back." (Step 68, CaneKitLogic). Fresh per route; fed by
    /// `announceGPS(now:)` from `update(fix:)` and `tick`.
    @ObservationIgnored private var gpsAnnouncer = GPSAnnouncer()
    /// True after `markLocationUnavailable(speak: false)` (authorization revoked: AppModel speaks the
    /// Settings line instead) until the next good fix; keeps `GPSAnnouncer` from adding "GPS weak.".
    @ObservationIgnored private var gpsLineSuppressed = false
    /// Recorded bearing (`bearing_next_deg`) of the leg that led to the waypoint about to be
    /// reached — the leg's direction, not a measured one. `reached` compares it with the new leg
    /// for the turn wrist cue and holds it as the settle's bearing.
    @ObservationIgnored private var previousBearing: Double?
    /// Settling state for the most recently reached waypoint (see TurnSettle in CaneKitLogic).
    /// Value type: mutated as copy → update → write back. nil once live, and after arrival/stop.
    @ObservationIgnored private var settle: TurnSettle?
    /// What Repeat says: the last waypoint line actually spoken (not the upcoming one), including a
    /// skip prefix, the passed-by line or the route intro, plus the arrival summary once
    /// `appendToLastSpoken` added it. Not changed by veer, GPS or arrival-hint lines.
    @ObservationIgnored private var lastSpokenLine = ""
    /// The leg now being walked is curved (`"curved": true` on the waypoint just reached, e.g. WP1 of
    /// the route file): no veer, beacon quiet (`effectiveBearing` returns nil).
    @ObservationIgnored private var legCurved = false

    /// Idle until `start(_:)`. Created once as `AppModel.nav`.
    init() {}

    // MARK: Control

    /// Begins guidance on `route`: fresh tracker (with `maxAccuracy = veerMaxAccuracy`), all flags
    /// reset, then speaks "Route to <destination>. <first say>" (Step 68) and stores it for Repeat.
    /// Called by `AppModel.startRouteNow` (reached from `beginRoute` once the depth-readiness
    /// interlock clears). `lastFix` survives only if it is < 30 s old; `heading` is always cleared.
    /// The intro is `WalkingIntro.routeStarted(route)` (CaneKitLogic, Step 54) — the same call
    /// `AppModel` prefetches during the depth wait / MapKit build, so the natural-voice cache holds
    /// these exact bytes before they are spoken (`introLineIsWhatNavigationSpeaks`).
    func start(_ route: Route) {
        self.route = route
        let t = GeofenceTracker(waypoints: route.waypoints)
        t.maxAccuracy = veerMaxAccuracy
        tracker = t
        offCourse.reset()
        isNavigating = true
        arrived = false
        waypointIndex = 0
        startedAt = Date()
        gpsWeak = false
        weakSince = nil
        gpsAnnouncer = GPSAnnouncer()
        gpsLineSuppressed = false
        previousBearing = nil
        settle = nil
        isSettling = false
        legCurved = false
        lastReached = nil
        heading = nil                        // the last route's heading must not aim the new one (Muse)
        courseSmoother.reset()
        smoothedCourse = nil
        nearArrivalSince = nil
        arrivalHintGiven = false
        // A fix kept from an earlier route may be hours old and somewhere else: the new route's
        // first distance and bearing must not come from it (Antigravity nav review). Keep it only
        // if it is fresh (< 30 s); otherwise wait for the first live fix.
        if let f = lastFix, Date().timeIntervalSinceReferenceDate - f.timestamp > 30 { lastFix = nil }
        refreshInstruction()
        let intro = WalkingIntro.routeStarted(route)
        lastSpokenLine = intro
        onSpeak?(intro, .nav)
    }

    /// Ends guidance (`AppModel.stopRoute`, and `endRouteQuietly` before a restart). Clears live
    /// outputs so the beacon goes silent; keeps `route`, `arrived`, `lastSpokenLine`,
    /// `lastReached` and `lastFix`. Speaks nothing (AppModel says "Route stopped.").
    func stop() {
        isNavigating = false
        tracker = nil
        settle = nil
        isSettling = false
        instruction = "No route"
        distanceToNext = nil
        targetBearing = nil
        bearingError = nil
    }

    /// Manual "next": speaks the skipped waypoint's line and sends its wrist cue.
    /// Reached only through `AppModel.nextWaypoint()` — the GuideCard "Next" button, the watch
    /// Next button and crown gesture, and Siri `NextWaypointIntent`. The new leg is live at once
    /// (no settling: the user asked to move on). No-op when idle (AppModel says "No route running.").
    func next() {
        guard isNavigating, let tracker, let wp = tracker.advance() else { return }
        reached(wp, index: waypointIndex, isLast: tracker.isFinished, skipped: [], manual: true)
    }

    /// Re-speak the last waypoint line (watch "Repeat", Siri, on-screen button — all through
    /// `AppModel.repeatInstruction()`), then where the next waypoint is, so a line cut off at a curb
    /// is always recoverable. Works after arrival too (last line plus the trip summary, no
    /// distance). With no route: "No route running." via `onSpeak` (not `onRepeat`).
    func repeatInstruction() {
        guard isNavigating || arrived else { onSpeak?("No route running.", .nav); return }
        var text = lastSpokenLine.isEmpty ? instruction : lastSpokenLine
        if isNavigating, let d = distanceToNext, let next = tracker?.current {
            text += " Next, \(next.placeName), in \(d) meters."
        }
        onRepeat?(text)
    }

    /// Add a line spoken outside the engine (the arrival trip summary) to what Repeat says, joined
    /// with one space. Called by AppModel's `onArrived` handler after `await trip.stop()`, so
    /// Repeat at the door includes the numbers.
    func appendToLastSpoken(_ text: String) {
        lastSpokenLine = lastSpokenLine.isEmpty ? text : lastSpokenLine + " " + text
    }

    // MARK: Inputs

    /// Every GPS fix (from `location.onFix`, idle or not; ignored unless navigating). Order
    /// matters: `lastFix` + course smoother (emptied inside the just-reached corner's fence) →
    /// GPS-weak bookkeeping → settle update → distance / target bearing for the current waypoint →
    /// geofence update (which may call `reached`) → arrival hint. The fix that reaches a waypoint
    /// is never fed to the new settle; it only sets its start distance.
    /// - Parameter fix: accuracy / speed −1 = invalid; `timestamp` on the wall clock.
    func update(fix: GeoFix) {
        guard isNavigating, let tracker else { return }
        let wallNow = Date().timeIntervalSinceReferenceDate
        guard NavigationHealth.isFresh(timestamp: fix.timestamp, now: wallNow) else {
            // A delayed callback must not get to run the geofence with its own old timestamp.
            // Withdraw the route target immediately; the ticker remains the independent gate for
            // a stream that simply goes quiet.
            markLocationUnavailable(at: wallNow)
            return
        }
        lastFix = fix
        let now = fix.timestamp
        smoothedCourse = courseSmoother.update(fix)
        // Still inside the fence of the corner just reached: the trail holds the end of the old
        // leg, so its first "course" is a diagonal across the corner, 35–45° off the new leg
        // (review round 5 harness: false "Veer right." after WP2/WP3/WP6 on every clean walk).
        // Keep the smoother empty until the walker is out of the corner's fence.
        if let corner = lastReached,
           GeoMath.distanceMeters(fix.coordinate, corner.coordinate) < corner.radiusM {
            courseSmoother.reset()
            smoothedCourse = nil
        }

        // GPS quality: `gpsWeak` (pill, fences) turns on when accuracy stays bad for
        // `gpsWeakAfter`, off with the next good fix — same threshold as the tracker. Whether
        // that is SPOKEN is `GPSAnnouncer`'s call (Step 68), in `announceGPS`.
        if fix.accuracy < 0 || fix.accuracy > veerMaxAccuracy {
            if weakSince == nil { weakSince = now }
            if !gpsWeak, now - weakSince! >= gpsWeakAfter { gpsWeak = true }
        } else {
            weakSince = nil
            gpsWeak = false
            gpsLineSuppressed = false
        }
        announceGPS(now: wallNow)

        // TurnSettle is a value type: copy, mutate, write back.
        if var s = settle {
            s.update(fix)
            settle = s
        }
        refreshSettling(now: now)

        if let wp = tracker.current {
            distanceToNext = Int(GeoMath.distanceMeters(fix.coordinate, wp.coordinate).rounded())
            targetBearing = effectiveBearing(live: tracker.targetBearing(from: fix), now: now)
            recomputeError()
        }

        if let event = tracker.update(fix) {
            switch event {
            case .reached(let index, let wp, let isLast, let skipped, let passedBy):
                reached(wp, index: index, isLast: isLast, skipped: skipped, manual: false, passedBy: passedBy)
            }
        }
        checkArrivalHint(fix, now: fix.timestamp)
    }

    /// Clock-driven checks that must not wait for a GPS fix. Called at 10 Hz by AppModel's
    /// ticker while a route runs: CoreLocation stops delivering fixes when the walker stands
    /// still, which is exactly when the arrival hint is needed (review round 5). With no fix at
    /// all since `start`, `gpsWeak` turns on after `noFixAfter` (cc04946). Every beat feeds
    /// `announceGPS` first, so "GPS weak." / "GPS back." never wait for a fix (Step 68).
    /// - Parameter now: wall clock, same clock as `GeoFix.timestamp`. (The no-fix branch reads
    ///   `Date()` itself.)
    func tick(now: TimeInterval) {
        guard isNavigating else { return }
        announceGPS(now: now)
        guard let f = lastFix else {
            // No fix has EVER arrived for this route: show it (pill). The spoken "GPS weak." comes
            // from `announceGPS` above after 20 s of no fix (`GPSAnnouncer.badOnset`); recovery is the first
            // good fix in `update(fix:)`.
            if !gpsWeak, let started = startedAt,
               Date().timeIntervalSince(started) >= noFixAfter {
                gpsWeak = true
            }
            return
        }
        // CoreLocation can stop yielding updates without throwing (background suspension,
        // revoked authorization, radio failure). The ticker is the independent liveness clock:
        // after the bounded age, clear every live navigation output so the beacon cannot keep
        // pointing at a place the walker may have left. A new good fix clears `gpsWeak` in
        // `update(fix:)` and rebuilds the target.
        guard NavigationHealth.isFresh(timestamp: f.timestamp, now: now) else {
            markLocationUnavailable(at: now)
            return
        }
        checkArrivalHint(f, now: now)
    }

    /// Withdraw route guidance that depends on a location fix without ending the route itself.
    /// The app adapter calls this immediately for a failed/revoked CoreLocation stream; `tick`
    /// calls it when no such callback arrives and the retained fix ages out. The next fresh fix
    /// resumes normally through `update(fix:)`.
    /// - Parameters:
    ///   - now: wall-clock timestamp used for the off-course evidence hole.
    ///   - speak: false for authorization failures, which use their more actionable Settings line:
    ///     `GPSAnnouncer` then adds no "GPS weak." until a good fix. True leaves the line to
    ///     `GPSAnnouncer` (10 s after its bad onset; Step 68 — this no longer speaks at once).
    func markLocationUnavailable(at now: TimeInterval = Date().timeIntervalSinceReferenceDate,
                                 speak: Bool = true) {
        guard isNavigating else { return }
        gpsWeak = true
        weakSince = now
        distanceToNext = nil
        targetBearing = nil
        bearingError = nil
        courseSmoother.reset()
        smoothedCourse = nil
        nearArrivalSince = nil
        offCourse.gated(at: now)
        if !speak { gpsLineSuppressed = true }
        announceGPS(now: now)
    }

    /// Feeds `GPSAnnouncer` when GPS turned bad for it (`GPSAnnouncer.badOnset`: the retained fix
    /// older than 12 s — dated from the 5 s guidance pause — or worse than 20 m, or no fix 10 s after
    /// the route started; nil while good) and speaks its line. Review round Steps 67–68: the
    /// announcer's 12 s fix age is deliberately longer than `NavigationHealth.maxFixAge` (5 s), which
    /// still pauses guidance here and in `tick` (Step 51a) — a walker standing still with a 6 s fix
    /// cadence is not told "GPS weak.". Called by `update(fix:)`, `tick` and
    /// `markLocationUnavailable`; wall clock.
    /// - Parameter now: wall clock (`timeIntervalSinceReferenceDate`).
    private func announceGPS(now: TimeInterval) {
        guard isNavigating else { return }
        let onset = GPSAnnouncer.badOnset(lastFixAt: lastFix?.timestamp, accuracy: lastFix?.accuracy,
                                          routeStartedAt: startedAt?.timeIntervalSinceReferenceDate ?? now,
                                          now: now)
        let outdoors = !(isIndoorActive?() ?? false) && !gpsLineSuppressed
        if let line = gpsAnnouncer.update(badOnset: onset, outdoors: outdoors, now: now) {
            onSpeak?(line, .nav)
        }
    }

    /// Near the destination for 20 s but arrival has not fired (GPS too poor for the two-hit
    /// rule): one spoken hint, then leave it to the walker (Next finishes the route).
    /// A fix older than 5 s counts as standing still (no new fixes = not moving); a speed of −1
    /// (unknown) also counts as standing. Only while the *last* waypoint is current; anything else
    /// resets the 20 s clock. Does not touch `lastSpokenLine`.
    /// - Parameters:
    ///   - fix: the fix just received (`update(fix:)`) or `lastFix` (`tick`).
    ///   - now: wall clock (the fix's own timestamp from `update(fix:)`, the ticker's from `tick`).
    private func checkArrivalHint(_ fix: GeoFix, now: TimeInterval) {
        guard isNavigating, let tracker, let wp = tracker.current,
              tracker.index == tracker.waypoints.count - 1 else { nearArrivalSince = nil; return }
        let d = GeoMath.distanceMeters(fix.coordinate, wp.coordinate)
        // Only while *standing* near the door: a normal walking approach must not hear "press
        // Next to finish" (review). The zone is the fence plus half the fix's uncertainty (capped
        // at 2× the fence), not a flat 2× radius that covered almost the whole final leg.
        let zone = min(wp.radiusM * 2, wp.radiusM + max(0, fix.accuracy) / 2)
        let standing = fix.speed < 0.5 || now - fix.timestamp > 5
        guard d <= zone, standing else { nearArrivalSince = nil; return }
        if nearArrivalSince == nil { nearArrivalSince = now }
        if !arrivalHintGiven, now - nearArrivalSince! >= 20 {
            arrivalHintGiven = true
            onSpeak?("You are close to \(wp.placeName). Keep going toward it, or press Next to finish.", .nav)
        }
    }

    /// Heading in degrees true, already gyro-gated by the caller (body facing: the phone is on
    /// the cane, so a head turn never counts). `AppModel` gates only compass headings — a GPS
    /// course (walking > 0.7 m/s) always arrives (Muse H1: gating it froze the heading mid-walk).
    /// `now` is wall clock (same clock as `GeoFix.timestamp`). While settling, a heading within
    /// 30° of the new leg releases the turn and swings the beacon immediately. Veer is decided
    /// here (fix accuracy in [0, veerMaxAccuracy], speed > 0.5 m/s, fix < 5 s old, not settling,
    /// not curved, not near the current waypoint), then speaks "Veer left/right." + a wrist tap.
    /// Veer therefore only runs as often as headings arrive (compass ≥ 2° change, or each moving
    /// fix); every non-judgement is routed to `offCourse.gated(at:)` or `endEpisode()` — see the
    /// ⚠ guard-order comment inside (f39c751).
    func update(heading h: Double, now: TimeInterval) {
        guard isNavigating else { return }
        heading = h
        if var s = settle {
            s.update(heading: h, now: now)
            settle = s
            refreshSettling(now: now)
            if let f = lastFix, let tracker {
                targetBearing = effectiveBearing(live: tracker.targetBearing(from: f), now: now)
            }
        }
        recomputeError()
        // Two kinds of "no veer decision right now", and the off-course episode must treat them
        // differently:
        //  · a different *situation* — a turn still settling, a curved leg, the zone beside the
        //    current waypoint, the walker standing still: the error before it was about another
        //    leg, or about an approach they have since stopped walking, so it must not be bridged
        //    to the error after it. Those call `endEpisode()` outright.
        //  · nothing to judge *with* — no fix at all, no target bearing, a poor or stale fix, an
        //    unknown speed, no smoothed course yet: a hole in the evidence about the leg walked.
        //    Reported as `gated(at:)`, which keeps an otherwise continuous hold across one missed
        //    beat and drops the episode only when the hole passes `maxEvidenceGap` (2 s). Ending
        //    the episode on the first such moment (the earlier shape of "no instant veer after a
        //    GPS gap", a7a5fa6) meant a walker genuinely off course under intermittent GPS never
        //    reached the 3 s hold and was never warned at all — silence exactly when the warning
        //    matters most.
        //
        // ⚠ The order of the guards below is load-bearing; each one is where it is for a reason
        // (both review rounds on this fix):
        //  1. No fix at all — nothing is known, not even which situation we are in: a hole.
        //  2. `isSettling` / `legCurved` are *route* state, true or false regardless of GPS, so
        //     they are decided before the fix is judged. They must also come before any test of
        //     `bearingError`: a curved leg and a settling crossing publish no `targetBearing`
        //     (see `effectiveBearing`), so `bearingError` is nil for them too, and an
        //     evidence-shaped guard would misreport them as a hole and bridge them.
        //  3. Fix quality (accuracy, staleness). A fix we have just declared untrustworthy must
        //     not drive *any* decision — including "the walker is beside the waypoint" in guard 5.
        //     Judging that on a 40 m blob and calling `endEpisode()` would silence a genuine
        //     drift on a position we do not believe.
        //  4. Speed, and the two halves mean opposite things — this is the distinction the whole
        //     fix turns on, and getting it wrong is a false "Veer" at a blind walker:
        //       · `speed < 0` is CoreLocation saying it does not know: a hole, bridge it.
        //       · `0 ≤ speed ≤ 0.5` is a *measurement* that the walker is not making progress.
        //         Standing is the one state in which a walker can turn to face anywhere with no
        //         evidence recording it, and the course smoother's 15 m trail still describes the
        //         approach they walked *before* stopping. Bridging a 1 s stop therefore lets the
        //         pre-stop drift finish the 3 s hold after the walker has already corrected and
        //         set off again — "Veer right." at someone now walking the right way (adversarial
        //         review, finding 1; the pure-logic half is pinned by `aStopMidDriftRestartsTheHold`).
        //         So a standing fix ends the episode, exactly as it did before this fix.
        //  5. `isNearCurrent` only now, on a fix good enough to locate the walker: a real change
        //     of situation, so the drift before the corner is never added to the drift after it.
        //  6. Whatever is left with no `bearingError` (and, while walking, no smoothed course) is
        //     genuinely a missing measurement, not a situation: a hole. Reachable right after
        //     `start()` keeps a < 30 s `lastFix`, before the first live fix computes a target.
        guard let fix = lastFix, let tracker else {
            offCourse.gated(at: now)         // no fix yet on this route: a hole, not a verdict
            return
        }
        guard !isSettling, !legCurved else {
            offCourse.endEpisode()
            return
        }
        guard fix.accuracy >= 0, fix.accuracy <= veerMaxAccuracy,
              NavigationHealth.isFresh(timestamp: fix.timestamp, now: now) else {
            offCourse.gated(at: now)
            return
        }
        guard fix.speed >= 0 else {
            offCourse.gated(at: now)         // CoreLocation reports −1 for "no speed": a hole
            return
        }
        guard fix.speed > 0.5 else {
            offCourse.endEpisode()           // standing: measured, not missing — see guard 4
            return
        }
        guard !tracker.isNearCurrent(fix) else {
            offCourse.endEpisode()
            return
        }
        guard let raw = bearingError else {
            offCourse.gated(at: now)         // no target bearing yet: a hole, not a verdict
            return
        }
        // Walking: judge against the smoothed course (jitter-proof); standing/slow: the heading.
        var err = raw
        if fix.speed > 0.7 {
            // Walking: only the smoothed course counts. It is reset at every waypoint and kept
            // empty inside the corner's fence, so there is no veer judgement until ~15 m past the
            // fence (review: the old leg's course lagged ~16 s after each turn and produced false
            // veers right after WP2/WP3/WP6).
            guard let course = smoothedCourse, let target = targetBearing else {
                offCourse.gated(at: now)         // no judgement possible: a hole, not a verdict
                return
            }
            err = GeoMath.bearingError(target: target, heading: course)
        }
        if let turn = offCourse.update(error: err, now: now) {
            onSpeak?(turn == .left ? "Veer left." : "Veer right.", .nav)
            onNavCue?(turn == .left ? .turnLeft : .turnRight)
            // The 15 m trail still holds the veer: without a reset it re-fires once the 10 s
            // cooldown ends, after the walker has already corrected (nav harness, round 5).
            courseSmoother.reset()
            smoothedCourse = nil
            offCourse.endEpisode()               // the next veer needs a full 3 s hold again
        }
    }

    // MARK: Internals

    /// Clears the settle once TurnSettle says the new leg is live (and restarts the off-course
    /// hold timer on the new leg); otherwise keeps `isSettling` true. With no settle, just
    /// `isSettling = false`. Called after every settle mutation (fix, heading) and from `reached`
    /// (an immediate settle — manual / passed-by — is cleared on the spot).
    /// - Parameter now: wall clock, compared against the settle's `releaseAt`.
    private func refreshSettling(now: TimeInterval) {
        guard let s = settle else { isSettling = false; return }
        if s.isLive(at: now) {
            settle = nil
            isSettling = false
            offCourse.reset()               // the hold time starts fresh on the new leg
        } else {
            isSettling = true
        }
    }

    /// Curved leg → silent; settling → held / silent (TurnSettle); otherwise the live bearing.
    /// The single place that decides what the beacon aims at; nil means no clicks.
    /// - Parameters:
    ///   - live: `GeofenceTracker.targetBearing(from:)` (already the recorded leg bearing near the
    ///     current waypoint or on a poor fix), or a recorded leg bearing when there is no fix.
    ///   - now: wall clock for `TurnSettle.bearing(live:at:)`.
    private func effectiveBearing(live: Double?, now: TimeInterval) -> Double? {
        if legCurved { return nil }
        if let s = settle { return s.bearing(live: live, at: now) }
        return live
    }

    /// `bearingError = wrap180(targetBearing − heading)`, nil if either is unknown. Uses the raw
    /// heading, not the smoothed course; the walking-speed veer check substitutes the course itself.
    private func recomputeError() {
        guard let t = targetBearing, let h = heading else { bearingError = nil; return }
        bearingError = GeoMath.bearingError(target: t, heading: h)
    }

    /// One waypoint reached (fence entry, passed-by, skip-ahead or manual `next()`): speak, tap the
    /// wrist, advance, and build the TurnSettle for the corner.
    /// - `index`: route index of `wp`; `skipped`: fences missed on the way (skip-ahead);
    ///   `manual`: from `next()`; `passedBy`: walked past without entering the fence.
    /// - Passed-by: says "Passed <place>." (+ " <Next place> in N meters." when a next waypoint and
    ///   a fix exist) — never `wp.say` (its "turn right…" would be wrong by then). No wrist cue for
    ///   an intermediate waypoint; a passed-by *destination* still sends `.arrived` (c550425, Muse
    ///   nav review: GPS jumping past the arrival fence was silent on the wrist and cane).
    /// - Otherwise: "Passed one waypoint." / "Passed N waypoints." first if any were skipped, then
    ///   `wp.say`. Wrist precedence: skipped crossing → `.crossing`; last → `.arrived`; crossing →
    ///   `.crossing`; else a turn cue when the leg bearing changes by more than ±30°.
    /// - Manual or passed-by advances are live at once (`releasedAt: now`); otherwise the previous
    ///   leg's bearing is held until TurnSettle releases it.
    /// - Every advance resets `offCourse`, the course smoother and `legCurved`; the last waypoint
    ///   sets `arrived`, clears `isNavigating` and fires `onArrived` after `onWaypointAdvanced`.
    /// - `lastSpokenLine` becomes the line just spoken (with the skip prefix), for Repeat.
    /// ⚠ Do not change the ±30° delta or the settle construction without re-running the
    /// TurnSettle tests in `NavSupportTests` and the device walk (see file header).
    private func reached(_ wp: Waypoint, index: Int, isLast: Bool, skipped: [Waypoint], manual: Bool,
                         passedBy: Bool = false) {
        waypointIndex = index + 1
        lastReached = wp
        let nextWp = isLast ? nil : route?.waypoints[safe: index + 1]
        let prev = skipped.last?.bearingNextDeg ?? previousBearing

        if passedBy {
            // Walked past it without entering the fence: the user is already beyond the corner,
            // so its "turn right…" line would be wrong now. Name it, point at the next one.
            var line = "Passed \(wp.placeName)."
            if let nextWp, let f = lastFix {
                let d = Int(GeoMath.distanceMeters(f.coordinate, nextWp.coordinate).rounded())
                line += " \(nextWp.placeName.sentenceCased) in \(d) meters."
            }
            lastSpokenLine = line
            onSpeak?(line, .nav)
            // GPS jumped past the destination's fence: still the arrival, so the wrist and the
            // cane get the arrival pattern (Muse nav review: it was silent).
            if isLast { onNavCue?(.arrived) }
        } else {
            // A skipped fence means the user is already past it: say so briefly, then the real line.
            var prefix = ""
            if !skipped.isEmpty {
                prefix = skipped.count == 1 ? "Passed one waypoint." : "Passed \(skipped.count) waypoints."
                onSpeak?(prefix, .nav)
            }
            // Repeat must say what was actually said, including the skip (Muse nav review).
            lastSpokenLine = prefix.isEmpty ? wp.say : prefix + " " + wp.say
            onSpeak?(wp.say, .nav)
            // Wrist: crossing beats turn; turn direction from the change in bearing. A skipped
            // crossing still gets its tap — the user just walked across that street.
            if skipped.contains(where: \.crossing), !wp.crossing, !isLast {
                onNavCue?(.crossing)
            } else if isLast {
                onNavCue?(.arrived)
            } else if wp.crossing {
                onNavCue?(.crossing)
            } else if let prev, let next = wp.bearingNextDeg {
                let delta = GeoMath.wrap180(next - prev)
                if delta > 30 { onNavCue?(.turnRight) } else if delta < -30 { onNavCue?(.turnLeft) }
            }
        }
        previousBearing = wp.bearingNextDeg
        legCurved = wp.curved
        offCourse.reset()
        courseSmoother.reset()               // the old leg's course must not judge the new one
        smoothedCourse = nil

        if isLast {
            settle = nil
            isSettling = false
            arrived = true
            isNavigating = false
            instruction = "Arrived: \(wp.say)"
            distanceToNext = 0
        } else {
            // Hold the old leg until the turn is really made. A passed-by or manual advance
            // means we are already beyond the corner: live at once.
            let now = lastFix?.timestamp ?? Date().timeIntervalSinceReferenceDate
            let startD = lastFix.map { GeoMath.distanceMeters($0.coordinate, wp.coordinate) } ?? .infinity
            let immediate = manual || passedBy
            settle = TurnSettle(anchor: wp.coordinate, radiusM: wp.radiusM,
                                heldBearing: immediate ? nil : prev,
                                // Heading release only when there is a turn to detect: at a
                                // straight-through crossing the heading already matches, so it
                                // would end the curb silence on the fence-entry fix (review).
                                nextBearing: Self.isTurn(from: prev, to: wp.bearingNextDeg) ? wp.bearingNextDeg : nil,
                                isCrossing: wp.crossing && !immediate,
                                startDistance: startD,
                                releasedAt: immediate ? now : nil)
            refreshSettling(now: now)
            refreshInstruction()
        }
        onWaypointAdvanced?()               // after the instruction refresh: watch/Live Activity see the new leg
        if isLast { onArrived?() }
    }

    /// Sets `instruction` to the current waypoint's line (or "Arrived") and recomputes distance and
    /// target bearing. Without a fix yet, the target is the recorded bearing of the leg just
    /// reached (nil before WP1, so a fresh route with no fix has a silent beacon until one arrives).
    /// Called by `start` and by `reached` for a non-final waypoint.
    private func refreshInstruction() {
        guard let tracker, let wp = tracker.current else { instruction = "Arrived"; return }
        instruction = wp.say
        if let f = lastFix {
            distanceToNext = Int(GeoMath.distanceMeters(f.coordinate, wp.coordinate).rounded())
            targetBearing = effectiveBearing(live: tracker.targetBearing(from: f), now: f.timestamp)
            recomputeError()
        } else {
            let leg = waypointIndex > 0 ? route?.waypoints[waypointIndex - 1].bearingNextDeg : nil
            targetBearing = effectiveBearing(live: leg, now: Date().timeIntervalSinceReferenceDate)
        }
    }
}

/// Pure helper kept on the engine type (not in CaneKitLogic, untested) because only `reached` uses it.
extension NavigationEngine {
    /// True when the bearing change at a waypoint is a real turn (> 30°, the same threshold as the
    /// turn wrist cue). `next == nil` (the destination) → false; `prev == nil` (WP1, or no recorded
    /// leg) with a `next` → true, so a heading release is allowed when the change is unknown.
    /// Decides whether `TurnSettle` gets a `nextBearing` (heading release): at a straight-through
    /// crossing a heading release would end the curb silence on the fence-entry fix (Step 11 review).
    static func isTurn(from prev: Double?, to next: Double?) -> Bool {
        guard let prev, let next else { return next != nil }
        return abs(GeoMath.wrap180(next - prev)) > 30
    }
}

/// File-private string helper for the passed-by line.
private extension String {
    /// "the CIF east entrance" → "The CIF east entrance" when it opens a sentence. Upper-cases
    /// only the first character; the rest is left as written (so "CIF" stays "CIF").
    var sentenceCased: String { prefix(1).uppercased() + dropFirst() }
}

/// File-private collection helper for `reached`.
private extension Array {
    /// Bounds-checked index: nil instead of a trap past the last waypoint.
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
