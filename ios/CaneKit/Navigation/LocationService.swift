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
//  `requestAuthorization()` at launch (AppModel.start, skipped under CANEKIT_UITEST=1);
//  `start()` at route start / MapKit route build; `stop()` at AppModel.stopRoute.
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
//  ⚠ Do not change the 0.7 m/s course rule, `.otherNavigation`, or the background session
//  without a device walk — no unit test covers CoreLocation.
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

    /// Latest fix (any accuracy; consumers apply their own gates). Also polled by
    /// `AppModel.startMapKitRoute()` while waiting for a first fix.
    private(set) var fix: GeoFix?
    /// Compass heading (degrees true), nil until the first reading.
    private(set) var compassHeading: Double?
    /// Best heading estimate: GPS course when moving, compass otherwise.
    /// Read directly by `AppModel.autoRecenterIfWalkingStraight` (course steadiness).
    private(set) var heading: Double?
    /// True once a location update has been delivered.
    private(set) var authorized = false
    /// True when an update reported `authorizationDenied`.
    private(set) var denied = false
    /// Last CoreLocation error, prefixed "Location: ", for the debug UI.
    private(set) var lastError: String?
    /// True between `start()` and `stop()`; makes `start()` idempotent.
    private(set) var isRunning = false

    /// Called on the main actor for every fix / heading.
    /// `onFix`: every fix, before any gating. Installed by `AppModel.wireNavigation()`.
    @ObservationIgnored var onFix: ((GeoFix) -> Void)?
    /// Degrees true, from GPS course (moving) or compass (still). Not gyro-gated here.
    /// Second argument: true when the value is the GPS course (immune to cane sweep and tilt, so
    /// the caller must NOT gyro-gate it), false for the compass (gate it).
    @ObservationIgnored var onHeading: ((Double, Bool) -> Void)?

    // MARK: Private

    /// Heading source only (position comes from `liveUpdates`). Created on main → main-actor delegate.
    @ObservationIgnored private let manager = CLLocationManager()
    /// The `liveUpdates` iteration; cancelled by `stop()`.
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    /// Keeps location alive if the screen locks mid-walk (needs UIBackgroundModes: location).
    @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?

    /// Configures the heading manager: 2° filter, portrait orientation (phone clamped upright on
    /// the cane). Starts nothing.
    override init() {
        super.init()
        manager.delegate = self
        manager.headingFilter = 2
        manager.headingOrientation = .portrait
    }

    // MARK: Lifecycle

    /// Show the location prompt now (app launch, while a sighted helper is around) instead of
    /// stacking it with the Motion and HealthKit prompts at route start.
    /// True when the user refused (or a profile restricts) location for OpenCane. Read straight
    /// from CoreLocation, so it is right on the very first route (review: the `denied` flag is only
    /// set by a live update, which never comes when denied).
    var authorizationDenied: Bool {
        manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /// Requests when-in-use authorization (first call prompts) and starts fixes + heading.
    /// Idempotent. Uses the `.otherNavigation` live-update configuration (non-automotive guidance).
    /// Called by `AppModel.beginRoute()` and `AppModel.startMapKitRoute()`.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        manager.requestWhenInUseAuthorization()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
        // Keeps location alive if the screen locks mid-walk (UIBackgroundModes: location).
        backgroundSession = CLBackgroundActivitySession()
        updatesTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                    guard let self, !Task.isCancelled else { return }
                    if update.authorizationDenied { self.denied = true; self.authorized = false }
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

    /// Stops fixes and heading and releases the background session. Called by `AppModel.stopRoute()`.
    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        manager.stopUpdatingHeading()
        backgroundSession?.invalidate()
        backgroundSession = nil
        isRunning = false
        fix = nil                             // a stale fix must not seed the next MapKit route
    }

    // MARK: Ingest

    /// CLLocation → `GeoFix` (accuracy and speed in metres / m/s, −1 = invalid), publish, and use
    /// the GPS course as heading when walking faster than 0.7 m/s.
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
