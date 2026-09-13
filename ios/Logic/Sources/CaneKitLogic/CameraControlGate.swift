//
//  CameraControlGate.swift
//  CaneKitLogic
//
//  When a Camera Control / volume press may start a scene description (Step 67; review round
//  Steps 67–68).
//
//  Why this exists: phone log `canekit-2026-09-13T15-48-34Z.jsonl`. The phone is gripped or clamped,
//  and the hand holding it pressed Camera Control three times in the first four seconds (t = 1.71,
//  2.89, 3.56, each `describe {trigger: cameraControl}`), while "OpenCane ready." was still
//  speaking. The walker heard two busy earcons stack up and, at 14.9 s, a scene description nobody
//  had asked for, on top of the launch listen. A press is a real way to ask "Where am I", so it
//  stays; it is refused only when it is almost certainly the grip, not the walker:
//    · during the first `launchGraceSeconds` after launch (picking the phone up, clamping it);
//    · while the voice shell is listening (the walker is talking, not asking for a description);
//    · while the launch line is still pending (speaking, or draining before the launch listen);
//    · as a grip burst: `burstPresses` presses within `burstWindowSeconds`;
//    · within `debounceSeconds` of the last ACCEPTED press.
//  Review round Steps 67–68: Antigravity #6 — the debounce used to restart on every press, refused
//  or not, so a hand touching the button every 1–1.8 s locked the button out indefinitely; now it
//  runs from the last accepted press and a grip is its own rule. Muse #6 — a refused press was
//  silent, so a walker who opened the app to ask "where am I" got nothing; now ONE press refused
//  only by the launch states (grace, launch line, listening) is remembered and answered when those
//  states end (`resolvePending`), unless a second quick press (a grip) or another command came first.
//  Every number is [H] until a walk log tunes it.
//
//  Key invariants:
//    · First refusal wins, in this order: launch_grace, listening, launch_line, grip_burst, debounce.
//      The reason strings are the `describe_skipped.reason` trip-log field.
//    · Only an accepted press (or a fired pending one) starts the debounce.
//    · A pending describe is armed only by a press refused for a launch state that came ≥
//      `debounceSeconds` after the previous press; any later press, a grip burst, another command
//      (`commandGeneration` changed) or `pendingMaxAgeSeconds` clears it. It fires only after the
//      launch states have been clear for `pendingSettleSeconds` (a transcript may still arrive).
//    · A clock that runs backwards refuses (elapsed < window); never describes.
//    · Pure value type; the caller passes the clock (`ProcessInfo.systemUptime`).
//
//  Owner / caller: `AppModel.cameraControlPressed` (app, main actor) — one instance, re-created at
//  `AppModel.start()`; `.describe` → `describeScene(trigger: .cameraControl)`, `.skip` →
//  `describe_skipped {reason, trigger: cameraControl, pending}`; while `hasPendingDescribe`,
//  `AppModel.watchPendingCameraControl` polls `resolvePending` (`describe_deferred {action, reason}`).
//  Tests: CameraControlGateTests.swift (14).
//

import Foundation

/// Launch grace, grip burst, debounce and one deferred press for Camera Control / volume presses.
public struct CameraControlGate: Sendable, Equatable {

    /// Seconds after launch during which every press is refused. [H] 5 s: the log's accidental
    /// presses were all at 1.7–3.6 s, and "OpenCane ready." plus the listening tone take about 2 s.
    public static let launchGraceSeconds: Double = 5

    /// A press closer than this to the last accepted press is refused. [H] 2 s: a deliberate second
    /// "Where am I" is rarely that quick, and the describer answers a real one with its busy taps.
    public static let debounceSeconds: Double = 2

    /// Window of the grip rule. [H] 1.5 s: the log's grip pressed every 0.7–1.2 s.
    public static let burstWindowSeconds: Double = 1.5

    /// Presses (this one included) inside `burstWindowSeconds` that make a grip burst. [H] 3.
    public static let burstPresses = 3

    /// Seconds a deferred press may wait for the launch states to end before it is dropped. [H] 30 s:
    /// the launch line, its drain (capped at 15 s) and the launch listen fit inside it.
    public static let pendingMaxAgeSeconds: Double = 30

    /// Seconds the launch states must stay clear before a deferred press fires. [H] 0.5 s: long enough
    /// for a transcript that ended the listen to reach the coordinator and bump its generation.
    public static let pendingSettleSeconds: Double = 0.5

    /// What to do with a press.
    public enum Verdict: Sendable, Equatable {
        /// Start a scene description (`AppModel.describeScene(trigger: .cameraControl)`).
        case describe
        /// Refuse it; `reason` is written to `describe_skipped {reason}`: "launch_grace",
        /// "listening", "launch_line", "grip_burst" or "debounce".
        case skip(reason: String)
    }

    /// What `resolvePending` decided about the deferred press.
    public enum PendingOutcome: Sendable, Equatable {
        /// Nothing is pending.
        case none
        /// Still pending: a launch state is active or has not been clear for `pendingSettleSeconds`.
        case wait
        /// Describe now (the pending press is consumed and counts as the accepted press).
        case fire
        /// Dropped: "other_command" (the coordinator handled a query meanwhile) or "expired".
        case drop(reason: String)
    }

    /// A press refused only by a launch state, waiting for it to end.
    private struct Pending: Sendable, Equatable {
        /// When the press arrived.
        let at: Double
        /// `commandGeneration` at the press.
        let generation: Int
    }

    /// When the app launched (the caller's clock).
    public let launchedAt: Double
    /// When the last accepted (or fired) press was; nil before the first.
    private var lastAcceptedAt: Double?
    /// When the previous press arrived, accepted or not; nil before the first.
    private var lastPressAt: Double?
    /// Every press inside the burst window, oldest first.
    private var recentPresses: [Double] = []
    /// The deferred press, if any.
    private var pending: Pending?
    /// Since when the launch states have been clear while a press is pending; nil otherwise.
    private var clearSince: Double?

    /// True while a press waits for the launch states to end (the app then polls `resolvePending`).
    public var hasPendingDescribe: Bool { pending != nil }

    /// - Parameter launchedAt: the launch moment on the same clock `press(now:…)` will be given.
    public init(launchedAt: Double) {
        self.launchedAt = launchedAt
    }

    /// Judge one press and remember it for the burst rule (and, if accepted, the debounce).
    /// - Parameters:
    ///   - now: the caller's clock.
    ///   - listening: the voice input is listening or starting (`VoiceInputEngine.isListening ||
    ///     isStarting`).
    ///   - launchLinePending: the launch line is speaking or the launch sequence is still waiting to
    ///     open its listen (`AppModel.launchLinePending`).
    ///   - commandGeneration: the coordinator's query generation now (`ConversationCoordinator.commandGeneration`);
    ///     a deferred press is dropped when it changes.
    /// - Returns: `.describe`, or `.skip(reason:)`.
    public mutating func press(now: Double, listening: Bool, launchLinePending: Bool,
                               commandGeneration: Int = 0) -> Verdict {
        let previous = lastPressAt
        lastPressAt = now
        recentPresses = recentPresses.filter { now - $0 < Self.burstWindowSeconds }
        recentPresses.append(now)
        let blockedReason: String? = now - launchedAt < Self.launchGraceSeconds ? "launch_grace"
            : listening ? "listening"
            : launchLinePending ? "launch_line"
            : nil
        if let reason = blockedReason {
            let quickRepeat = previous.map { now - $0 < Self.debounceSeconds } ?? false
            pending = quickRepeat ? nil : Pending(at: now, generation: commandGeneration)
            clearSince = nil
            return .skip(reason: reason)
        }
        pending = nil
        clearSince = nil
        if recentPresses.count >= Self.burstPresses { return .skip(reason: "grip_burst") }
        if let last = lastAcceptedAt, now - last < Self.debounceSeconds { return .skip(reason: "debounce") }
        lastAcceptedAt = now
        return .describe
    }

    /// Decide the deferred press, if any. Poll it while `hasPendingDescribe` (the app: every 0.25 s).
    /// - Parameters:
    ///   - now: the caller's clock.
    ///   - listening: as in `press`.
    ///   - launchLinePending: as in `press`.
    ///   - commandGeneration: as in `press`; a different value than at the press drops it.
    /// - Returns: `.none`, `.wait`, `.fire` (describe now) or `.drop(reason:)`.
    public mutating func resolvePending(now: Double, listening: Bool, launchLinePending: Bool,
                                        commandGeneration: Int = 0) -> PendingOutcome {
        guard let p = pending else { return .none }
        guard now.isFinite else { return .wait }
        if commandGeneration != p.generation {
            pending = nil
            clearSince = nil
            return .drop(reason: "other_command")
        }
        if now < p.at || now - p.at > Self.pendingMaxAgeSeconds {
            pending = nil
            clearSince = nil
            return .drop(reason: "expired")
        }
        if now - launchedAt < Self.launchGraceSeconds || listening || launchLinePending {
            clearSince = nil
            return .wait
        }
        let since = clearSince ?? now
        clearSince = since
        guard now - since >= Self.pendingSettleSeconds else { return .wait }
        pending = nil
        clearSince = nil
        lastAcceptedAt = now
        return .fire
    }
}
