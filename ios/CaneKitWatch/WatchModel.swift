//
//  WatchModel.swift
//  CaneKit Watch
//
//  Watch side of the link: receives cues from the phone and plays them on the wrist, sends
//  Repeat / Next / Describe / Recenter back, and keeps itself alive with a walking workout session
//  so `WKInterfaceDevice.play` keeps working with the wrist down (it no-ops when the app is not
//  frontmost). If HealthKit is unavailable or refused, or the workout fails, falls back to an
//  extended runtime session (`WKBackgroundModes: mindfulness`).
//
//  Haptic map: turnLeft (and "Veer left.") → .directionUp, turnRight (and "Veer right.") →
//  .directionDown, crossing → .notification, arrived → .success, nav `.obstacle` → .failure (the
//  case exists in `NavCue` but the phone never sends it). Mirrored obstacle cues: left → .start,
//  right → .stop, center (also a LiDAR ground hazard) → .click, head → .failure. Button presses:
//  .click when sent, .retry when they could not be sent or the phone is older than the watch.
//
//  Implements the wrist columns of docs/design.md §5.2–§5.4 and the §6.6 haptic table and crown
//  rule; design.md now matches this map (each cue is one system pattern, played once).
//  AGENTS.md "deliberate": `.failure` is reserved for head height; send failure and "phone app
//  too old" use `.retry`, never `.failure`.
//
//  Owner / callers: one instance, created by `WatchApp`, started by `WatchContentView`'s `.task`.
//  Phone counterpart: `ios/CaneKit/Watch/PhoneWatchLink.swift` (wire contract: CaneKitLogic
//  `WatchMessage.swift`). Module `watch-widget-shared` in docs/CODE_REFERENCE.md.
//  Tests: the envelope is pinned by CaneKitLogic `WatchMessageTests`, the crown gesture by the
//  `crown…` tests in `NavSupportTests`. The haptic map, reply handling and keep-alive have no
//  automated test (no watch test bundle): CHANGELOG "Step 5 — Watch" device test ("lower the wrist
//  for 30 s → cues still arrive") and docs/devices_setup.md.
//
//  Accessibility contract: no UI of its own. The strings it publishes (`instruction`,
//  `lastError`) are shown and read by WatchContentView.
//
//  Concurrency: `@MainActor` model; the WCSession / HKWorkoutSession / WKExtendedRuntimeSession
//  delegates are `nonisolated` relay classes at the bottom that hop back with
//  `Task { @MainActor in … }` (AGENTS.md hard rule 1).
//

import CaneKitLogic
import HealthKit
import Observation
import WatchConnectivity
import WatchKit

/// Observable state + behaviour behind the wrist screen: phone link, cue haptics, outgoing
/// commands, crown-to-Next gesture and the workout / runtime keep-alive.
@MainActor
@Observable
final class WatchModel {

    // MARK: Published

    /// Current instruction text from the phone's `.status` (`NavigationEngine.instruction`: the
    /// waypoint line, "Arrived: <say>" on arrival, "No route" when idle). The prefixes "Arrived"
    /// and "No route" also drive `updateKeepAlive`.
    var instruction = "Waiting for the phone"
    /// Whole metres to the next waypoint; nil until the first status and whenever the phone sends
    /// its -1 "unknown" sentinel. Shown as the navigation title.
    var distanceM: Int?
    /// `WCSession.isReachable` as last reported by the relay (live messaging to the phone is
    /// possible right now). Drives the phone-link glyph; `send` re-checks the live session itself
    /// rather than trusting this copy.
    var phoneReachable = false
    /// Last cue played: `NavCue.rawValue` or "obstacle <kind>". Debug state only — no view shows
    /// it since the watch footer was removed.
    private(set) var lastCue = "—"
    /// How the app stays frontmost: "workout" / "runtime" / "runtime (expiring)" / "none". Set to a
    /// running value only once the session reports running. Debug state only — not rendered; the
    /// code compares it as a string, so keep the literals in step with `updateKeepAlive`.
    private(set) var keepAlive = "none"
    /// Last user-visible problem ("Phone not reachable", "Update the phone app", a transport error,
    /// "HealthKit refused", "Workout: …", "Runtime session: …"); cleared when a send is attempted
    /// on a reachable link and when the workout reports running. Shown in red under the buttons.
    private(set) var lastError: String?

    // MARK: Private

    /// Guards `start()` against SwiftUI running `.task` more than once.
    @ObservationIgnored private var started = false
    /// WCSession delegate relay (off-main callbacks → main actor). Held strongly here because
    /// `WCSession.delegate` does not keep it alive on its own.
    @ObservationIgnored private let relay = WatchSessionRelay()
    /// HealthKit store used only to authorise and run the walking workout (the `stepCount` read
    /// grant it asks for serves the phone's arrival summary; nothing here reads steps).
    @ObservationIgnored private let healthStore = HKHealthStore()
    /// The walking workout that was started, from `startActivity` until it ends, fails or is
    /// stopped. Non-nil before it reports `.running`, so it also blocks a duplicate start; the
    /// relay's stale-callback guard compares against its identity.
    @ObservationIgnored private var workout: HKWorkoutSession?
    /// Strong reference to the workout delegate relay (the session holds it weakly).
    @ObservationIgnored private var workoutRelay: WorkoutRelay?
    /// The fallback extended runtime session, from `startRuntimeSession` until it invalidates or
    /// is stopped; non-nil means "never start a second one".
    @ObservationIgnored private var runtime: WKExtendedRuntimeSession?
    /// Strong reference to the runtime-session delegate relay (the session holds it weakly).
    @ObservationIgnored private var runtimeRelay: RuntimeRelay?
    /// CaneKitLogic.CrownAccumulator (unit-tested): 3 detents within 1 s of the first, 0.8 s
    /// debounce. A value type: `move` mutates it in place through this `var`.
    @ObservationIgnored private var crown = CrownAccumulator()
    /// Pending delayed keep-alive stop, scheduled 60 s after an "Arrived…" status and cancelled
    /// by any later status (see `updateKeepAlive`).
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    /// True while HealthKit authorization for a keep-alive start is pending, so a status arriving
    /// meanwhile cannot start a second workout.
    @ObservationIgnored private var keepAliveStarting = false

    /// Creates an idle model; nothing is activated until `start()`.
    init() {}

    // MARK: Lifecycle

    /// Idempotent: SwiftUI's `.task` can run more than once per app lifetime.
    ///
    /// Wires the relay callbacks, activates `WCSession` and starts the keep-alive. On every
    /// reachability callback (activation completing, then each change) it also replays the latest
    /// application context, so a status sent while the watch was asleep still updates the screen.
    /// Replaying is harmless: a `.status` only sets text, and the context never carries a haptic
    /// cue (the phone sends cues live only). Does nothing — not even the keep-alive — where
    /// `WCSession` is unsupported. Called from `WatchContentView`'s `.task` on the main actor.
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

    /// Applies one decoded phone message: plays the wrist haptic for a nav / obstacle cue, or
    /// updates `instruction` / `distanceM` for a status (distance -1 from the phone = unknown) and
    /// lets `updateKeepAlive` start or schedule the stop of the keep-alive. Main actor only (the
    /// relay closures hop here).
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
            updateKeepAlive(forInstruction: text)
        }
    }

    /// Wrist pattern for a navigation cue (see the haptic map in the file header). ⚠ Changing a
    /// pattern needs the CHANGELOG Step 5 device test (four distinguishable wrist taps) and the
    /// design.md §6.6 table in the same commit; `.failure` stays reserved for head height.
    private static func haptic(for cue: NavCue) -> WKHapticType {
        switch cue {
        case .turnLeft: return .directionUp
        case .turnRight: return .directionDown
        case .crossing: return .notification
        case .arrived: return .success
        case .obstacle: return .failure
        }
    }

    /// Wrist pattern for a mirrored obstacle cue; nil for `.clear` (nothing to play). The phone
    /// sends these only when it cannot buzz (engine down or "Silence haptics") or "Mirror obstacle
    /// cues to the watch" is on, at most one per kind per second (`PhoneWatchLink`).
    private static func haptic(forObstacle kind: CueKind) -> WKHapticType? {
        switch kind {
        case .left: return .start
        case .right: return .stop
        case .center: return .click
        case .head: return .failure
        case .clear: return nil
        }
    }

    /// Plays one system haptic on the wrist (no-op unless the app is frontmost / kept alive).
    private func play(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }

    // MARK: Outgoing

    /// Sends a command; the wrist clicks only when the phone can actually receive it.
    ///
    /// Not activated / unreachable / unencodable → `lastError = "Phone not reachable"` + `.retry`.
    /// Reachable → `lastError = nil`, `sendMessage` with a reply handler, and `.click` at once (the
    /// confirm does not wait for the reply). The phone answers `["ok": Bool]` immediately on its
    /// WatchConnectivity queue: `ok == false` (the phone build does not know this command, e.g.
    /// Repeat on an older phone) → "Update the phone app" + `.retry`; a missing `ok` key counts as
    /// ok. A transport error → `lastError` = its description + `.retry` (Muse M8: the wrist already
    /// clicked "sent", so a late failure must be felt too). No retry or queueing: a command is
    /// only meaningful now.
    /// - Parameter cmd: Next / Describe / Recenter / Repeat, from the buttons or the crown.
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
            // The wrist already clicked "sent"; a late failure must be felt too (Muse M8).
            Task { @MainActor [weak self] in self?.lastError = text; self?.play(.retry) }
        })
        play(.click)
    }

    /// Digital Crown: three detents (either direction) within one second of the first = "next
    /// waypoint", then a 0.8 s debounce. The window is anchored at the first detent, so a cuff
    /// brushing the crown once per arm swing never adds up to a skip.
    /// - Parameters:
    ///   - delta: crown change since the last callback (detents; sign = direction).
    ///   - now: wall-clock seconds (`Date().timeIntervalSinceReferenceDate` from the view).
    /// ⚠ The numbers live in `CrownAccumulator` and are pinned by
    /// `crownFiresOnThreeDetentsWithinASecond`, `crownIgnoresARhythmicSleeve` and
    /// `crownDebouncesBackToBackGestures`; device test "crown three clicks → phone says 'Next.'".
    func crownMoved(delta: Double, now: TimeInterval) {
        if crown.move(delta: delta, now: now) { send(.nextWaypoint) }
    }

    // MARK: Keep-alive

    /// Prefer a walking workout (high-priority background, haptics play wrist-down); fall back to
    /// an extended runtime session if HealthKit is unavailable, refused, or the workout fails.
    ///
    /// Asks to share workouts and read step count (the phone's arrival summary merges the
    /// watch's steps). Note HealthKit's `ok` only says the request was processed, not that the
    /// walker granted it; a denied grant is expected to surface as a workout failure, which falls
    /// back through the relay like any other failure (not verified on a device). Called by
    /// `start()` at launch and by
    /// `updateKeepAlive` when a route's status arrives with nothing running.
    private func startKeepAlive() {
        // One start at a time: HealthKit authorization is async, and a second call while it is
        // pending would start two workout sessions (review).
        guard !keepAliveStarting else { return }
        keepAliveStarting = true
        guard HKHealthStore.isHealthDataAvailable() else { keepAliveStarting = false; startRuntimeSession(); return }
        let types: Set<HKSampleType> = [HKObjectType.workoutType()]
        healthStore.requestAuthorization(toShare: types, read: [HKQuantityType(.stepCount)]) { [weak self] ok, error in
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.keepAliveStarting = false
                if ok { self.startWorkout() } else {
                    self.lastError = message ?? "HealthKit refused"
                    self.startRuntimeSession()
                }
            }
        }
    }

    /// Starts an outdoor walking `HKWorkoutSession`. `keepAlive` becomes "workout" when it
    /// reports running; if it ends or fails underneath us, falls back to the runtime session.
    ///
    /// Only `startActivity` is called — no `HKLiveWorkoutBuilder`, so nothing is collected or
    /// saved; the session exists for its background priority. Intermediate states before the
    /// first `.running` (e.g. `.prepared`) do not trigger the fallback. Each relay callback is
    /// checked against this session's `ObjectIdentifier` so a stale session cannot clear a newer
    /// one (review round 5). A throwing init → `lastError = "Workout: …"` + runtime session.
    private func startWorkout() {
        let config = HKWorkoutConfiguration()
        config.activityType = .walking
        config.locationType = .outdoor
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let id = ObjectIdentifier(session)
            let relay = WorkoutRelay { [weak self] running, error in
                Task { @MainActor [weak self] in
                    // Callbacks from a session we already ended or replaced are not news
                    // (review round 5: stale callbacks cleared the newer session).
                    guard let self, self.workout.map(ObjectIdentifier.init) == id else { return }
                    if running { self.keepAlive = "workout"; self.lastError = nil }
                    else if self.keepAlive == "workout" || error != nil {
                        // Ended or failed underneath us: fall back so cues keep working.
                        self.keepAlive = "none"
                        self.workout = nil        // a dead session must not block a restart
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

    /// Starts the fallback `WKExtendedRuntimeSession` (once; no-op if one already exists).
    /// `keepAlive` becomes "runtime" while it runs, "runtime (expiring)" when the system warns it
    /// will expire (still running), and "none" when it invalidates. There is no automatic re-arm
    /// after invalidation: the next route's status restarts the chain via `updateKeepAlive`.
    /// The session type comes from `WKBackgroundModes` (`mindfulness`) in the watch Info.plist.
    private func startRuntimeSession() {
        guard runtime == nil else { return }
        let session = WKExtendedRuntimeSession()
        let id = ObjectIdentifier(session)
        let relay = RuntimeRelay { [weak self] event in
            Task { @MainActor [weak self] in
                // Only the current session's callbacks count: `stopKeepAlive()` invalidating it
                // on purpose must not show up as an error or clear a newer session.
                guard let self, self.runtime.map(ObjectIdentifier.init) == id else { return }
                switch event {
                case .started: self.keepAlive = "runtime"
                case .expiring: self.keepAlive = "runtime (expiring)"   // still running; keep it
                case .ended(let error):
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

    /// Starts or schedules the end of the keep-alive from a status line, so the workout runs only
    /// around a route (Muse M7: it never stopped, draining the watch all demo day).
    ///
    /// Every status first cancels a pending stop. Then: "Arrived…" (the phone sends
    /// "Arrived: <say>") → if anything is running, `stopKeepAlive()` 60 s later, so the arrival tap
    /// and summary still land (a replayed "Arrived…" context restarts that countdown); "No route…"
    /// → nothing, deliberately (see the inline note; Step 12 rejected stopping here, Step 20 added
    /// the guard so an idle "No route" does not start one); any other text with nothing running
    /// or starting → `startKeepAlive()`.
    /// ⚠ Device test: "arrive → the workout ends about a minute later; start another route → wrist
    /// cues work again".
    private func updateKeepAlive(forInstruction text: String) {
        // Only arrival ends the keep-alive (after 60 s, so the arrival tap and summary land).
        // "No route" does NOT: a suspended watch could never restart it for the next route
        // (review) — the phone's first status of a new route only reaches a running watch app.
        stopTask?.cancel()
        if text.hasPrefix("Arrived") {
            guard keepAlive != "none" else { return }
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.stopKeepAlive()
            }
        } else if !text.hasPrefix("No route"), keepAlive == "none", workout == nil, runtime == nil {
            startKeepAlive()
        }
    }

    /// Ends whichever keep-alive session exists (workout `end()`, runtime `invalidate()`), clears
    /// both references first-hand and resets `keepAlive` to "none". The sessions' own end
    /// callbacks then fail the identity guard and are ignored, so a deliberate stop never shows
    /// an error or triggers the fallback. Internal access, but the only caller today is
    /// `updateKeepAlive`'s delayed arrival stop. Does not cancel `stopTask` or a pending
    /// HealthKit authorization.
    func stopKeepAlive() {
        workout?.end()
        workout = nil
        runtime?.invalidate()
        runtime = nil
        keepAlive = "none"
    }
}

// MARK: - Relays (delegate callbacks arrive off the main actor)

/// `WCSessionDelegate` relay: forwards decoded phone messages and reachability changes through
/// `@Sendable` closures; `WatchModel` hops them onto the main actor. `@unchecked Sendable` is
/// safe here because the closures are set once in `start()` before the session activates, and
/// the relay itself never touches main-actor state. Undecodable payloads (a newer phone's case)
/// are dropped silently — the watch has nothing useful to do with them. No
/// `sessionDidBecomeInactive` / `sessionDidDeactivate`: those are iOS-only delegate methods.
nonisolated private final class WatchSessionRelay: NSObject, WCSessionDelegate, @unchecked Sendable {
    /// Called with every decodable message or application context from the phone.
    var onMessage: (@Sendable (PhoneToWatch) -> Void)?
    /// Called with `isReachable` after activation and on every reachability change.
    var onReachability: (@Sendable (Bool) -> Void)?

    /// Activation finished: report the initial reachability (which also makes `WatchModel` replay
    /// the stored application context). The activation error is not surfaced.
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        onReachability?(session.isReachable)
    }

    /// Live messaging to the phone became possible or stopped being possible.
    func sessionReachabilityDidChange(_ session: WCSession) {
        onReachability?(session.isReachable)
    }

    /// Live message (sent while reachable): cues and status updates. The phone sends these with
    /// no reply handler, so this variant is the only one needed.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let msg = WatchEnvelope.decodePhoneToWatch(message) { onMessage?(msg) }
    }

    /// Latest-state channel: status the phone posted while we could not receive live messages.
    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        if let msg = WatchEnvelope.decodePhoneToWatch(context) { onMessage?(msg) }
    }
}

/// Reports whether the workout session is running; `error` is a description on failure. Every
/// non-running state (`.prepared`, `.paused`, `.stopped`, `.ended`) reports `false`; `WatchModel`
/// decides whether that means "fell over" (it was running, or there is an error).
nonisolated private final class WorkoutRelay: NSObject, HKWorkoutSessionDelegate, @unchecked Sendable {
    /// `(running, error)` callback; immutable after init.
    private let onChange: @Sendable (_ running: Bool, _ error: String?) -> Void
    /// - Parameter onChange: called on every state change and on failure.
    init(onChange: @escaping @Sendable (Bool, String?) -> Void) { self.onChange = onChange }

    /// Any state change: running iff the new state is `.running`.
    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {
        onChange(toState == .running, nil)
    }

    /// The workout failed: not running, with the error text.
    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        onChange(false, error.localizedDescription)
    }
}

/// What happened to the extended runtime session — a Sendable summary so no framework object
/// crosses into the main actor.
nonisolated private enum RuntimeEvent: Sendable {
    /// The session is running (`extendedRuntimeSessionDidStart`).
    case started
    /// About to expire, but still running (the session is not gone yet).
    case expiring
    /// Invalidated; the error text, or nil for a normal end (reason `.none`).
    case ended(String?)
}

/// Reports the extended runtime session's lifecycle as `RuntimeEvent`s.
nonisolated private final class RuntimeRelay: NSObject, WKExtendedRuntimeSessionDelegate, @unchecked Sendable {
    /// Event callback; immutable after init.
    private let onChange: @Sendable (RuntimeEvent) -> Void
    /// - Parameter onChange: called on start, imminent expiry and invalidation.
    init(onChange: @escaping @Sendable (RuntimeEvent) -> Void) { self.onChange = onChange }

    /// Session is running: haptics now play with the wrist down.
    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        onChange(.started)
    }

    /// About to expire: still running for now.
    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        onChange(.expiring)
    }

    /// Ended: an error only when there is one (a normal end, reason `.none`, is not an error).
    func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?) {
        let text = error?.localizedDescription ?? (reason == .none ? nil : "invalidated (\(reason.rawValue))")
        onChange(.ended(text))
    }
}
