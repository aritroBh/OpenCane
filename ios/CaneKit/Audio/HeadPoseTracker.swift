//
//  HeadPoseTracker.swift
//  CaneKit
//
//  Head yaw from AirPods Pro via CMHeadphoneMotionManager (no special entitlement; the
//  `isListenerHeadTrackingEnabled` route needs the Head Pose capability a free team cannot get).
//  The headphones' yaw is relative to an arbitrary frame and drifts, so we only ever use the
//  *difference* from a reference captured at "Recenter": the user faces the way they are walking
//  (phone heading) and presses Recenter → headYaw = 0 there.
//
//  Recentering (AGENTS.md deliberate behaviour): besides the manual Recenter button / watch
//  command, AppModel auto-recenters via CaneKitLogic `StraightWalkDetector` (3 fixes > 0.6 m/s —
//  0.9 excluded slow cane walkers entirely — steady course, still head), never within 15 m of a
//  crossing and never on a timer. Until then `HeadYawSelector` feeds the beacon a head yaw of 0 (the
//  stale reference would double-count a turn). The first sample after `start()` also seeds the
//  reference.
//
//  Nod to talk (Step 3 of the nod plan): the same motion stream's *pitch* feeds a CaneKitLogic
//  `HeadNodDetector`; a double nod calls `onDoubleNod`, which AppModel turns into
//  `startVoiceInput()` behind the off-by-default "Nod to talk" option. Pitch is absolute in Core
//  Motion's frame (no reference needed: the detector looks at excursions, not at a level), and the
//  detector is reset in `start()` / `stop()` so a nod half-made before a route cannot pair with one
//  made after. The numbers live in `HeadNodDetector` (⚠ untuned placeholders; HeadNodDetectorTests).
//
//  Threading / isolation: `@MainActor`. Motion samples are delivered with
//  `startDeviceMotionUpdates(to: .main)`, so the handler provably runs on the main queue and
//  `MainActor.assumeIsolated` is legal (hard rule 1); only Sendable values (`Double` yaw, pitch
//  and timestamp, `String` error) are extracted before entering it. Connect/disconnect arrive through the
//  `CMHeadphoneMotionManagerDelegate` on an unspecified thread, so they go through the
//  `nonisolated` `ConnectionRelay`, which hops with `Task { @MainActor in … }`.
//
//  Audio: none. Head motion rides the AirPods' existing A2DP link; this never touches the
//  audio session. Requires `NSMotionUsageDescription` (the prompt appears at route start).
//
//  Owner: `AppModel.head` (one instance). Readers: `AppModel.startTicker` / auto-recenter through
//  `HeadYawSelector` (AirPods win over the front camera's `FaceHeadPose`), GuideCard's head pill
//  (`isConnected`), the status summary, and the `head_nod` trip-log event (`pitchDeg`).
//  Tests: none for this wrapper (CoreMotion, device-only). Pinned in CaneKitLogic:
//  `NavSupportTests` (`StraightWalkDetector`, when `recenter()` auto-fires), `HeadNodDetectorTests`
//  (the double nod), `HeadYawSourcesTests` (source choice). ⚠ The sign convention needs the AirPods
//  device walk: turn the head with the body still and the beacon click moves the other way.
//

import CaneKitLogic
import CoreMotion
import Foundation
import Observation

/// Relative head yaw from AirPods motion, for the beacon's listener orientation. Owned by
/// `AppModel`; started at route start (and on AirPods connect mid-route), stopped with the route.
@MainActor
@Observable
final class HeadPoseTracker {

    /// Degrees, positive = head turned to the right of the recentred direction. nil = no AirPods data.
    /// Range (−180, 180]. Read by AppModel's 10 Hz ticker into `BeaconEngine.setHeadYaw`.
    private(set) var headYawDeg: Double?
    /// Latest head pitch, degrees, straight from `CMAttitude.pitch` (Core Motion's frame, sign
    /// unmeasured on AirPods — see the ponytail note in `HeadNodDetector`). nil = no AirPods data.
    /// Written for the trip log (`head_nod` events) so the nod thresholds can be re-measured from
    /// real walks; not used for the beacon.
    private(set) var pitchDeg: Double?
    /// Fired once per double nod (`HeadNodDetector.update` returned true), on the main actor.
    /// `AppModel` installs it and, when "Nod to talk" is on, starts voice input. Only fires while
    /// motion is `active`, i.e. while a route is running.
    /// ⚠ Gesture pinned by HeadNodDetectorTests (`doubleNodFiresOnceOnTheSecondNod`,
    /// `walkingSwayIsSilent`, `refractoryHoldsAfterAFire`, …).
    var onDoubleNod: (() -> Void)?
    /// AirPods motion is flowing (a sample arrived, or the delegate reported connect). Gates
    /// auto-recenter and the "Head tracked" pill; false after disconnect or `stop()`.
    private(set) var isConnected = false
    /// This device can do headphone motion at all (evaluated once at init from a throwaway
    /// manager); says nothing about whether AirPods are currently connected.
    private(set) var isAvailable = CMHeadphoneMotionManager().isDeviceMotionAvailable
    /// Last Core Motion error text (e.g. motion permission denied); never cleared.
    private(set) var lastError: String?

    /// The one headphone motion manager; its delegate is `relay`.
    @ObservationIgnored private let manager = CMHeadphoneMotionManager()
    /// Strong reference to the connection delegate (the manager holds it weakly).
    @ObservationIgnored private let relay = ConnectionRelay()
    /// Latest raw AirPods yaw, radians, in Core Motion's arbitrary drifting frame.
    @ObservationIgnored private var rawYaw: Double?
    /// Raw yaw (radians) that counts as "straight ahead"; nil = seed from the next sample.
    @ObservationIgnored private var referenceYaw: Double?
    /// Samples already queued on main when `stop()` runs must not re-seed the reference.
    @ObservationIgnored private var active = false
    /// The double-nod state machine (CaneKitLogic). Fed every motion sample's pitch with the
    /// sample's own `timestamp` (seconds since boot, monotonic — the detector only needs one
    /// consistent clock). Reset in `start()` and `stop()`.
    @ObservationIgnored private var nod = HeadNodDetector()
    /// Invalidates connection and motion callbacks queued by Core Motion before `stop()`.
    /// Without this, a late `didConnect` task can mark a newly stopped tracker connected again.
    @ObservationIgnored private var lifecycleGeneration: UInt64 = 0

    /// Starts with no data and no reference; nothing runs until `start()`.
    init() {}

    /// Begin head tracking: clear the reference (the first sample becomes forward), install the
    /// connection relay and start motion updates on the main queue. No-op when unsupported or
    /// already active. Callers: `AppModel.startRouteNow` (route start), and `wireAudioRoute` when
    /// headphones connect mid-route (followed by a pending recenter).
    /// ⚠ Open (CHANGELOG Step 34 audit, "still open"): route start calls this without checking
    /// that headphones are connected (`AudioRouteMonitor.headphonesConnected`).
    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        active = true
        referenceYaw = nil
        nod.reset()                 // a half-made nod from before the route must not pair up
        relay.onConnect = { [weak self] connected in
            Task { @MainActor [weak self] in
                guard let self, self.active, self.lifecycleGeneration == generation else { return }
                self.isConnected = connected
                if !connected { self.headYawDeg = nil; self.rawYaw = nil }
            }
        }
        manager.delegate = relay
        // Deliver on main: the closure is @Sendable but provably on the main queue.
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            // Sendable scalars only, extracted before the isolated block (hard rule 1).
            let yaw = motion?.attitude.yaw
            let pitch = motion?.attitude.pitch
            let timestamp = motion?.timestamp
            let message = error?.localizedDescription
            MainActor.assumeIsolated {
                guard let self, self.active, self.lifecycleGeneration == generation else { return }
                if let message { self.lastError = message }
                guard let yaw else { return }
                self.isConnected = true
                self.rawYaw = yaw
                if self.referenceYaw == nil { self.referenceYaw = yaw }   // first sample = forward
                self.headYawDeg = Self.wrap180((self.referenceYaw! - yaw) * 180 / .pi)
                if let pitch, let timestamp {
                    let deg = pitch * 180 / .pi
                    self.pitchDeg = deg
                    if self.nod.update(pitchDeg: deg, now: timestamp) { self.onDoubleNod?() }
                }
            }
        }
    }

    /// Stop updates and forget everything (yaw, pitch, reference, connection, pending nod) so the
    /// UI never shows stale head tracking. Callers: `AppModel.stopRoute`, `endRouteQuietly`, the
    /// `nav.onArrived` handler and `wireAudioRoute` when headphones disconnect.
    func stop() {
        lifecycleGeneration &+= 1
        active = false
        isConnected = false             // the pill must not say "Head tracked" with no data
        manager.stopDeviceMotionUpdates()
        headYawDeg = nil
        pitchDeg = nil
        rawYaw = nil
        referenceYaw = nil          // a fresh start re-zeroes on the first sample
        nod.reset()
    }

    /// Current head direction becomes "straight ahead".
    /// Without data (`rawYaw == nil`) it clears the reference, so the next sample seeds it.
    /// Callers: `AppModel.recenter()` (button / watch) and `autoRecenterIfWalkingStraight`.
    func recenter() {
        referenceYaw = rawYaw
        headYawDeg = rawYaw == nil ? nil : 0
    }

    /// Wrap degrees into (−180, 180].
    private static func wrap180(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }
}

/// `CMHeadphoneMotionManagerDelegate` relay. Core Motion calls it on a thread of its choosing,
/// so it is `nonisolated` and touches no main-actor state; it forwards a `Bool` to `onConnect`,
/// whose closure (installed by `HeadPoseTracker.start()`) hops to the main actor.
/// `@unchecked Sendable`: `onConnect` is only written on main in `start()` (first before the
/// relay becomes the delegate; later starts re-assign an equivalent closure) and only read here.
nonisolated private final class ConnectionRelay: NSObject, CMHeadphoneMotionManagerDelegate, @unchecked Sendable {
    /// Receives true on connect, false on disconnect (off main; the closure hops).
    var onConnect: (@Sendable (Bool) -> Void)?
    /// AirPods motion became available → `onConnect(true)`.
    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) { onConnect?(true) }
    /// AirPods removed / disconnected → `onConnect(false)`; the tracker clears its yaw.
    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) { onConnect?(false) }
}
