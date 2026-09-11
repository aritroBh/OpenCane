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

import CaneKitLogic
import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class LocationService: NSObject, @MainActor CLLocationManagerDelegate {

    // MARK: Published

    private(set) var fix: GeoFix?
    /// Compass heading (degrees true), nil until the first reading.
    private(set) var compassHeading: Double?
    /// Best heading estimate: GPS course when moving, compass otherwise.
    private(set) var heading: Double?
    private(set) var authorized = false
    private(set) var denied = false
    private(set) var lastError: String?
    private(set) var isRunning = false

    /// Called on the main actor for every fix / heading.
    @ObservationIgnored var onFix: ((GeoFix) -> Void)?
    @ObservationIgnored var onHeading: ((Double) -> Void)?

    // MARK: Private

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?

    override init() {
        super.init()
        manager.delegate = self
        manager.headingFilter = 2
        manager.headingOrientation = .portrait
    }

    // MARK: Lifecycle

    /// Show the location prompt now (app launch, while a sighted helper is around) instead of
    /// stacking it with the Motion and HealthKit prompts at route start.
    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /// Requests when-in-use authorization (first call prompts) and starts fixes + heading.
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

    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        manager.stopUpdatingHeading()
        backgroundSession?.invalidate()
        backgroundSession = nil
        isRunning = false
    }

    // MARK: Ingest

    private func ingest(_ loc: CLLocation) {
        let f = GeoFix(coordinate: Coordinate(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude),
                       accuracy: loc.horizontalAccuracy, speed: loc.speed,
                       timestamp: loc.timestamp.timeIntervalSinceReferenceDate)
        fix = f
        onFix?(f)
        // Course-over-ground beats the compass once we are actually walking.
        if loc.speed > 0.7, loc.course >= 0 {
            heading = loc.course
            onHeading?(loc.course)
        }
    }

    // MARK: CLLocationManagerDelegate (main actor)

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }          // negative = invalid
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        compassHeading = h
        // Only trust the compass when we are not moving fast enough for a GPS course.
        if let f = fix, f.speed > 0.7 { return }
        heading = h
        onHeading?(h)
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        false   // never pop the figure-8 sheet over the guide screen
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        lastError = "Location: \(error.localizedDescription)"
    }
}
