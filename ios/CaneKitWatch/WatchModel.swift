//
//  WatchModel.swift
//  CaneKit Watch
//
//  Watch side of the link: receives cues from the phone and plays them on the wrist, sends
//  Next / Describe / Recenter back, and keeps itself alive with a walking workout session so
//  `WKInterfaceDevice.play` keeps working with the wrist down (it no-ops when the app is not
//  frontmost). If HealthKit is refused or the workout fails, falls back to an extended runtime
//  session (`WKBackgroundModes: mindfulness`).
//
//  Haptic map (spec): turnLeft → .directionUp, turnRight → .directionDown, crossing →
//  .notification, arrived → .success, obstacle → .failure. Mirrored obstacle cues: left → .start,
//  right → .stop, center → .click, head → .failure.
//

import CaneKitLogic
import HealthKit
import Observation
import WatchConnectivity
import WatchKit

@MainActor
@Observable
final class WatchModel {

    // MARK: Published

    /// Current instruction text from the phone.
    var instruction = "Waiting for the phone"
    /// Distance to the next waypoint in metres, if known.
    var distanceM: Int?
    /// Whether the phone app is reachable over WatchConnectivity.
    var phoneReachable = false
    /// Last cue played (for the small status line).
    private(set) var lastCue = "—"
    /// "workout" / "runtime" / "none" — how we stay frontmost, only set once the session is running.
    private(set) var keepAlive = "none"
    private(set) var lastError: String?

    // MARK: Private

    @ObservationIgnored private var started = false
    @ObservationIgnored private let relay = WatchSessionRelay()
    @ObservationIgnored private let healthStore = HKHealthStore()
    @ObservationIgnored private var workout: HKWorkoutSession?
    @ObservationIgnored private var workoutRelay: WorkoutRelay?
    @ObservationIgnored private var runtime: WKExtendedRuntimeSession?
    @ObservationIgnored private var runtimeRelay: RuntimeRelay?
    /// CaneKitLogic.CrownAccumulator (unit-tested): 3 detents within 1 s of the first, 0.8 s debounce.
    @ObservationIgnored private var crown = CrownAccumulator()

    init() {}

    // MARK: Lifecycle

    /// Idempotent: SwiftUI's `.task` can run more than once per app lifetime.
    func start() {
        guard !started, WCSession.isSupported() else { return }
        started = true
        relay.onMessage = { [weak self] msg in
            Task { @MainActor [weak self] in self?.handle(msg) }
        }
        relay.onReachability = { [weak self] reachable in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.phoneReachable = reachable
                // Status sent while we were asleep lands in the application context.
                if let msg = WatchEnvelope.decodePhoneToWatch(WCSession.default.receivedApplicationContext) {
                    self.handle(msg)
                }
            }
        }
        let session = WCSession.default
        session.delegate = relay
        session.activate()
        startKeepAlive()
    }

    // MARK: Incoming

    private func handle(_ msg: PhoneToWatch) {
        switch msg {
        case .nav(let cue):
            play(Self.haptic(for: cue))
            lastCue = cue.rawValue
        case .obstacle(let kind):
            if let h = Self.haptic(forObstacle: kind) { play(h) }
            lastCue = "obstacle \(kind.rawValue)"
        case .status(let text, let d):
            instruction = text
            distanceM = d >= 0 ? d : nil           // the phone sends -1 for "unknown"
        }
    }

    private static func haptic(for cue: NavCue) -> WKHapticType {
        switch cue {
        case .turnLeft: return .directionUp
        case .turnRight: return .directionDown
        case .crossing: return .notification
        case .arrived: return .success
        case .obstacle: return .failure
        }
    }

    private static func haptic(forObstacle kind: CueKind) -> WKHapticType? {
        switch kind {
        case .left: return .start
        case .right: return .stop
        case .center: return .click
        case .head: return .failure
        case .clear: return nil
        }
    }

    private func play(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }

    // MARK: Outgoing

    /// Sends a command; the wrist clicks only when the phone can actually receive it.
    func send(_ cmd: WatchToPhone) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable,
              let dict = try? WatchEnvelope.encode(cmd) else {
            lastError = "Phone not reachable"
            play(.retry)                    // never .failure: that pattern means "head height"
            return
        }
        lastError = nil
        // The phone replies ok=false when it does not know the command (an older phone build than
        // the watch, e.g. Repeat): say so instead of a reassuring click that did nothing.
        session.sendMessage(dict, replyHandler: { @Sendable [weak self] reply in
            let ok = reply["ok"] as? Bool ?? true
            Task { @MainActor [weak self] in
                guard !ok, let self else { return }
                self.lastError = "Update the phone app"
                self.play(.retry)
            }
        }, errorHandler: { @Sendable [weak self] error in
            let text = error.localizedDescription
            Task { @MainActor [weak self] in self?.lastError = text }
        })
        play(.click)
    }

    /// Digital Crown: three detents (either direction) within one second of the first = "next
    /// waypoint", then a 0.8 s debounce. The window is anchored at the first detent, so a cuff
    /// brushing the crown once per arm swing never adds up to a skip.
    func crownMoved(delta: Double, now: TimeInterval) {
        if crown.move(delta: delta, now: now) { send(.nextWaypoint) }
    }

    // MARK: Keep-alive

    /// Prefer a walking workout (high-priority background, haptics play wrist-down); fall back to
    /// an extended runtime session if HealthKit is unavailable, refused, or the workout fails.
    private func startKeepAlive() {
        guard HKHealthStore.isHealthDataAvailable() else { startRuntimeSession(); return }
        let types: Set<HKSampleType> = [HKObjectType.workoutType()]
        healthStore.requestAuthorization(toShare: types, read: [HKQuantityType(.stepCount)]) { [weak self] ok, error in
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                if ok { self.startWorkout() } else {
                    self.lastError = message ?? "HealthKit refused"
                    self.startRuntimeSession()
                }
            }
        }
    }

    private func startWorkout() {
        let config = HKWorkoutConfiguration()
        config.activityType = .walking
        config.locationType = .outdoor
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let relay = WorkoutRelay { [weak self] running, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if running { self.keepAlive = "workout"; self.lastError = nil }
                    else if self.keepAlive == "workout" || error != nil {
                        // Ended or failed underneath us: fall back so cues keep working.
                        self.keepAlive = "none"
                        if let error { self.lastError = "Workout: \(error)" }
                        self.startRuntimeSession()
                    }
                }
            }
            session.delegate = relay
            workoutRelay = relay
            session.startActivity(with: Date())
            workout = session
        } catch {
            lastError = "Workout: \(error.localizedDescription)"
            startRuntimeSession()
        }
    }

    private func startRuntimeSession() {
        guard runtime == nil else { return }
        let session = WKExtendedRuntimeSession()
        let relay = RuntimeRelay { [weak self] running, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if running { self.keepAlive = "runtime" }
                else {
                    self.keepAlive = "none"
                    self.runtime = nil
                    if let error { self.lastError = "Runtime session: \(error)" }
                }
            }
        }
        session.delegate = relay
        runtimeRelay = relay
        runtime = session
        session.start()
    }

    func stopKeepAlive() {
        workout?.end()
        workout = nil
        runtime?.invalidate()
        runtime = nil
        keepAlive = "none"
    }
}

// MARK: - Relays (delegate callbacks arrive off the main actor)

nonisolated private final class WatchSessionRelay: NSObject, WCSessionDelegate, @unchecked Sendable {
    var onMessage: (@Sendable (PhoneToWatch) -> Void)?
    var onReachability: (@Sendable (Bool) -> Void)?

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        onReachability?(session.isReachable)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        onReachability?(session.isReachable)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let msg = WatchEnvelope.decodePhoneToWatch(message) { onMessage?(msg) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        if let msg = WatchEnvelope.decodePhoneToWatch(context) { onMessage?(msg) }
    }
}

/// Reports whether the workout session is running; `error` is a description on failure.
nonisolated private final class WorkoutRelay: NSObject, HKWorkoutSessionDelegate, @unchecked Sendable {
    private let onChange: @Sendable (_ running: Bool, _ error: String?) -> Void
    init(onChange: @escaping @Sendable (Bool, String?) -> Void) { self.onChange = onChange }

    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {
        onChange(toState == .running, nil)
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        onChange(false, error.localizedDescription)
    }
}

nonisolated private final class RuntimeRelay: NSObject, WKExtendedRuntimeSessionDelegate, @unchecked Sendable {
    private let onChange: @Sendable (_ running: Bool, _ error: String?) -> Void
    init(onChange: @escaping @Sendable (Bool, String?) -> Void) { self.onChange = onChange }

    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        onChange(true, nil)
    }

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        onChange(false, "expiring")
    }

    func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?) {
        onChange(false, error?.localizedDescription ?? "invalidated (\(reason.rawValue))")
    }
}
