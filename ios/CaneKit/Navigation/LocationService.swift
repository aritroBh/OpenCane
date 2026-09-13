//
//  LocationService.swift
//  CaneKit
//
//  GPS + compass, reduced to `GeoFix` and a heading in degrees true. Position comes from
//  `CLLocationUpdate.liveUpdates` (async sequence, no delegate); heading from a
//  `CLLocationManager` created on the main actor (its delegate is therefore main-actor).
//
//  Heading rule: while walking (> 0.7 m/s with a valid course) the GPS course is the truth —
//  it is immune to the pole and to the phone's tilt; standing still, the compass is all we have.
//  The caller additionally gates heading on the gyro so a mid-sweep reading is ignored.
//
//  Owner: `AppModel.location` (one instance). Module `navigation-trip` in docs/CODE_REFERENCE.md.
//  Lifecycle (bf03253, "GPS runs from launch, not from route start"): GPS belongs to the
//  FOREGROUND SESSION, not to a route. `start()` at launch (`AppModel.start`), again on every
//  return to `.active` (`scenePhaseChanged`), and — idempotently — from `buildRoute` and
//  `startRouteNow`. `stop()` only when the app goes to the background with no route running
//  (nobody to guide; a receiver on in a pocket is battery). Arrival and Stop leave it running so
//  the GPS pill keeps telling the truth and the next route starts with a warm fix.
//  `requestAuthorization()` at launch right after `start()` (skipped under CANEKIT_UITEST=1:
//  the three-choice alert races the first XCUITest tap).
//  Readers: `onFix` / `onHeading` (AppModel.wireNavigation), `fix` (GuideCard GPS pill,
//  DestinationField, route build, hazard geotag, status / conversation facts), `heading`
//  (auto-recenter), `denied` / `authorizationDenied` / `lastError` (UI and route refusal).
//
//  Threading / isolation: `@MainActor @Observable`; the delegate conformance is `@MainActor`
//  because the manager is created on main. The `liveUpdates` loop runs in a main-actor Task, so
//  `onFix` / `onHeading` always fire on the main actor.
//
//  Key invariants:
//    · `GeoFix.timestamp` is wall clock (`timeIntervalSinceReferenceDate`); NavigationEngine and
//      TurnSettle compare it against `Date()` — keep them on the same clock.
//    · The 0.7 m/s threshold is shared by `ingest` and the compass path; changing one without the
//      other creates a band where no heading is published.
//    · `onHeading` is not gyro-gated here (AppModel does it). Do not add gating in this class.
//  Tests: ⚠ none — no unit test covers CoreLocation; `make e2e` feeds simulated fixes through this
//  class (`xcrun simctl location`). Do not change the 0.7 m/s course rule, `.otherNavigation`, or
//  the background session without a device walk.
//

import CaneKitLogic
import CoreLocation
import Foundation
import Observation

/// CoreLocation adapter: publishes the latest `GeoFix` and a best-estimate heading.
@MainActor
@Observable
final class LocationService: NSObject, @MainActor CLLocationManagerDelegate {

    // MARK: Published

    /// Latest fix (any accuracy; consumers apply their own gates). nil before the first fix and
    /// after `stop()`. Also polled by `AppModel.buildRoute` (≤ 30 × 500 ms) while waiting for a
    /// first fix, read by the GuideCard GPS pill, `DestinationField`, `recordHazard` (< 120 s old)
    /// and the status / conversation facts.
    private(set) var fix: GeoFix?
    /// Compass heading (degrees true, magnetic when true north is unavailable), nil until the first
    /// valid reading. Recorded even while walking, when it is not published as `heading`. Not
    /// cleared by `stop()`.
    private(set) var compassHeading: Double?
    /// Best heading estimate: GPS course when moving, compass otherwise.
    /// Read directly by `AppModel.autoRecenterIfWalkingStraight` (course steadiness).
    private(set) var heading: Double?
    /// True once a location (not a status-only update) has been delivered. Never reset to false
    /// except by a later `authorizationDenied` update.
    private(set) var authorized = false
    /// True when a live update reported `authorizationDenied`. Such an update never comes on a
    /// first route when access is already refused — use `authorizationDenied` for gating.
    /// Read by the GuideCard GPS pill ("Denied") and the status facts.
    private(set) var denied = false
    /// Last CoreLocation error, prefixed "Location: " (live-update loop or heading manager). Shown
    /// on the GuideCard error line when there is no route error. Never cleared.
    private(set) var lastError: String?
    /// True between `start()` and `stop()`; makes `start()` idempotent. The GPS pill reads
    /// "Searching" while running without a fix, "Off" otherwise.
    private(set) var isRunning = false

    /// Called on the main actor for every fix / heading.
    /// `onFix`: every fix, before any gating — idle or navigating (GPS runs from launch).
    /// Installed by `AppModel.wireNavigation()`.
    @ObservationIgnored var onFix: ((GeoFix) -> Void)?
    /// Degrees true, from GPS course (moving) or compass (still). Not gyro-gated here.
    /// Second argument: true when the value is the GPS course (immune to cane sweep and tilt, so
    /// the caller must NOT gyro-gate it), false for the compass (gate it).
    @ObservationIgnored var onHeading: ((Double, Bool) -> Void)?

    // MARK: Private

    /// Heading source and authorization owner (position comes from `liveUpdates`). Created on
    /// main → main-actor delegate.
    @ObservationIgnored private let manager = CLLocationManager()
    /// The `liveUpdates` iteration (a main-actor Task, so `ingest` runs on main); cancelled by `stop()`.
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    /// Keeps location alive if the screen locks mid-walk (needs UIBackgroundModes: location).
    /// Created by `start()`, invalidated by `stop()`.
    @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?

    /// Configures the heading manager: 2° filter, portrait orientation (phone clamped upright on
    /// the cane). Starts nothing.
    override init() {
        super.init()
        manager.delegate = self
        manager.headingFilter = 2
        manager.headingOrientation = .portrait
        // Tear down any orphaned background navigation session from previous runs or crashes.
        let orphan = CLBackgroundActivitySession()
        orphan.invalidate()
    }

    // MARK: Lifecycle

    /// True when the user refused (or a profile restricts) location for OpenCane. Read straight
    /// from CoreLocation, so it is right on the very first route (review: the `denied` flag is only
    /// set by a live update, which never comes when denied). Caller:
    /// `AppModel.announceLocationDenied` (route refusal in `beginRoute` / `buildRoute`).
    var authorizationDenied: Bool {
        manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted
    }

    /// Show the location prompt now (app launch, while a sighted helper is around) instead of
    /// stacking it with the Motion and HealthKit prompts at route start. When-in-use only; a no-op
    /// once the user has answered. Caller: `AppModel.start()` (not under `CANEKIT_UITEST=1`).
    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /// True while actively guiding along a route. Gates `.otherNavigation` and `CLBackgroundActivitySession`.
    @ObservationIgnored private var isNavigating = false

    /// Requests when-in-use authorization (first call prompts) and starts fixes + heading.
    /// Idempotent. Uses default live-updates when idle, switching to `.otherNavigation` only when
    /// actively navigating a route (`setNavigating(true)`).
    /// Called by `AppModel.start()` (launch), `scenePhaseChanged(.active)`, `buildRoute` and
    /// `startRouteNow` — see the file header's lifecycle. A thrown sequence error lands in
    /// `lastError` and ends the loop while `isRunning` stays true (so a later `start()` is a no-op
    /// until `stop()`).
    func start() {
        guard !isRunning else { return }
        isRunning = true
        manager.requestWhenInUseAuthorization()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
        startUpdatesLoop()
    }

    /// Arms or invalidates the CoreLocation background activity session and switches between
    /// `.otherNavigation` (during an active route) and default liveUpdates (while idle).
    /// Scoped strictly to active navigation so the system does not display the persistent
    /// blue navigation pill in the Dynamic Island / status bar while idle in the foreground.
    /// Idempotent. Calls invalidate() before nil to avoid leaking the session assertion.
    func setNavigating(_ navigating: Bool) {
        guard navigating != isNavigating else { return }
        isNavigating = navigating
        if isNavigating {
            if backgroundSession == nil {
                backgroundSession = CLBackgroundActivitySession()
            }
        } else {
            backgroundSession?.invalidate()
            backgroundSession = nil
        }
        if isRunning {
            startUpdatesLoop()
        }
    }

    private func startUpdatesLoop() {
        updatesTask?.cancel()
        let navigating = isNavigating
        updatesTask = Task { [weak self] in
            do {
                let stream = navigating ? CLLocationUpdate.liveUpdates(.otherNavigation) : CLLocationUpdate.liveUpdates()
                for try await update in stream {
                    guard let self, !Task.isCancelled else { return }
                    if update.authorizationDenied {
                        self.denied = true
                        self.authorized = false
                        self.setNavigating(false)
                    }
                    if update.authorizationRequestInProgress { continue }
                    guard let loc = update.location else { continue }
                    self.authorized = true
                    self.ingest(loc)
                }
            } catch {
                self?.lastError = "Location: \(error.localizedDescription)"
            }
        }
    }

    /// Stops fixes and heading, releases the background session and clears `fix`. Called only by
    /// `AppModel.scenePhaseChanged(.background)` when no route is running — not by `stopRoute()`
    /// or arrival any more (bf03253).
    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        manager.stopUpdatingHeading()
        setNavigating(false)
        isRunning = false
        fix = nil                             // a stale fix must not seed the next MapKit route
    }

    // MARK: Ingest

    /// CLLocation → `GeoFix` (accuracy and speed in metres / m/s, −1 = invalid; timestamp on the
    /// wall clock), publish, and use the GPS course as heading when walking faster than 0.7 m/s
    /// (`onHeading(course, true)` — the caller must not gyro-gate it).
    private func ingest(_ loc: CLLocation) {
        let f = GeoFix(coordinate: Coordinate(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude),
                       accuracy: loc.horizontalAccuracy, speed: loc.speed,
                       timestamp: loc.timestamp.timeIntervalSinceReferenceDate)
        fix = f
        onFix?(f)
        // Course-over-ground beats the compass once we are actually walking.
        if loc.speed > 0.7, loc.course >= 0 {
            heading = loc.course
            onHeading?(loc.course, true)
        }
    }

    // MARK: CLLocationManagerDelegate (main actor)

    /// Compass update (≥ 2° change). Always records `compassHeading`; publishes it as `heading`
    /// only when not walking fast enough for a GPS course. True north preferred, magnetic fallback.
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }          // negative = invalid
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        compassHeading = h
        // Only trust the compass when we are not moving fast enough for a GPS course.
        if let f = fix, f.speed > 0.7 { return }
        heading = h
        onHeading?(h, false)
    }

    /// Declines the system figure-8 calibration sheet (it would cover the guide screen).
    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        false   // never pop the figure-8 sheet over the guide screen
    }

    /// Heading-manager failure: recorded in `lastError` for the debug UI only.
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        lastError = "Location: \(error.localizedDescription)"
    }
}
