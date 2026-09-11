//
//  PhoneWatchLink.swift
//  CaneKit
//
//  Phone side of WatchConnectivity. Sends navigation cues (turn / crossing / arrived), mirrored
//  obstacle cues when the phone's haptic engine is down (or the user asked for it), and a status
//  line for the watch face; receives Next / Describe / Recenter from the watch.
//
//  Reachability: `sendMessage` only works while the watch app is frontmost or running its
//  workout session. Cues are ephemeral, so an unreachable watch simply drops them; the status
//  line goes through `updateApplicationContext`, which is delivered when the watch wakes.
//

import CaneKitLogic
import Foundation
import Observation
import WatchConnectivity

@MainActor
@Observable
final class PhoneWatchLink {

    // MARK: Published

    private(set) var isSupported = WCSession.isSupported()
    private(set) var isPaired = false
    private(set) var isWatchAppInstalled = false
    /// True while the watch app can receive `sendMessage` right now.
    private(set) var isReachable = false
    private(set) var lastError: String?
    private(set) var messagesSent = 0
    private(set) var lastReceived: WatchToPhone?

    /// Called on the main actor for every command from the watch.
    @ObservationIgnored var onCommand: ((WatchToPhone) -> Void)?

    // MARK: Private

    @ObservationIgnored private let relay = SessionRelay()
    @ObservationIgnored private var lastStatus: PhoneToWatch?
    /// Per-kind throttle so a chatty obstacle mirror never floods the Bluetooth link.
    @ObservationIgnored private var lastObstacleSent: [CueKind: TimeInterval] = [:]

    init() {}

    // MARK: Lifecycle

    func activate() {
        guard isSupported else { return }
        relay.onStateChange = { [weak self] paired, installed, reachable, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPaired = paired
                self.isWatchAppInstalled = installed
                self.isReachable = reachable
                if let error { self.lastError = error }
            }
        }
        relay.onCommand = { [weak self] cmd in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastReceived = cmd
                self.onCommand?(cmd)
            }
        }
        let session = WCSession.default
        session.delegate = relay
        session.activate()
    }

    // MARK: Sending

    /// Turn / crossing / arrived: sent once, dropped if the watch is unreachable.
    func send(nav cue: NavCue) {
        send(.nav(cue))
    }

    /// Mirrored obstacle cue (fallback). Throttled to one per kind per second.
    func send(obstacle kind: CueKind, now: TimeInterval) {
        if now - (lastObstacleSent[kind] ?? -.infinity) < 1.0 { return }
        lastObstacleSent[kind] = now
        send(.obstacle(kind))
    }

    /// Current instruction + distance for the watch face. Uses application context so the
    /// latest value survives the watch being asleep; also pushed live when reachable.
    func send(status instruction: String, distanceM: Int) {
        let msg = PhoneToWatch.status(instruction: instruction, distanceM: distanceM)
        if case .status(let i, let d)? = lastStatus, i == instruction, abs(d - distanceM) < 5 { return }
        lastStatus = msg
        guard let dict = try? WatchEnvelope.encode(msg) else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        try? session.updateApplicationContext(dict)
        if session.isReachable { deliver(dict, session: session) }
    }

    private func send(_ msg: PhoneToWatch) {
        let session = WCSession.default
        guard isSupported, session.activationState == .activated, session.isReachable,
              let dict = try? WatchEnvelope.encode(msg) else { return }
        deliver(dict, session: session)
    }

    private func deliver(_ dict: [String: Any], session: WCSession) {
        session.sendMessage(dict, replyHandler: nil) { [weak self] error in
            let text = error.localizedDescription
            Task { @MainActor [weak self] in self?.lastError = text }
        }
        messagesSent += 1
        lastError = nil
    }
}

/// WCSessionDelegate callbacks arrive on a background queue. Decode into Sendable values here,
/// then hop to the main actor.
nonisolated private final class SessionRelay: NSObject, WCSessionDelegate, @unchecked Sendable {
    var onStateChange: (@Sendable (_ paired: Bool, _ installed: Bool, _ reachable: Bool, _ error: String?) -> Void)?
    var onCommand: (@Sendable (WatchToPhone) -> Void)?

    private func publish(_ session: WCSession, error: Error? = nil) {
        onStateChange?(session.isPaired, session.isWatchAppInstalled, session.isReachable,
                       error?.localizedDescription)
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        publish(session, error: error)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The user switched watches: re-activate for the new one.
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        publish(session)
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        publish(session)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let cmd = WatchEnvelope.decodeWatchToPhone(message) { onCommand?(cmd) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let cmd = WatchEnvelope.decodeWatchToPhone(message)
        if let cmd { onCommand?(cmd) }
        replyHandler(["ok": cmd != nil])        // false = watch is newer than this phone build
    }
}
