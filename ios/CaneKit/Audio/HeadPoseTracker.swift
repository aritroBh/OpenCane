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
//  command, AppModel auto-recenters via CaneKitLogic `StraightWalkDetector` (3 fixes > 0.9 m/s,
//  steady course, still head), never within 15 m of a crossing and never on a timer. Until then
//  AppModel feeds the beacon a head yaw of 0 (the stale reference would double-count a turn).
//  The first sample after `start()` also seeds the reference.
//
//  Threading / isolation: `@MainActor`. Motion samples are delivered with
//  `startDeviceMotionUpdates(to: .main)`, so the handler provably runs on the main queue and
//  `MainActor.assumeIsolated` is legal (hard rule 1); only Sendable values (`Double` yaw,
//  `String` error) are extracted before entering it. Connect/disconnect arrive through the
//  `CMHeadphoneMotionManagerDelegate` on an unspecified thread, so they go through the
//  `nonisolated` `ConnectionRelay`, which hops with `Task { @MainActor in … }`.
//
//  Audio: none. Head motion rides the AirPods' existing A2DP link; this never touches the
//  audio session. Requires `NSMotionUsageDescription` (the prompt appears at route start).
//

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

    init() {}

    /// Begin head tracking: clear the reference (the first sample becomes forward), install the
    /// connection relay and start motion updates on the main queue. No-op when unsupported or
    /// already active. Callers: `AppModel.beginRoute`, and `wireAudioRoute` when AirPods connect
    /// mid-route (followed by a pending recenter).
    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        active = true
        referenceYaw = nil
        relay.onConnect = { [weak self] connected in
            Task { @MainActor [weak self] in
                self?.isConnected = connected
                if !connected { self?.headYawDeg = nil; self?.rawYaw = nil }
            }
        }
        manager.delegate = relay
        // Deliver on main: the closure is @Sendable but provably on the main queue.
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            let yaw = motion?.attitude.yaw
            let message = error?.localizedDescription
            MainActor.assumeIsolated {
                guard let self, self.active else { return }
                if let message { self.lastError = message }
                guard let yaw else { return }
                self.isConnected = true
                self.rawYaw = yaw
                if self.referenceYaw == nil { self.referenceYaw = yaw }   // first sample = forward
                self.headYawDeg = Self.wrap180((self.referenceYaw! - yaw) * 180 / .pi)
            }
        }
    }

    /// Stop updates and forget everything (yaw, reference, connection) so the UI never shows
    /// stale head tracking. Callers: `AppModel.stopRoute` and arrival.
    func stop() {
        active = false
        isConnected = false             // the pill must not say "Head tracked" with no data
        manager.stopDeviceMotionUpdates()
        headYawDeg = nil
        rawYaw = nil
        referenceYaw = nil          // a fresh start re-zeroes on the first sample
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
