//
//  DepthReadiness.swift
//  CaneKitLogic
//
//  Pure route-start gate for the ARKit/LiDAR safety channel. The app adapter supplies the
//  per-frame facts (tracking state, scene-depth availability and the existing gyro trust bit),
//  while this type owns the consecutive-frame and timeout rules so they can be tested without
//  ARKit or a real camera.
//

import Foundation

/// The state of the short ARKit warm-up window used before starting route guidance.
public enum DepthReadinessState: String, Sendable, Equatable {
    /// No route-start request is waiting for depth.
    case idle
    /// A request is waiting for enough consecutive trusted depth frames.
    case warming
    /// The minimum freshness bar has been met.
    case ready
    /// The bounded warm-up expired without recovery.
    case timedOut
}

/// Tracks continuity of the published depth-report stream across a transition boundary.
/// `AsyncStream.bufferingNewest(1)` may drop an intermediate report; the adapter must then discard
/// the newest report as readiness evidence and earn a wholly contiguous run again. This stays in
/// CaneKitLogic so the policy is testable without ARKit. Caller: `DepthEngine.ingest`.
public struct DepthFrameContinuity: Sendable, Equatable {
    private var baseline: Int?
    private var last: Int?

    public init() {}

    /// Start a new stream window. Reports at or before `after` are pre-transition evidence.
    public mutating func begin(after sequence: Int?) {
        baseline = sequence
        last = nil
    }

    /// Accept one published sequence as contiguous evidence. The first report after a known
    /// boundary must be exactly `baseline + 1`; after that every report must increment by one.
    /// A gap returns false and becomes the new anchor, so the next report can start a fresh run.
    public mutating func accepts(_ sequence: Int) -> Bool {
        defer { last = sequence }
        if let last { return sequence == last &+ 1 }
        if let baseline { return sequence == baseline &+ 1 }
        return true
    }
}

/// Pure state machine for the route-start depth interlock.
///
/// A frame counts only when all three facts are true for that same ARKit frame: camera tracking is
/// `.normal`, scene-depth semantics produced a valid map, and the existing sweep gate marked the
/// report trusted. Any invalid frame, interruption, or reconfiguration breaks the consecutive run.
/// The owner must call `poll(at:)` when no frame arrives so a dead session cannot leave a queued
/// route waiting forever. Constants are intentionally small: the existing device telemetry says
/// camera release / ARKit warm-up is about 1–3 seconds, while three reports at the normal 30 Hz
/// publish rate provide roughly 67 ms of healthy evidence after the first frame.
public struct DepthReadiness: Sendable, Equatable {
    /// Tunables kept in the logic module and injectable for deterministic tests.
    public struct Configuration: Sendable, Equatable {
        /// Number of consecutive qualifying reports required.
        public var requiredFrames: Int
        /// Maximum allowed gap between qualifying reports before the run restarts.
        public var maxFrameGap: TimeInterval
        /// Maximum time spent waiting for recovery.
        public var timeout: TimeInterval

        /// Creates a bounded freshness policy, clamping invalid caller values to safe minima.
        public init(requiredFrames: Int = 3,
                    maxFrameGap: TimeInterval = 0.5,
                    timeout: TimeInterval = 5.0) {
            self.requiredFrames = max(1, requiredFrames)
            self.maxFrameGap = max(0, maxFrameGap)
            self.timeout = max(0, timeout)
        }
    }

    /// The shipped warm-up policy. The 5-second bound covers the documented 1–3 second camera
    /// transition while still failing promptly when ARKit never recovers.
    public static let standardConfiguration = Configuration()

    /// The policy used by this instance.
    public let configuration: Configuration
    /// Current state, observed by the app adapter.
    public private(set) var state: DepthReadinessState = .idle
    /// Number of qualifying frames in the current consecutive run.
    public private(set) var consecutiveFrames = 0

    private var startedAt: TimeInterval?
    private var lastQualifyingFrameAt: TimeInterval?

    /// Creates an idle gate. A route request starts the gate with `begin(at:)`.
    public init(configuration: Configuration = DepthReadiness.standardConfiguration) {
        self.configuration = configuration
    }

    /// Begin (or restart) a bounded warm-up window.
    @discardableResult
    public mutating func begin(at now: TimeInterval) -> DepthReadinessState {
        state = .warming
        consecutiveFrames = 0
        startedAt = now
        lastQualifyingFrameAt = nil
        return state
    }

    /// Feed one report's same-frame readiness facts.
    @discardableResult
    public mutating func frame(at now: TimeInterval,
                               trackingNormal: Bool,
                               sceneDepthAvailable: Bool,
                               reportTrusted: Bool) -> DepthReadinessState {
        guard state == .warming else { return state }
        guard !expired(at: now) else {
            state = .timedOut
            return state
        }

        let qualifies = trackingNormal && sceneDepthAvailable && reportTrusted
        guard qualifies else {
            consecutiveFrames = 0
            lastQualifyingFrameAt = nil
            return state
        }

        if let previous = lastQualifyingFrameAt,
           now - previous > configuration.maxFrameGap {
            consecutiveFrames = 1
        } else {
            consecutiveFrames += 1
        }
        lastQualifyingFrameAt = now
        if consecutiveFrames >= configuration.requiredFrames {
            state = .ready
        }
        return state
    }

    /// Reset the consecutive run after an AR interruption, pause/resume, or session reconfigure.
    /// The overall timeout does **not** restart: a request must remain bounded even when a session
    /// repeatedly interrupts. Only the freshness evidence is earned again after the recovery.
    @discardableResult
    public mutating func invalidate(at _: TimeInterval) -> DepthReadinessState {
        guard state != .idle else { return state }
        state = .warming
        consecutiveFrames = 0
        lastQualifyingFrameAt = nil
        return state
    }

    /// Check the timeout when no frame has arrived.
    @discardableResult
    public mutating func poll(at now: TimeInterval) -> DepthReadinessState {
        guard state == .warming, expired(at: now) else { return state }
        state = .timedOut
        return state
    }

    /// Cancel a pending route-start request and return to idle.
    @discardableResult
    public mutating func cancel() -> DepthReadinessState {
        state = .idle
        consecutiveFrames = 0
        startedAt = nil
        lastQualifyingFrameAt = nil
        return state
    }

    private func expired(at now: TimeInterval) -> Bool {
        guard let startedAt else { return false }
        return now - startedAt >= configuration.timeout
    }
}
