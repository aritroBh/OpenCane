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
//    · the fix is inside the current waypoint's passed-by zone (live bearing swings / points back);
//    · the current leg is `curved` in the route file (chord bearing ≠ walking direction);
//    · the fix is poor (> 20 m), stale (> 5 s) or the user is not walking (≤ 0.5 m/s).
//

import CaneKitLogic
import Foundation
import Observation

@MainActor
@Observable
final class NavigationEngine {

    // MARK: Published

    private(set) var route: Route?
    private(set) var isNavigating = false
    private(set) var arrived = false
    /// Text of the *next* waypoint's line ("Goodwin Avenue. Crossing.") for the UI / watch preview.
    private(set) var instruction = "No route"
    /// Metres to the next waypoint, nil when unknown.
    private(set) var distanceToNext: Int?
    /// Bearing to walk right now (degrees true), nil when unknown or deliberately silent (settling
    /// at a crossing, curved leg). While a turn is settling this is the *previous* leg's bearing.
    private(set) var targetBearing: Double?
    /// Signed error target − heading in (−180, 180], nil when either is unknown.
    private(set) var bearingError: Double?
    private(set) var waypointIndex = 0
    private(set) var startedAt: Date?
    private(set) var gpsWeak = false
    /// True between a waypoint being reached and the user having actually made the turn.
    private(set) var isSettling = false
    /// The waypoint reached most recently (auto-recenter needs to know if it was a crossing).
    private(set) var lastReached: Waypoint?

    /// Outputs, all on the main actor.
    @ObservationIgnored var onSpeak: ((String, SpeechPriority) -> Void)?
    /// "Say that again": must bypass the queue's coalescing (the line may still be playing).
    @ObservationIgnored var onRepeat: ((String) -> Void)?
    @ObservationIgnored var onNavCue: ((NavCue) -> Void)?
    @ObservationIgnored var onWaypointAdvanced: (() -> Void)?
    @ObservationIgnored var onArrived: (() -> Void)?

    // MARK: Tunables

    /// Veer cues need a fix at least this good (metres). Matches `GeofenceTracker.maxAccuracy`
    /// so "GPS weak" is announced exactly when the fences stop firing.
    var veerMaxAccuracy: Double = 20
    /// Seconds of bad accuracy before "GPS weak" is spoken.
    var gpsWeakAfter: TimeInterval = 10

    // MARK: Private

    @ObservationIgnored private var tracker: GeofenceTracker?
    @ObservationIgnored private let offCourse = OffCourseDetector()
    @ObservationIgnored private var lastFix: GeoFix?
    @ObservationIgnored private var heading: Double?
    @ObservationIgnored private var weakSince: TimeInterval?
    /// Bearing the user was walking when this waypoint was reached (turn direction for the wrist).
    @ObservationIgnored private var previousBearing: Double?
    /// Settling state for the most recently reached waypoint (see TurnSettle in CaneKitLogic).
    @ObservationIgnored private var settle: TurnSettle?
    /// What Repeat says: the last waypoint line actually spoken (not the upcoming one).
    @ObservationIgnored private var lastSpokenLine = ""
    /// The leg now being walked is curved: no veer, beacon quiet.
    @ObservationIgnored private var legCurved = false

    init() {}

    // MARK: Control

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
        refreshInstruction()
        let intro = "Route started. \(route.name). First: \(route.waypoints.first?.say ?? "")"
        lastSpokenLine = intro
        onSpeak?(intro, .nav)
    }

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
    func next() {
        guard isNavigating, let tracker, let wp = tracker.advance() else { return }
        reached(wp, index: waypointIndex, isLast: tracker.isFinished, skipped: [], manual: true)
    }

    /// Re-speak the last waypoint line (watch "Repeat", Siri, on-screen button), then where the
    /// next waypoint is, so a line cut off at a curb is always recoverable.
    func repeatInstruction() {
        guard isNavigating || arrived else { onSpeak?("No route running.", .nav); return }
        var text = lastSpokenLine.isEmpty ? instruction : lastSpokenLine
        if isNavigating, let d = distanceToNext, let next = tracker?.current {
            text += " Next, \(next.placeName), in \(d) meters."
        }
        onRepeat?(text)
    }

    /// Add a line spoken outside the engine (the arrival trip summary) to what Repeat says.
    func appendToLastSpoken(_ text: String) {
        lastSpokenLine = lastSpokenLine.isEmpty ? text : lastSpokenLine + " " + text
    }

    // MARK: Inputs

    func update(fix: GeoFix) {
        guard isNavigating, let tracker else { return }
        lastFix = fix
        let now = fix.timestamp

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
    }

    /// Heading in degrees true, already gyro-gated by the caller (body facing: the phone is on
    /// the cane, so a head turn never counts).
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
        guard let err = bearingError, let fix = lastFix, let tracker,
              fix.accuracy >= 0, fix.accuracy <= veerMaxAccuracy,
              fix.speed > 0.5, now - fix.timestamp < 5,
              !isSettling, !legCurved, !tracker.isNearCurrent(fix) else { return }
        if let turn = offCourse.update(error: err, now: now) {
            onSpeak?(turn == .left ? "Veer left." : "Veer right.", .nav)
            onNavCue?(turn == .left ? .turnLeft : .turnRight)
        }
    }

    // MARK: Internals

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

    private func recomputeError() {
        guard let t = targetBearing, let h = heading else { bearingError = nil; return }
        bearingError = GeoMath.bearingError(target: t, heading: h)
    }

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
        } else {
            // A skipped fence means the user is already past it: say so briefly, then the real line.
            if !skipped.isEmpty {
                onSpeak?(skipped.count == 1 ? "Passed one waypoint." : "Passed \(skipped.count) waypoints.", .nav)
            }
            lastSpokenLine = wp.say
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
                                nextBearing: wp.bearingNextDeg,
                                isCrossing: wp.crossing && !immediate,
                                startDistance: startD,
                                releasedAt: immediate ? now : nil)
            refreshSettling(now: now)
            refreshInstruction()
        }
        onWaypointAdvanced?()               // after the instruction refresh: watch/Live Activity see the new leg
        if isLast { onArrived?() }
    }

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

private extension String {
    /// "the CIF east entrance" → "The CIF east entrance" when it opens a sentence.
    var sentenceCased: String { prefix(1).uppercased() + dropFirst() }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
