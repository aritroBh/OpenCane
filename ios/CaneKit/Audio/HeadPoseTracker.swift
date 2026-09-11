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

import CoreMotion
import Foundation
import Observation

@MainActor
@Observable
final class HeadPoseTracker {

    /// Degrees, positive = head turned to the right of the recentred direction. nil = no AirPods data.
    private(set) var headYawDeg: Double?
    private(set) var isConnected = false
    private(set) var isAvailable = CMHeadphoneMotionManager().isDeviceMotionAvailable
    private(set) var lastError: String?

    @ObservationIgnored private let manager = CMHeadphoneMotionManager()
    @ObservationIgnored private let relay = ConnectionRelay()
    @ObservationIgnored private var rawYaw: Double?
    @ObservationIgnored private var referenceYaw: Double?
    /// Samples already queued on main when `stop()` runs must not re-seed the reference.
    @ObservationIgnored private var active = false

    init() {}

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

    func stop() {
        active = false
        isConnected = false             // the pill must not say "Head tracked" with no data
        manager.stopDeviceMotionUpdates()
        headYawDeg = nil
        rawYaw = nil
        referenceYaw = nil          // a fresh start re-zeroes on the first sample
    }

    /// Current head direction becomes "straight ahead".
    func recenter() {
        referenceYaw = rawYaw
        headYawDeg = rawYaw == nil ? nil : 0
    }

    private static func wrap180(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }
}

nonisolated private final class ConnectionRelay: NSObject, CMHeadphoneMotionManagerDelegate, @unchecked Sendable {
    var onConnect: (@Sendable (Bool) -> Void)?
    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) { onConnect?(true) }
    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) { onConnect?(false) }
}
