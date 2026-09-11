//
//  NavigationEngine.swift
//  CaneKit
//
//  Walks a `Route` waypoint by waypoint: geofence entry speaks the waypoint's line once, sends
//  the wrist cue (crossing / turn), advances, and re-aims the beacon. Off-bearing for 3 s →
//  "veer left/right". Pure decisions live in CaneKitLogic (GeofenceTracker, OffCourseDetector);
//  this class owns state, timing and the outputs.
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
    /// Text of the *next* waypoint's line ("Goodwin Avenue. Crossing.") for the UI / watch.
    private(set) var instruction = "No route"
    /// Metres to the next waypoint, nil when unknown.
    private(set) var distanceToNext: Int?
    /// Bearing to walk (degrees true), nil when unknown.
    private(set) var targetBearing: Double?
    /// Signed error target − heading in (−180, 180], nil when either is unknown.
    private(set) var bearingError: Double?
    private(set) var waypointIndex = 0
    private(set) var startedAt: Date?
    private(set) var gpsWeak = false

    /// Outputs, all on the main actor.
    @ObservationIgnored var onSpeak: ((String, SpeechPriority) -> Void)?
    @ObservationIgnored var onNavCue: ((NavCue) -> Void)?
    @ObservationIgnored var onWaypointAdvanced: (() -> Void)?
    @ObservationIgnored var onArrived: (() -> Void)?

    // MARK: Private

    @ObservationIgnored private var tracker: GeofenceTracker?
    @ObservationIgnored private let offCourse = OffCourseDetector()
    @ObservationIgnored private var lastFix: GeoFix?
    @ObservationIgnored private var heading: Double?
    @ObservationIgnored private var weakSince: TimeInterval?
    @ObservationIgnored private var lastVeerAt: TimeInterval = -.infinity
    /// No veer cues for a few seconds after a waypoint: the user is mid-turn and the heading lags.
    @ObservationIgnored private var suppressVeerUntil: TimeInterval = -.infinity
    var turnSettleSeconds: TimeInterval = 8
    /// Bearing the user was walking when this waypoint was reached (turn direction for the wrist).
    @ObservationIgnored private var previousBearing: Double?

    init() {}

    // MARK: Control

    func start(_ route: Route) {
        self.route = route
        tracker = GeofenceTracker(waypoints: route.waypoints)
        offCourse.reset()
        isNavigating = true
        arrived = false
        waypointIndex = 0
        startedAt = Date()
        gpsWeak = false
        weakSince = nil
        previousBearing = nil
        refreshInstruction()
        onSpeak?("Route started. \(route.name). First: \(route.waypoints.first?.say ?? "")", .nav)
    }

    func stop() {
        isNavigating = false
        tracker = nil
        instruction = "No route"
        distanceToNext = nil
        targetBearing = nil
        bearingError = nil
    }

    /// Manual "next" from the watch / Action button: speaks the skipped waypoint's line.
    func next() {
        guard isNavigating, let tracker, let wp = tracker.advance() else { return }
        reached(wp, index: waypointIndex, isLast: tracker.isFinished, manual: true)
    }

    // MARK: Inputs

    func update(fix: GeoFix) {
        guard isNavigating, let tracker else { return }
        lastFix = fix
        let now = fix.timestamp

        // GPS quality: announce once when it degrades for 10 s, once when it recovers.
        if fix.accuracy < 0 || fix.accuracy > 25 {
            if weakSince == nil { weakSince = now }
            if !gpsWeak, now - weakSince! >= 10 {
                gpsWeak = true
                onSpeak?("GPS weak. Cues may be late.", .nav)
            }
        } else {
            weakSince = nil
            if gpsWeak { gpsWeak = false; onSpeak?("GPS back.", .nav) }
        }

        if let wp = tracker.current {
            distanceToNext = Int(GeoMath.distanceMeters(fix.coordinate, wp.coordinate).rounded())
            targetBearing = tracker.targetBearing(from: fix)
            recomputeError()
        }

        if let event = tracker.update(fix) {
            switch event {
            case .reached(let index, let wp, let isLast):
                reached(wp, index: index, isLast: isLast, manual: false)
            }
        }
    }

    /// Heading in degrees true, already gyro-gated by the caller.
    func update(heading h: Double, now: TimeInterval) {
        guard isNavigating else { return }
        heading = h
        recomputeError()
        // Veer cues need a fresh, good, moving fix (GPS timestamps and `now` share the wall clock).
        guard let err = bearingError, let fix = lastFix, fix.accuracy >= 0, fix.accuracy <= 15,
              fix.speed > 0.5, now - fix.timestamp < 5, now >= suppressVeerUntil else { return }
        if let turn = offCourse.update(error: err, now: now) {
            lastVeerAt = now
            onSpeak?(turn == .left ? "Veer left." : "Veer right.", .nav)
            onNavCue?(turn == .left ? .turnLeft : .turnRight)
        }
    }

    // MARK: Internals

    private func recomputeError() {
        guard let t = targetBearing, let h = heading else { bearingError = nil; return }
        bearingError = GeoMath.bearingError(target: t, heading: h)
    }

    private func reached(_ wp: Waypoint, index: Int, isLast: Bool, manual: Bool) {
        waypointIndex = index + 1
        onSpeak?(wp.say, .nav)
        // Wrist: crossing beats turn; turn direction from the change in bearing.
        if isLast {
            onNavCue?(.arrived)
        } else if wp.crossing {
            onNavCue?(.crossing)
        } else if let prev = previousBearing, let next = wp.bearingNextDeg {
            let delta = GeoMath.wrap180(next - prev)
            if delta > 30 { onNavCue?(.turnRight) } else if delta < -30 { onNavCue?(.turnLeft) }
        }
        previousBearing = wp.bearingNextDeg
        offCourse.reset()
        suppressVeerUntil = (lastFix?.timestamp ?? Date().timeIntervalSinceReferenceDate) + turnSettleSeconds
        onWaypointAdvanced?()
        if isLast {
            arrived = true
            isNavigating = false
            instruction = "Arrived: \(wp.say)"
            distanceToNext = 0
            onArrived?()
        } else {
            refreshInstruction()
        }
    }

    private func refreshInstruction() {
        guard let tracker, let wp = tracker.current else { instruction = "Arrived"; return }
        instruction = wp.say
        if let f = lastFix {
            distanceToNext = Int(GeoMath.distanceMeters(f.coordinate, wp.coordinate).rounded())
            targetBearing = tracker.targetBearing(from: f)
            recomputeError()
        } else {
            targetBearing = waypointIndex > 0 ? route?.waypoints[waypointIndex - 1].bearingNextDeg : nil
        }
    }
}
