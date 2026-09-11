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
//
//  Owner: `AppModel.nav` (one instance). Module `navigation-trip` in docs/CODE_REFERENCE.md.
//  Inputs arrive from `AppModel.wireNavigation()` (fixes from LocationService, gyro-gated
//  headings); outputs are the `on…` callbacks, all installed by AppModel. The UI (GuideCard)
//  reads the published state and calls `next()`; the 10 Hz ticker reads `targetBearing`.
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
//  ⚠ No unit test covers this class (app target). Do not change the ±30° turn delta, the veer
//  gate or its mute conditions, or the settle construction in `reached` without re-running the
//  GeoMath / NavSupport tests listed in docs/CODE_REFERENCE.md and the step-10 device walk.
//

import CaneKitLogic
import Foundation
import Observation

/// Owner of route-following state and timing; delegates every numeric decision to CaneKitLogic.
@MainActor
@Observable
final class NavigationEngine {

    // MARK: Published

    /// The route being (or last) walked. Not cleared by `stop()`; the arrival card reads it.
    private(set) var route: Route?
    /// True from `start` until arrival or `stop()`. Gates every input.
    private(set) var isNavigating = false
    /// True once the last waypoint is reached (irreversible until the next `start`).
    private(set) var arrived = false
    /// Text of the *next* waypoint's line ("Goodwin Avenue. Crossing.") for the UI / watch preview.
    private(set) var instruction = "No route"
    /// Metres to the next waypoint, nil when unknown.
    private(set) var distanceToNext: Int?
    /// Bearing to walk right now (degrees true), nil when unknown or deliberately silent (settling
    /// at a crossing, curved leg). While a turn is settling this is the *previous* leg's bearing.
    /// Read by AppModel's 10 Hz ticker → `BeaconEngine.setTarget(bearing:)`; nil = no clicks.
    private(set) var targetBearing: Double?
    /// Signed error target − heading in (−180, 180], nil when either is unknown.
    /// Positive = the target is to the user's right. Degrees.
    private(set) var bearingError: Double?
    /// Number of waypoints reached so far (= index of the current target waypoint).
    private(set) var waypointIndex = 0
    /// Wall-clock time `start` ran.
    private(set) var startedAt: Date?
    /// True while accuracy has been worse than `veerMaxAccuracy` for ≥ `gpsWeakAfter` seconds.
    private(set) var gpsWeak = false
    /// True between a waypoint being reached and the user having actually made the turn.
    private(set) var isSettling = false
    /// The waypoint reached most recently (auto-recenter needs to know if it was a crossing).
    private(set) var lastReached: Waypoint?

    /// Outputs, all on the main actor.
    /// Every waypoint / GPS / veer line; priority is always `.nav`. AppModel → `speech.say(ttl: 12)`.
    @ObservationIgnored var onSpeak: ((String, SpeechPriority) -> Void)?
    /// "Say that again": must bypass the queue's coalescing (the line may still be playing).
    @ObservationIgnored var onRepeat: ((String) -> Void)?
    /// Wrist tap (`.crossing`, `.turnLeft/.turnRight`, `.arrived`); also feeds the Live Activity glyph.
    @ObservationIgnored var onNavCue: ((NavCue) -> Void)?
    /// Fired after every advance (fence, passed-by or manual), after `instruction` is refreshed so
    /// the watch / Live Activity see the new leg. AppModel marks a head recenter pending here.
    @ObservationIgnored var onWaypointAdvanced: (() -> Void)?
    /// Fired once when the last waypoint is reached, after `onWaypointAdvanced`.
    @ObservationIgnored var onArrived: (() -> Void)?

    // MARK: Tunables

    /// Veer cues need a fix at least this good (metres). Matches `GeofenceTracker.maxAccuracy`
    /// so "GPS weak" is announced exactly when the fences stop firing.
    /// Copied into the tracker in `start()`. ⚠ Do not change independently of
    /// `GeofenceTracker.maxAccuracy` (20 m) — the "GPS weak" line promises the fences are paused
    /// (AGENTS.md: "GPS weak" is spoken at the same 20 m).
    var veerMaxAccuracy: Double = 20
    /// Seconds of bad accuracy before "GPS weak" is spoken.
    var gpsWeakAfter: TimeInterval = 10

    // MARK: Private

    /// Geofence state machine for the current route (lookahead 2, passed-by, arrival streak).
    @ObservationIgnored private var tracker: GeofenceTracker?
    /// "Veer" decider: 25° off for 3 s, 10 s cooldown (CaneKitLogic defaults).
    @ObservationIgnored private let offCourse = OffCourseDetector()
    /// Most recent fix (kept across `stop()`/`start()`); used for distances, the veer gate, the
    /// clock-driven arrival hint (`tick`) and by AppModel to geotag hazards after arrival.
    @ObservationIgnored private(set) var lastFix: GeoFix?
    /// Latest gyro-gated body heading, degrees true.
    @ObservationIgnored private var heading: Double?
    /// Direction of travel over ≥ 15 m (CaneKitLogic.CourseSmoother). Veer decisions use this
    /// while walking, so a few metres of GPS jitter never becomes "Veer left/right"
    /// (e2e gps_jitter: 28 false veers with the per-fix course).
    @ObservationIgnored private var courseSmoother = CourseSmoother()
    @ObservationIgnored private var smoothedCourse: Double?
    /// Standing near the last waypoint without the two plausible arrival fixes (GPS under the
    /// entrance overhang): after 20 s say so once, so the walker is never left wondering.
    @ObservationIgnored private var nearArrivalSince: TimeInterval?
    @ObservationIgnored private var arrivalHintGiven = false
    /// Fix timestamp at which accuracy first went bad; nil while accuracy is good.
    @ObservationIgnored private var weakSince: TimeInterval?
    /// Bearing the user was walking when this waypoint was reached (turn direction for the wrist).
    @ObservationIgnored private var previousBearing: Double?
    /// Settling state for the most recently reached waypoint (see TurnSettle in CaneKitLogic).
    @ObservationIgnored private var settle: TurnSettle?
    /// What Repeat says: the last waypoint line actually spoken (not the upcoming one).
    @ObservationIgnored private var lastSpokenLine = ""
    /// The leg now being walked is curved: no veer, beacon quiet.
    @ObservationIgnored private var legCurved = false

    /// Idle until `start(_:)`.
    init() {}

    // MARK: Control

    /// Begins guidance on `route`: fresh tracker (with `maxAccuracy = veerMaxAccuracy`), all flags
    /// reset, then speaks "Route started. <name>. First: <line>" and stores it for Repeat.
    /// Called by `AppModel.beginRoute`. Does not clear `lastFix`.
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
        previousBearing = nil
        settle = nil
        isSettling = false
        legCurved = false
        lastReached = nil
        courseSmoother.reset()
        smoothedCourse = nil
        nearArrivalSince = nil
        arrivalHintGiven = false
        // A fix kept from an earlier route may be hours old and somewhere else: the new route's
        // first distance and bearing must not come from it (Antigravity nav review). Keep it only
        // if it is fresh (< 30 s); otherwise wait for the first live fix.
        if let f = lastFix, Date().timeIntervalSinceReferenceDate - f.timestamp > 30 { lastFix = nil }
        refreshInstruction()
        let intro = "Route started. \(route.name). First: \(route.waypoints.first?.say ?? "")"
        lastSpokenLine = intro
        onSpeak?(intro, .nav)
    }

    /// Ends guidance (AppModel.stopRoute). Clears live outputs so the beacon goes silent; keeps
    /// `route`, `arrived`, `lastSpokenLine` and `lastReached`.
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

    /// Manual "next" from the watch / Action button: speaks the skipped waypoint's line.
    /// Also the GuideCard "Next" button and the watch crown gesture. The new leg is live at once
    /// (no settling: the user asked to move on).
    func next() {
        guard isNavigating, let tracker, let wp = tracker.advance() else { return }
        reached(wp, index: waypointIndex, isLast: tracker.isFinished, skipped: [], manual: true)
    }

    /// Re-speak the last waypoint line (watch "Repeat", Siri, on-screen button), then where the
    /// next waypoint is, so a line cut off at a curb is always recoverable.
    /// Works after arrival too (last line only). With no route: "No route running." via `onSpeak`.
    func repeatInstruction() {
        guard isNavigating || arrived else { onSpeak?("No route running.", .nav); return }
        var text = lastSpokenLine.isEmpty ? instruction : lastSpokenLine
        if isNavigating, let d = distanceToNext, let next = tracker?.current {
            text += " Next, \(next.placeName), in \(d) meters."
        }
        onRepeat?(text)
    }

    /// Add a line spoken outside the engine (the arrival trip summary) to what Repeat says.
    /// Called by AppModel's `onArrived` handler.
    func appendToLastSpoken(_ text: String) {
        lastSpokenLine = lastSpokenLine.isEmpty ? text : lastSpokenLine + " " + text
    }

    // MARK: Inputs

    /// Every GPS fix (from `location.onFix`). Order matters: GPS-weak bookkeeping → settle update
    /// → distance / target bearing for the current waypoint → geofence update (which may call
    /// `reached`). The fix that reaches a waypoint is never fed to the new settle; it only sets
    /// its start distance.
    func update(fix: GeoFix) {
        guard isNavigating, let tracker else { return }
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

        // GPS quality: announce once when it degrades long enough to pause the fences, once
        // when it recovers. Same threshold as the tracker, so the warning is never silent.
        if fix.accuracy < 0 || fix.accuracy > veerMaxAccuracy {
            if weakSince == nil { weakSince = now }
            if !gpsWeak, now - weakSince! >= gpsWeakAfter {
                gpsWeak = true
                onSpeak?("GPS weak. Waypoint cues paused until it recovers.", .nav)
            }
        } else {
            weakSince = nil
            if gpsWeak { gpsWeak = false; onSpeak?("GPS back.", .nav) }
        }

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
    /// still, which is exactly when the arrival hint is needed (review round 5).
    /// - Parameter now: wall clock, same clock as `GeoFix.timestamp`.
    func tick(now: TimeInterval) {
        guard isNavigating, let f = lastFix else { return }
        checkArrivalHint(f, now: now)
    }

    /// Near the destination for 20 s but arrival has not fired (GPS too poor for the two-hit
    /// rule): one spoken hint, then leave it to the walker (Next finishes the route).
    /// A fix older than 5 s counts as standing still (no new fixes = not moving).
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
    /// the cane, so a head turn never counts).
    /// `now` is wall clock (same clock as `GeoFix.timestamp`). While settling, a heading within
    /// 30° of the new leg releases the turn and swings the beacon immediately. Veer is decided
    /// here (fix accuracy in [0, veerMaxAccuracy], speed > 0.5 m/s, fix < 5 s old, not settling,
    /// not curved, not near the current waypoint), then speaks "Veer left/right." + a wrist tap.
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
        guard let raw = bearingError, let fix = lastFix, let tracker,
              fix.accuracy >= 0, fix.accuracy <= veerMaxAccuracy,
              fix.speed > 0.5, now - fix.timestamp < 5,
              !isSettling, !legCurved, !tracker.isNearCurrent(fix) else { return }
        // Walking: judge against the smoothed course (jitter-proof); standing/slow: the heading.
        var err = raw
        if fix.speed > 0.7 {
            // Walking: only the smoothed course counts. It is reset at every waypoint and kept
            // empty inside the corner's fence, so there is no veer judgement until ~15 m past the
            // fence (review: the old leg's course lagged ~16 s after each turn and produced false
            // veers right after WP2/WP3/WP6).
            guard let course = smoothedCourse, let target = targetBearing else {
                offCourse.endEpisode()           // no judgement possible: no episode either
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
    /// hold timer on the new leg); otherwise keeps `isSettling` true.
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
    private func effectiveBearing(live: Double?, now: TimeInterval) -> Double? {
        if legCurved { return nil }
        if let s = settle { return s.bearing(live: live, at: now) }
        return live
    }

    /// `bearingError = wrap180(targetBearing − heading)`, nil if either is unknown.
    private func recomputeError() {
        guard let t = targetBearing, let h = heading else { bearingError = nil; return }
        bearingError = GeoMath.bearingError(target: t, heading: h)
    }

    /// One waypoint reached (fence entry, passed-by, skip-ahead or manual `next()`): speak, tap the
    /// wrist, advance, and build the TurnSettle for the corner.
    /// - `index`: route index of `wp`; `skipped`: fences missed on the way (skip-ahead);
    ///   `manual`: from `next()`; `passedBy`: walked past without entering the fence.
    /// - Passed-by: says "Passed <place>. <Next place> in N meters." — never `wp.say` (its "turn
    ///   right…" would be wrong by then) — and sends no wrist cue.
    /// - Otherwise: "Passed one waypoint." / "Passed N waypoints." first if any were skipped, then
    ///   `wp.say`. Wrist precedence: skipped crossing → `.crossing`; last → `.arrived`; crossing →
    ///   `.crossing`; else a turn cue when the leg bearing changes by more than ±30°.
    /// - Manual or passed-by advances are live at once (`releasedAt: now`); otherwise the previous
    ///   leg's bearing is held until TurnSettle releases it.
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
    /// reached (nil before WP1).
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

extension NavigationEngine {
    /// True when the bearing change at a waypoint is a real turn (> 30°).
    static func isTurn(from prev: Double?, to next: Double?) -> Bool {
        guard let prev, let next else { return next != nil }
        return abs(GeoMath.wrap180(next - prev)) > 30
    }
}

private extension String {
    /// "the CIF east entrance" → "The CIF east entrance" when it opens a sentence.
    var sentenceCased: String { prefix(1).uppercased() + dropFirst() }
}

private extension Array {
    /// Bounds-checked index: nil instead of a trap past the last waypoint.
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
