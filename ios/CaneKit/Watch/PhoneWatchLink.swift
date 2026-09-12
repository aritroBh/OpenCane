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
//  Wire format: `WatchEnvelope` (CaneKitLogic, unit-tested) wraps `PhoneToWatch` /
//  `WatchToPhone` as JSON `Data` under key "m" in the `[String: Any]` dictionary WatchConnectivity
//  carries; this file is transport only.
//  Deliberate behaviours (AGENTS.md): silencing phone haptics routes obstacle cues here (and to
//  speech); a watch command this build cannot decode is answered `["ok": false]` so the watch
//  can say "phone app too old" with its `.retry` haptic.
//
//  Threading / isolation: `PhoneWatchLink` is `@MainActor`; every send and every published
//  property is main-only. `WCSessionDelegate` callbacks arrive on a WatchConnectivity
//  background queue, so the delegate is the `nonisolated` `SessionRelay` below: it decodes
//  into Sendable values (`Bool`s, `String?`, `WatchToPhone`) on that queue and the closures
//  installed by `activate()` hop with `Task { @MainActor in … }` (AGENTS.md hard rule 1).
//  `sendMessage`'s error handler also runs off main and hops the same way.
//
//  Owner: `AppModel.watch` (created eagerly; `onCommand` set and `activate()` called in
//  `AppModel.start()`). Senders: `nav.onNavCue` → `send(nav:)`; `AppModel.handle(report)` and
//  `groundHazardFound` → `send(obstacle:now:)`; `pushStatusToWatch()` plus the route-readiness
//  lines ("Obstacle detection warming up" / "not ready" / "Route start canceled", distance -1) →
//  `send(status:distanceM:)`; the Watch card's test buttons → `AppModel.watchTest` → `send(nav:)`.
//  Readers: `WatchCard` (pill, last command, error), `AppModel.announceChannels` (paired but not
//  reachable), status and conversation facts (`isReachable`).
//  Tests: the wire format only (`WatchMessageTests`: `phoneToWatchRoundTrips`,
//  `watchToPhoneRoundTrips`, `unknownPayloadsDecodeToNil`). Reachability, throttles and the reply
//  are device-tested (CHANGELOG "Step 5 — Watch").
//

import CaneKitLogic
import Foundation
import Observation
import WatchConnectivity

/// Phone end of the watch link: publishes pairing / reachability, sends nav cues, mirrored
/// obstacle cues and status, and forwards watch commands to `AppModel`. Owned by `AppModel`.
@MainActor
@Observable
final class PhoneWatchLink {

    // MARK: Published

    /// Device supports WatchConnectivity (false on iPad). Evaluated once at init; WatchCard shows
    /// "Unsupported" when false.
    private(set) var isSupported = WCSession.isSupported()
    /// A watch is paired with this phone (from the last activation / state callback). False until
    /// activation completes.
    private(set) var isPaired = false
    /// The OpenCane watch app (target CaneKitWatch) is installed on the paired watch.
    private(set) var isWatchAppInstalled = false
    /// True while the watch app can receive `sendMessage` right now.
    /// Mirrors `WCSession.isReachable` as of the last relay callback; AppModel uses it to warn
    /// "Watch not reachable" at route start and to decide whether haptics can fall back to the wrist.
    private(set) var isReachable = false
    /// Last activation or send error, shown on the Watch card; cleared synchronously by the next
    /// `deliver` (so a failure that arrives after a later send can reappear). Not cleared by a
    /// successful activation.
    private(set) var lastError: String?
    /// Count of `sendMessage` calls attempted (debug; counts attempts, not deliveries). No view
    /// reads it today.
    private(set) var messagesSent = 0
    /// Most recent decoded command from the watch; shown on the Watch card as the last command.
    private(set) var lastReceived: WatchToPhone?

    /// Called on the main actor for every command from the watch.
    /// Set by `AppModel.start()` to `handleWatchCommand` (`repeatLast`, `nextWaypoint`,
    /// `describe`, `recenter`).
    @ObservationIgnored var onCommand: ((WatchToPhone) -> Void)?

    // MARK: Private

    /// The session delegate (WCSession holds it weakly, so it is retained here).
    @ObservationIgnored private let relay = SessionRelay()
    /// Last status pushed, for de-duplication in `send(status:distanceM:)`.
    @ObservationIgnored private var lastStatus: PhoneToWatch?
    /// Per-kind throttle so a chatty obstacle mirror never floods the Bluetooth link.
    /// Values are the caller's clock (depth report timestamps, seconds — the ARKit clock, the same
    /// one `CueDecider` uses, so the 1 s throttle lines up with its repeat rate).
    @ObservationIgnored private var lastObstacleSent: [CueKind: TimeInterval] = [:]

    /// Inert until `activate()`: no session delegate, no activation.
    init() {}

    // MARK: Lifecycle

    /// Install the relay's main-actor hop closures, make it the `WCSession` delegate and
    /// activate. The closures are set *before* the delegate so no early callback is lost.
    /// No-op when WatchConnectivity is unsupported. Called once by `AppModel.start()`.
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

    /// Turn / crossing / arrived (and turnLeft / turnRight for a veer): sent once, dropped if the
    /// watch is unreachable — a late turn tap would be wrong, so nothing is queued.
    /// Callers: `NavigationEngine.onNavCue` (wired in AppModel) and the watch test buttons.
    func send(nav cue: NavCue) {
        send(.nav(cue))
    }

    /// Mirrored obstacle cue (fallback). Throttled to one per kind per second.
    /// Callers: `AppModel.handle` and `AppModel.groundHazardFound` (as `.center`), when the phone
    /// cannot buzz (engine down or silenced) or the user enabled "Mirror obstacle cues to the watch"
    /// (`fallbackToWatch`). `now` is the depth report timestamp (s). The throttle stamp is taken
    /// before the reachability check, so a cue dropped as unreachable still uses up that second.
    func send(obstacle kind: CueKind, now: TimeInterval) {
        if now - (lastObstacleSent[kind] ?? -.infinity) < 1.0 { return }
        lastObstacleSent[kind] = now
        send(.obstacle(kind))
    }

    /// Current instruction + distance for the watch face. Uses application context so the
    /// latest value survives the watch being asleep; also pushed live when reachable.
    /// De-duplicated: same instruction and < 5 m distance change is skipped (≈ one message per
    /// 5 s of walking). `distanceM` is metres, -1 when unknown (the watch maps any negative to nil).
    /// Callers: `AppModel.pushStatusToWatch()` (GPS fixes while navigating, waypoint advance,
    /// arrival, route start/stop) and the route-readiness paths (`queueRouteStart`,
    /// `failQueuedRouteStart`, `cancelRouteStart`) with fixed lines and -1.
    /// Unlike `send(_:)` it does not check `isSupported` (phone-only target, so always true).
    /// Note: `lastStatus` is updated even if the session is not yet activated, so that value is
    /// not retried until the instruction or distance changes.
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

    /// Ephemeral live message: encode and `sendMessage` only if supported, activated and
    /// reachable right now; otherwise silently dropped (cues are worthless late).
    private func send(_ msg: PhoneToWatch) {
        let session = WCSession.default
        guard isSupported, session.activationState == .activated, session.isReachable,
              let dict = try? WatchEnvelope.encode(msg) else { return }
        deliver(dict, session: session)
    }

    /// `sendMessage` without a reply handler. Optimistically bumps `messagesSent` and clears
    /// `lastError`; a failure arrives later on a WatchConnectivity queue and hops to main to
    /// set `lastError` (only the error's text crosses — `Error` is not Sendable).
    /// ⚠ `@Sendable` is required: WCSession's `errorHandler` block is not `NS_SWIFT_SENDABLE`
    /// (WCSession.h), so without it the closure is inferred `@MainActor` and the runtime traps
    /// when WatchConnectivity invokes it on its own queue (same mechanism as the 2026-09-11
    /// pedometer crash; the watch side already does this in `WatchModel.send`).
    private func deliver(_ dict: [String: Any], session: WCSession) {
        session.sendMessage(dict, replyHandler: nil) { @Sendable [weak self] error in
            let text = error.localizedDescription
            Task { @MainActor [weak self] in self?.lastError = text }
        }
        messagesSent += 1
        lastError = nil
    }
}

/// WCSessionDelegate callbacks arrive on a background queue. Decode into Sendable values here,
/// then hop to the main actor.
///
/// Why a separate class: a delegate method on the main-actor `PhoneWatchLink` would be called
/// off main (a data race Swift 6 rejects). This relay touches no main-actor state; the hop
/// lives in the closures `PhoneWatchLink.activate()` installs. `@unchecked Sendable` is sound
/// because both closure properties are written once on main before the relay becomes the
/// session delegate and only read afterwards.
nonisolated private final class SessionRelay: NSObject, WCSessionDelegate, @unchecked Sendable {
    /// Receives (paired, app installed, reachable, error text) on the WC queue; the installed
    /// closure hops to main and updates the published flags.
    var onStateChange: (@Sendable (_ paired: Bool, _ installed: Bool, _ reachable: Bool, _ error: String?) -> Void)?
    /// Receives each successfully decoded watch command on the WC queue; hops to main.
    var onCommand: (@Sendable (WatchToPhone) -> Void)?

    /// Snapshot the session's state as Sendable values and forward it.
    private func publish(_ session: WCSession, error: Error? = nil) {
        onStateChange?(session.isPaired, session.isWatchAppInstalled, session.isReachable,
                       error?.localizedDescription)
    }

    /// Activation finished (or failed): publish pairing / install / reachability and any error.
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        publish(session, error: error)
    }

    /// Required on iOS; nothing to do while a watch switch is in progress.
    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The user switched watches: re-activate for the new one.
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// Watch app came to the foreground / started or ended its workout session.
    func sessionReachabilityDidChange(_ session: WCSession) {
        publish(session)
    }

    /// Pairing or watch-app installation changed.
    func sessionWatchStateDidChange(_ session: WCSession) {
        publish(session)
    }

    /// Fire-and-forget command from the watch; undecodable messages are ignored.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let cmd = WatchEnvelope.decodeWatchToPhone(message) { onCommand?(cmd) }
    }

    /// Command that expects a reply: forward it if decodable, then answer `["ok": Bool]` at once
    /// (on this queue, before the main-actor handler runs) so the watch is never left waiting.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let cmd = WatchEnvelope.decodeWatchToPhone(message)
        if let cmd { onCommand?(cmd) }
        replyHandler(["ok": cmd != nil])        // false = watch is newer than this phone build
    }
}
