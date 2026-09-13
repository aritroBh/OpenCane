//
//  VoiceInputGuard.swift
//  CaneKitLogic
//
//  Pure lifecycle policy for push-to-talk voice input. AVFoundation and Speech framework types
//  stay in the app target; `VoiceInputEngine` supplies Sendable route snapshots and forwards
//  interruption, recognition and permission events here before touching its audio graph.
//
//  A voice transcript is never safety-critical, but a stale or silently empty transcript can make
//  the walker believe a spoken command was heard. Any route/interruption/recognizer/permission
//  failure therefore stops the current capture and drops the partial text. The first failure wins
//  so a burst of callbacks cannot thrash the shared audio session or repeat failure cues.
//

import Foundation

/// Why push-to-talk capture was taken down.
public enum VoiceInputFailure: String, Equatable, Sendable {
    /// The output identity moved while the microphone was held.
    case outputRouteChanged
    /// Input moved to Bluetooth HFP or another low-quality path.
    case inputRouteDegraded
    /// The input port disappeared while capture was active.
    case inputUnavailable
    /// Speech recognition or its audio graph reported an error.
    case recognitionFailed
    /// An audio-session interruption began; a partial transcript is not trusted.
    case interrupted
    /// Microphone or speech permission was revoked during capture.
    case permissionRevoked
    /// Permission was denied before capture could start.
    case permissionDenied
}

/// Result of a voice-input lifecycle event. The AVFoundation adapter performs teardown and cues;
/// this type only decides whether the current capture may continue.
public enum VoiceInputDecision: Equatable, Sendable {
    /// The event belongs to an old or already-finished capture.
    case ignored
    /// Keep the current permission/start/listening flow alive.
    case continueRunning
    /// Stop capture and surface the supplied reason exactly once.
    case stop(VoiceInputFailure)
    /// Cancel a pending authorization/start without speaking a failure line.
    case cancelPendingStart
}

/// Generation- and route-aware state machine for push-to-talk capture.
///
/// `VoiceInputEngine` owns one value on the main actor. Tests drive it with fake routes and
/// lifecycle events, so no AVAudioEngine, NotificationCenter or Speech framework object crosses
/// into `CaneKitLogic`.
public struct VoiceInputGuard: Equatable, Sendable {
    /// Permission polling cadence used by the AVFoundation adapter while capture is live. iOS
    /// has no dependable mid-session permission notification; half a second bounds the unsafe
    /// window without waking an idle app (the task exists only while the microphone is held).
    public static let permissionPollInterval: Double = 0.5

    /// Capture lifecycle visible to the adapter and tests.
    public enum State: Equatable, Sendable {
        case idle
        case awaitingPermission(generation: UInt64)
        case starting(route: SoundRecognitionRoute?)
        case listening(route: SoundRecognitionRoute)
    }

    public private(set) var state: State = .idle
    private var nextPermissionGeneration: UInt64 = 0

    public init() {}

    /// Begins the combined microphone/Speech authorization flow. A second request while one is
    /// pending is ignored; the returned generation is required to resolve the original callback.
    public mutating func beginPermissionRequest() -> UInt64? {
        guard case .idle = state else { return nil }
        nextPermissionGeneration &+= 1
        state = .awaitingPermission(generation: nextPermissionGeneration)
        return nextPermissionGeneration
    }

    /// Resolves a permission callback only when it belongs to the current request. A stale grant
    /// (for example, after the user canceled the prompt) is inert and cannot start the microphone.
    public mutating func permissionResolved(granted: Bool,
                                            generation: UInt64) -> VoiceInputDecision {
        guard case .awaitingPermission(let expected) = state, expected == generation else {
            return .ignored
        }
        state = .idle
        return granted ? .continueRunning : .stop(.permissionDenied)
    }

    /// Begins microphone/session setup after both permissions are confirmed. A second start while
    /// one is pending is ignored.
    public mutating func beginStart() -> Bool {
        guard case .idle = state else { return false }
        state = .starting(route: nil)
        return true
    }

    /// Records the route after `.playAndRecord` activation. HFP is never accepted; a missing
    /// input may settle briefly before the engine's format check and is handled by `routeChanged`.
    public mutating func sessionStarted(route: SoundRecognitionRoute) -> VoiceInputDecision {
        guard case .starting = state else { return .ignored }
        if route.inputQuality == .hfp || route.outputIsHFP {
            state = .idle
            return .stop(.inputRouteDegraded)
        }
        state = .starting(route: route)
        return .continueRunning
    }

    /// Marks the tap/recognizer live only after a usable input format has been observed.
    public mutating func recognitionStarted(route: SoundRecognitionRoute) -> VoiceInputDecision {
        guard case .starting = state else { return .ignored }
        guard route.isUsable else {
            state = .idle
            return .stop(route.inputQuality == .hfp || route.outputIsHFP
                         ? .inputRouteDegraded : .inputUnavailable)
        }
        state = .listening(route: route)
        return .continueRunning
    }

    /// Handles a route notification for the entire capture lifetime. Output identity changes are
    /// unsafe even when the input remains usable because the beacon/speech route may have moved.
    /// Input changes are also hard stops once listening; the only startup exception is `none →
    /// usable` while the input format settles.
    public mutating func routeChanged(_ route: SoundRecognitionRoute) -> VoiceInputDecision {
        let held: SoundRecognitionRoute
        switch state {
        case .starting(let route):
            guard let route else { return .ignored }
            held = route
        case .listening(let route):
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
        if case .starting = state,
           held.inputQuality == .unavailable, route.inputQuality == .usable {
            state = .starting(route: route)
            return .continueRunning
        }
        state = .idle
        return .stop(route.inputQuality == .hfp ? .inputRouteDegraded : .inputUnavailable)
    }

    /// Stops on an SFSpeechRecognizer error or an audio-engine configuration failure.
    public mutating func recognitionFailed() -> VoiceInputDecision {
        guard isActive else { return .ignored }
        state = .idle
        return .stop(.recognitionFailed)
    }

    /// Stops on an audio-session interruption; the later `.ended` event cannot resurrect a stale
    /// request. The user can explicitly start a fresh capture after the interruption ends.
    public mutating func interruptionBegan() -> VoiceInputDecision {
        guard isActive else { return .ignored }
        state = .idle
        return .stop(.interrupted)
    }

    /// Stops when the system reports microphone or speech permission loss during capture.
    public mutating func permissionRevoked() -> VoiceInputDecision {
        guard isActive else { return .ignored }
        state = .idle
        return .stop(.permissionRevoked)
    }

    /// Cancels a pending start silently, or performs the ordinary user stop of a live capture.
    public mutating func cancel() -> VoiceInputDecision {
        switch state {
        case .awaitingPermission:
            state = .idle
            return .cancelPendingStart
        case .starting:
            state = .idle
            return .cancelPendingStart
        case .listening:
            state = .idle
            return .continueRunning
        case .idle:
            return .ignored
        }
    }

    /// True while setup or capture owns the microphone.
    public var isActive: Bool {
        switch state {
        case .idle, .awaitingPermission: return false
        case .starting, .listening: return true
        }
    }
}
