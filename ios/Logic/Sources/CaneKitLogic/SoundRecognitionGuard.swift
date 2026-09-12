//
//  SoundRecognitionGuard.swift
//  CaneKitLogic
//
//  Pure lifecycle policy for the optional microphone sound-recognition feature. AVFoundation is
//  deliberately kept out of this file: `SoundWatcher` supplies route snapshots and forwards
//  permission, interruption and analyser events from the app's main actor.
//
//  The feature is advisory and off by default. A degraded input or output route therefore stops
//  only sound recognition, restores the app's normal `.playback` session in the adapter, and lets
//  navigation, LiDAR and the existing speech/haptic cues continue. The first failure wins; after
//  that the guard is idle, so a burst of route notifications cannot thrash the audio session or
//  repeat a spoken failure.
//
//  Why (Step 28, "sound recognition fails safe across its whole microphone lifetime"): the
//  microphone is untrusted unless route and analyser stay healthy for the entire run. A switch to
//  Bluetooth hands-free (HFP) drops AirPods to phone-call quality and degrades the HRTF beacon
//  (AGENTS.md hard rule 7); a revoked permission delivers silence that sounds exactly like "no
//  sirens"; and a permission grant that lands after the walker turned the switch off must not start
//  the microphone behind an "off" switch. Each is one testable decision here. The AirPods HFP route
//  itself is still device-unmeasured: this is graceful degradation, not a primary safety sensor.
//
//  Owner: `SoundWatcher` (app, main actor) holds one `SoundRecognitionGuard` (`lifecycle`) and turns
//  each `.stop(reason)` into teardown + one spoken `failureMessage(for:)`. `SpeechQueue` builds the
//  `SoundRecognitionRoute` snapshots (`microphoneRoute(_:)`) and reports route changes through
//  `onMicrophoneRouteChanged`. Isolation: nonisolated `Sendable` values; mutated only on main.
//  Tests: SoundAlertsTests.swift (`midSessionHFPInputDegradationStopsRecognition`,
//  `analyzerThrowStopsOnce`, `permissionRevokedMidSessionStopsRecognition`,
//  `permissionRaceCancellationInvalidatesLateGrant`, `rapidRouteFlappingFailsOnceAndStaysIdle`,
//  `startupInputRouteSettlesWithoutDisablingTheFeature`).
//

import Foundation

/// Quality of the input port feeding the sound classifier.
public enum SoundInputQuality: String, Equatable, Sendable {
    /// A negotiated input that is not the Bluetooth hands-free (HFP) path.
    case usable
    /// Bluetooth hands-free / phone-call-quality input. It is never accepted for this feature.
    case hfp
    /// No input port is present (or its format has dropped out).
    case unavailable
}

/// The small, Sendable portion of an `AVAudioSession` route the microphone feature must trust.
/// `SpeechQueue` builds this value from AVFoundation port types; Logic tests use it as a fake.
public struct SoundRecognitionRoute: Equatable, Sendable {
    /// Stable description of the output ports, including port UID/name (for example
    /// `Speaker[...]` or `BluetoothA2DP[...]`).
    public let output: String
    /// Stable description of the input ports, including port UID/name (for example
    /// `BuiltInMic[...]` or `BluetoothHFP[...]`).
    public let input: String
    /// Whether the input can be used without degrading the beacon / speech route.
    public let inputQuality: SoundInputQuality
    /// True when the output is already on the Bluetooth hands-free path. This is unsafe even if
    /// Core Audio still reports a built-in input, because speech and the beacon are already in
    /// phone-call quality.
    public let outputIsHFP: Bool

    /// Creates a snapshot.
    /// - Parameters:
    ///   - output: output port description (identity compared verbatim by `routeChanged`).
    ///   - input: input port description.
    ///   - inputQuality: classified by the adapter from the port type.
    ///   - outputIsHFP: the adapter's exact port-type bit; nil derives it from `output` containing
    ///     "BluetoothHFP" (test fixtures).
    public init(output: String, input: String, inputQuality: SoundInputQuality,
                outputIsHFP: Bool? = nil) {
        self.output = output
        self.input = input
        self.inputQuality = inputQuality
        // The default keeps fake routes terse while the AVFoundation adapter supplies the exact
        // port-type bit. Port descriptions include the raw type, so this also catches hand-built
        // HFP fixtures in Logic tests.
        self.outputIsHFP = outputIsHFP ?? output.contains("BluetoothHFP")
    }

    /// A route is safe only when the input is present/not HFP and the output is not HFP.
    public var isUsable: Bool { inputQuality == .usable && !outputIsHFP }
}

/// Why the optional sound-recognition feature was taken down.
public enum SoundRecognitionFailure: String, Equatable, Sendable {
    /// The output route changed, which could steal the HRTF beacon or change speech quality.
    case outputRouteChanged
    /// The input route changed to HFP or another low-quality port.
    case inputRouteDegraded
    /// The input port disappeared before or during startup.
    case inputUnavailable
    /// SoundAnalysis reported an error or the audio tap/engine failed.
    case analyzerFailed
    /// An AVAudioSession interruption began and recognition can no longer be trusted.
    case interrupted
    /// The user revoked microphone permission while recognition was active.
    case permissionRevoked
    /// Permission was denied at the start.
    case permissionDenied
}

/// Result of a lifecycle event. The app adapter performs the effect; Logic only decides it.
public enum SoundRecognitionDecision: Equatable, Sendable {
    /// The event does not apply to the current state (for example, a late callback after stop).
    case ignored
    /// Continue the current startup or recognition session.
    case continueRunning
    /// Stop recognition and surface the supplied reason once.
    case stop(SoundRecognitionFailure)
    /// Cancel a permission/start continuation without surfacing a failure.
    case cancelPendingStart
}

/// Generation- and route-aware state machine for microphone sound recognition.
///
/// All methods are mutating value operations so tests can drive it with fake notifications. The
/// AVFoundation owner (`SoundWatcher`) keeps one instance on the main actor and performs the
/// actual teardown after a `.stop` decision. Numbers in this policy are intentionally absent;
/// the permission poll cadence is exposed separately as a small adapter constant below.
public struct SoundRecognitionGuard: Equatable, Sendable {
    /// Permission polling cadence for the AVFoundation adapter. iOS exposes no dependable
    /// mid-session permission notification; 0.5 s bounds the unsafe window without waking an idle
    /// app (the task exists only while the microphone session is held).
    public static let permissionPollInterval: Double = 0.5

    /// Lifecycle state visible to tests and the adapter's ownership checks.
    public enum State: Equatable, Sendable {
        /// Nothing holds the microphone; every late callback is `.ignored`.
        case idle
        /// The system permission prompt is up; only a resolution carrying this generation counts.
        case awaitingPermission(generation: UInt64)
        /// Permission granted, session and tap being set up. `route` is nil until `sessionStarted`
        /// records the baseline; route notifications before that are ignored.
        case starting(generation: UInt64, route: SoundRecognitionRoute?)
        /// The analyser is live against this route baseline; any identity change stops it.
        case running(route: SoundRecognitionRoute)
    }

    /// Current lifecycle state (starts `.idle`).
    public private(set) var state: State = .idle
    /// Last generation token handed out (wrapping add); a new one per permission request or start,
    /// so a callback from an abandoned attempt can never match the current one.
    private var nextGeneration: UInt64 = 0

    /// Creates an idle guard.
    public init() {}

    /// Begins an asynchronous microphone-permission request and returns its generation token.
    /// A second request while one is already pending is ignored, preventing duplicate callbacks.
    /// - Returns: the token to pass back to `permissionResolved`, or nil when not idle.
    public mutating func beginPermissionRequest() -> UInt64? {
        guard case .idle = state else { return nil }
        nextGeneration &+= 1
        state = .awaitingPermission(generation: nextGeneration)
        return nextGeneration
    }

    /// Begins setup when permission is already granted. Returns false if a start is already live.
    public mutating func beginStart() -> Bool {
        guard case .idle = state else { return false }
        nextGeneration &+= 1
        state = .starting(generation: nextGeneration, route: nil)
        return true
    }

    /// Resolves a permission request only when its generation still owns the pending start.
    /// A stale callback (including one arriving after the user switched the feature off) is inert.
    public mutating func permissionResolved(granted: Bool, generation: UInt64) -> SoundRecognitionDecision {
        guard case .awaitingPermission(let expected) = state, expected == generation else {
            return .ignored
        }
        guard granted else {
            state = .idle
            return .stop(.permissionDenied)
        }
        // The adapter calls `beginStart()` next. Keeping the guard idle here makes that handoff
        // explicit and keeps the permission callback from touching AVFoundation itself.
        state = .idle
        return .continueRunning
    }

    /// Records the route after `.playAndRecord` is granted and before the tap is installed. An
    /// already-HFP output is rejected even when the input happens to be the built-in mic.
    public mutating func sessionStarted(route: SoundRecognitionRoute) -> SoundRecognitionDecision {
        guard case .starting(let generation, _) = state else { return .ignored }
        if route.inputQuality == .hfp || route.outputIsHFP {
            state = .idle
            return .stop(.inputRouteDegraded)
        }
        // During the first few hundred milliseconds iOS can publish the output route before an
        // input port/format exists. Keep the startup state (with its route baseline) so the adapter
        // may perform the one bounded format retry; `recognitionStarted` is the gate that requires
        // a usable input before the analyser is declared live.
        state = .starting(generation: generation, route: route)
        return .continueRunning
    }

    /// Marks the analyser/tap live after the input format has become usable.
    /// A route that is still not `isUsable` here stops with `.inputRouteDegraded` (HFP either side)
    /// or `.inputUnavailable`; this is the last gate before the classifier is trusted.
    public mutating func recognitionStarted(route: SoundRecognitionRoute) -> SoundRecognitionDecision {
        guard case .starting = state else { return .ignored }
        guard route.isUsable else {
            state = .idle
            return .stop(route.inputQuality == .hfp || route.outputIsHFP
                         ? .inputRouteDegraded : .inputUnavailable)
        }
        state = .running(route: route)
        return .continueRunning
    }

    /// Handles a route notification for the full recognition lifetime.
    ///
    /// Any output identity change stops immediately because it can move speech/beacon audio. An
    /// input identity or quality change also stops: even a brief HFP or missing-input interval is
    /// not allowed to masquerade as a healthy classifier. Once stopped, subsequent flapping events
    /// are ignored until the user explicitly starts the feature again.
    public mutating func routeChanged(_ route: SoundRecognitionRoute) -> SoundRecognitionDecision {
        let held: SoundRecognitionRoute
        switch state {
        case .starting(_, let route):
            guard let route else { return .ignored }
            held = route
        case .running(let route):
            held = route
        case .idle, .awaitingPermission:
            return .ignored
        }
        if route.output != held.output || route.outputIsHFP != held.outputIsHFP {
            state = .idle
            return .stop(.outputRouteChanged)
        }
        if route.input == held.input && route.inputQuality == held.inputQuality {
            return .continueRunning
        }
        // Input can legitimately appear a moment after `.playAndRecord` activation. This is the
        // only transition allowed without stopping, and only while the analyser is still starting;
        // once recognition is live, any input identity/quality change is a hard stop.
        if case .starting(let generation, _ ) = state,
           held.inputQuality == .unavailable, route.inputQuality == .usable {
            state = .starting(generation: generation, route: route)
            return .continueRunning
        }
        state = .idle
        return .stop(route.inputQuality == .hfp ? .inputRouteDegraded : .inputUnavailable)
    }

    /// Stops on a SoundAnalysis / tap / engine failure.
    public mutating func analyzerFailed() -> SoundRecognitionDecision {
        guard isActive else { return .ignored }
        state = .idle
        return .stop(.analyzerFailed)
    }

    /// Stops on an audio-session interruption; a later interruption-ended notification cannot
    /// resurrect a session the app has already handed back.
    public mutating func interruptionBegan() -> SoundRecognitionDecision {
        guard isActive else { return .ignored }
        state = .idle
        return .stop(.interrupted)
    }

    /// Stops when the system reports that microphone permission was revoked mid-session.
    public mutating func permissionRevoked() -> SoundRecognitionDecision {
        guard isActive else { return .ignored }
        state = .idle
        return .stop(.permissionRevoked)
    }

    /// Cancels an outstanding permission/start continuation without speaking a failure line.
    /// Calling this for an already-running session is a normal user stop and is also silent here;
    /// the adapter owns the ordinary teardown path.
    public mutating func cancel() -> SoundRecognitionDecision {
        switch state {
        case .awaitingPermission, .starting:
            state = .idle
            return .cancelPendingStart
        case .running:
            state = .idle
            return .continueRunning
        case .idle:
            return .ignored
        }
    }

    /// True while a session or its asynchronous startup owns the microphone.
    public var isActive: Bool {
        switch state {
        case .idle: return false
        case .awaitingPermission, .starting, .running: return true
        }
    }
}
