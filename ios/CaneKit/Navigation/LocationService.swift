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
    /// The route's explicit Always session (iOS 18+ `CLServiceSession(authorization: .always)`,
    /// Codex review, Step 47): on the modern API an app's *implicit* session is When In Use, so an
    /// Always-authorized app still needs this to be sure of background delivery without a
    /// `CLBackgroundActivitySession`. Created by `setNavigating(true)`, invalidated by
    /// `setNavigating(false)`; its diagnostics are logged through `onDiagnostic`. The background
    /// activity session stays armed until the status reports Always (`reconcileBackgroundSession`).
    @ObservationIgnored private var alwaysSession: CLServiceSession?
    /// Reads `alwaysSession.diagnostics`; cancelled with the session.
    @ObservationIgnored private var alwaysDiagnosticsTask: Task<Void, Never>?
    /// CoreLocation diagnostics worth a trip-log line (`location_diag {source, flags}`): the update
    /// stream's `authorizationDenied` / `authorizationRestricted` / `insufficientlyInUse` /
    /// `serviceSessionRequired` / `locationUnavailable`, and the Always session's own flags. A
    /// walker must never follow stale guidance in silence (Codex review). Installed by
    /// `AppModel.wireNavigation`.
    @ObservationIgnored var onDiagnostic: ((String, [String]) -> Void)?
    /// Last diagnostic flags reported by the update stream, deduplicated so a persisting state logs once.
    @ObservationIgnored private var lastUpdateFlags: [String] = []

    /// Keeps location alive if the screen locks mid-walk (needs UIBackgroundModes: location).
    /// Armed by `setNavigating(true)` (an active route only, Step 40) **and only without Always
    /// authorization** (`reconcileBackgroundSession`, Step 47); released by `setNavigating(false)` —
    /// which `stopRoute`, arrival, a denied authorization and `stop()` all call — or the moment
    /// Always is granted. While it is armed and the app is in the background, iOS draws its blue
    /// location pill in the Dynamic Island and demotes the Live Activity to the minimal bubble;
    /// that pill is this session's, not the widget's.
    @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?

    /// Configures the heading manager: 2° filter, portrait orientation (phone clamped upright on
    /// the cane). Starts nothing.
    override init() {
        super.init()
        manager.delegate = self
        manager.headingFilter = 2
        manager.headingOrientation = .portrait
        manager.showsBackgroundLocationIndicator = false
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

    /// True while a `CLBackgroundActivitySession` is armed — i.e. the route runs on When-In-Use
    /// authorization and iOS is drawing its blue location pill in the Dynamic Island (which demotes
    /// the Live Activity to the minimal bubble). False with Always authorization, where background
    /// fixes need no session and the island belongs to OpenCane. Read by the Scene engine / trip log.
    private(set) var backgroundSessionArmed = false

    /// "always" / "whenInUse" / "denied" / "restricted" / "notDetermined", for the trip log and the UI.
    var authorizationName: String {
        switch manager.authorizationStatus {
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "whenInUse"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    /// Called on the main actor whenever CoreLocation reports an authorization change, with
    /// `authorizationName` and whether a background session is now armed. Installed by
    /// `AppModel.wireNavigation` (logs `location_auth`).
    @ObservationIgnored var onAuthorizationChange: ((String, Bool) -> Void)?

    /// Ask for Always on top of When In Use (Step 47). Why: a route runs with the screen locked;
    /// a When-In-Use app keeps receiving fixes only through a `CLBackgroundActivitySession`, and
    /// that session makes iOS draw the blue location pill in the Dynamic Island — which is what
    /// pushed OpenCane's own Live Activity into the minimal bubble on the owner's phone (pictures
    /// 2026-09-12 21:48: a blue arrow in the pill, our head-height glance in a detached circle).
    /// Apple Maps and Google Maps own the island because they hold Always. iOS shows the upgrade
    /// prompt once (and may grant provisional Always first); a walker who declines keeps today's
    /// behaviour (session + pill). Idempotent; a no-op once answered. Caller: `AppModel.startRouteNow`
    /// (not under `CANEKIT_UITEST=1`: the prompt would race the first XCUITest tap).
    func requestAlwaysAuthorization() {
        alwaysWanted = true
        guard manager.authorizationStatus == .authorizedWhenInUse else { return }   // else: deferred below
        manager.requestAlwaysAuthorization()
    }

    /// A route asked for Always while the status was still `.notDetermined` (the launch prompt not
    /// yet answered — a first route right after install). `locationManagerDidChangeAuthorization`
    /// finishes the request the moment When In Use is granted (Muse review, Step 47), so the first
    /// walk gets the upgrade prompt, not the second.
    @ObservationIgnored private var alwaysWanted = false

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
        // Deliberately NOT `= navigating` (Step 47): the blue location pill iOS draws around the
        // Dynamic Island while a route runs in the background comes from the
        // `CLBackgroundActivitySession` itself — that indicator is what lets a When-In-Use app
        // keep receiving fixes in the background (WWDC23 "Discover streamlined location updates")
        // and no flag on our side removes it. Leaving this manager flag off keeps the legacy
        // indicator path out of the picture so there is exactly one system pill, never two; it is
        // the OS's, not the Live Activity's, and docs/design.md §6.7 says so for the spotter.
        manager.showsBackgroundLocationIndicator = false
        reconcileAlwaysSession()
        reconcileBackgroundSession()
        if isRunning {
            startUpdatesLoop()
        }
    }

    /// Hold an explicit `.always` service session for the route, and none while idle (an idle app
    /// must not ask for background location). Its diagnostics stream tells the trip log why Always
    /// is not in effect (`alwaysAuthorizationDenied`, `insufficientlyInUse`, …).
    private func reconcileAlwaysSession() {
        if isNavigating, alwaysSession == nil {
            let session = CLServiceSession(authorization: .always)
            alwaysSession = session
            alwaysDiagnosticsTask = Task { [weak self] in
                // The stream ends by throwing when the session is invalidated; that is not a diagnostic.
                do {
                    for try await d in session.diagnostics {
                        guard let self, !Task.isCancelled else { return }
                        var flags: [String] = []
                        if d.authorizationDenied { flags.append("authorizationDenied") }
                        if d.authorizationDeniedGlobally { flags.append("authorizationDeniedGlobally") }
                        if d.authorizationRestricted { flags.append("authorizationRestricted") }
                        if d.insufficientlyInUse { flags.append("insufficientlyInUse") }
                        if d.fullAccuracyDenied { flags.append("fullAccuracyDenied") }
                        if d.alwaysAuthorizationDenied { flags.append("alwaysAuthorizationDenied") }
                        if d.authorizationRequestInProgress { flags.append("authorizationRequestInProgress") }
                        self.onDiagnostic?("always_session", flags)
                    }
                } catch {}
            }
        } else if !isNavigating, let session = alwaysSession {
            alwaysDiagnosticsTask?.cancel()
            alwaysDiagnosticsTask = nil
            session.invalidate()
            alwaysSession = nil
        }
    }

    /// Arm the background session only when a route runs AND the app lacks Always authorization.
    /// With Always, `liveUpdates` keeps flowing in the background on the `location` background
    /// mode alone, and no session means no blue pill — the Live Activity keeps the island (Step 47).
    /// Re-run on every authorization change, so the Always grant mid-route drops the session (and
    /// the pill) at once, and a downgrade re-arms it so the walk never loses GPS. Idempotent.
    private func reconcileBackgroundSession() {
        // Denied / restricted get no session: it could deliver nothing and would only keep the
        // pill (and a misleading `background_session: true`) alive (Muse review).
        let status = manager.authorizationStatus
        let wantSession = isNavigating && (status == .authorizedWhenInUse || status == .notDetermined)
        if wantSession, backgroundSession == nil {
            backgroundSession = CLBackgroundActivitySession()
        } else if !wantSession, let session = backgroundSession {
            session.invalidate()
            backgroundSession = nil
        }
        backgroundSessionArmed = backgroundSession != nil
    }

    /// Authorization changed (the launch prompt, the Always upgrade prompt, a Settings change):
    /// re-decide the background session and tell the app so the trip log records it.
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        reconcileBackgroundSession()
        onAuthorizationChange?(authorizationName, backgroundSessionArmed)
        if alwaysWanted, isNavigating, manager.authorizationStatus == .authorizedWhenInUse {
            alwaysWanted = false
            manager.requestAlwaysAuthorization()
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
                    // Diagnostics first: a stopped stream must never be silent (Codex review).
                    var flags: [String] = []
                    if update.authorizationDenied { flags.append("authorizationDenied") }
                    if update.authorizationDeniedGlobally { flags.append("authorizationDeniedGlobally") }
                    if update.authorizationRestricted { flags.append("authorizationRestricted") }
                    if update.insufficientlyInUse { flags.append("insufficientlyInUse") }
                    if update.serviceSessionRequired { flags.append("serviceSessionRequired") }
                    if update.locationUnavailable { flags.append("locationUnavailable") }
                    if update.accuracyLimited { flags.append("accuracyLimited") }
                    if flags != self.lastUpdateFlags {
                        self.lastUpdateFlags = flags
                        if !flags.isEmpty { self.onDiagnostic?("updates", flags) }
                    }
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

    /// Ingests a simulated or replay fix and heading directly into the pipeline, bypassing CoreLocation.
    /// Used by walk simulation on real devices and deterministic testing.
    func ingest(fix f: GeoFix, course: Double? = nil) {
        fix = f
        onFix?(f)
        if let c = course, f.speed > 0.7, c >= 0 {
            heading = c
            onHeading?(c, true)
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
