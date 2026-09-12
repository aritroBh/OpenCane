//
//  DepthReadiness.swift
//  CaneKitLogic
//
//  Pure route-start gate for the ARKit/LiDAR safety channel. The app adapter supplies the
//  per-frame facts (tracking state, scene-depth availability and the existing gyro trust bit),
//  while this type owns the consecutive-frame and timeout rules so they can be tested without
//  ARKit or a real camera.
//
//  Why (Steps 22 / 25): a route used to start while ARKit was still warming up or recovering from
//  the "Both cameras" teardown, so the first seconds of guidance had no obstacle channel. Guidance
//  now waits for fresh, same-frame evidence that depth works — bounded, so a dead camera fails
//  loudly ("Obstacle detection is not ready. Route did not start.", `.safety`) instead of leaving
//  the walker waiting. The no-LiDAR and camera-denied paths deliberately skip this gate and guide
//  with GPS only (AGENTS.md "How we engineer" 6).
//
//  Owner / callers: `DepthEngine` (main actor) holds one `DepthReadiness` and one
//  `DepthFrameContinuity`: `beginReadiness(at:)` / `pollReadiness(at:)` / `cancelReadiness()` for
//  `AppModel.queueRouteStart`, `frame(at:…)` from `ingest(_:)` for every post-baseline report,
//  `invalidate(at:)` on interruption, pause / resume, configuration re-runs and two-camera
//  transitions. State changes reach `AppModel.depthReadinessChanged` (ready → `startRouteNow`;
//  timedOut → `failQueuedRouteStart`) and the `route_readiness` trip-log event.
//  Clock: every `now` here is `ProcessInfo.systemUptime` supplied by the app (not the ARKit frame
//  timestamp), so `maxFrameGap` measures gaps between *consumed* reports on the main actor.
//  Tests: DepthReadinessTests.swift (7).
//

import Foundation

/// The state of the short ARKit warm-up window used before starting route guidance.
/// Mirrored in `DepthEngine.readinessState`; `ready` and `timedOut` are terminal until the next
/// `begin` / `invalidate` / `cancel`.
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
/// ⚠ `accepts` is `mutating`: call it into a local before `#expect` (a `mutating` call inside
/// `#expect` does not compile — Step 27, `DepthReadinessTests`).
public struct DepthFrameContinuity: Sendable, Equatable {
    /// `LaneReport.frameSequence` of the last report published before the boundary; nil = no
    /// boundary known (the first report is accepted as-is).
    private var baseline: Int?
    /// The last sequence seen since `begin`; nil until the first `accepts`.
    private var last: Int?

    /// No boundary, nothing seen: the first sequence is accepted.
    public init() {}

    /// Start a new stream window. Reports at or before `after` are pre-transition evidence.
    /// - Parameter sequence: `DepthFrameProcessor.latestPublishedSequence()` read by `DepthEngine`
    ///   at the transition (a reconfiguration drains the processor queue first), or nil when unknown.
    public mutating func begin(after sequence: Int?) {
        baseline = sequence
        last = nil
    }

    /// Accept one published sequence as contiguous evidence. The first report after a known
    /// boundary must be exactly `baseline + 1`; after that every report must increment by one.
    /// A gap returns false and becomes the new anchor, so the next report can start a fresh run.
    /// Sequences wrap (`&+`), matching the processor's wrapping counter.
    /// - Returns: true when `sequence` is contiguous evidence; false → the caller invalidates the run.
    /// Pinned by `publishedFrameContinuityRejectsGapsAndRecovers`,
    /// `publishedFrameContinuityHonorsTransitionBoundary`.
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
    /// Tunables kept in the logic module and injectable for deterministic tests. The app uses only
    /// `standardConfiguration` (3 frames / 0.5 s / 5 s; also logged in `route_readiness`).
    public struct Configuration: Sendable, Equatable {
        /// Number of consecutive qualifying reports required (clamped ≥ 1).
        public var requiredFrames: Int
        /// Maximum allowed gap (s) between qualifying reports before the run restarts at 1 (≥ 0).
        public var maxFrameGap: TimeInterval
        /// Maximum time (s) from `begin` before the window is `timedOut` (≥ 0). ⚠ `AppModel` also
        /// sleeps this long in its own request timer, which covers a camera transition that never
        /// lets `begin` run at all.
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

    /// `now` of the `begin` that opened the window; nil when idle. Not moved by `invalidate`, so
    /// repeated interruptions cannot extend the request past `timeout`.
    private var startedAt: TimeInterval?
    /// `now` of the last qualifying frame in the current run; nil after a break.
    private var lastQualifyingFrameAt: TimeInterval?

    /// Creates an idle gate. A route request starts the gate with `begin(at:)`.
    public init(configuration: Configuration = DepthReadiness.standardConfiguration) {
        self.configuration = configuration
    }

    /// Begin (or restart) a bounded warm-up window: state `warming`, empty run, deadline
    /// `now + timeout`. Pinned by `coldStartNeedsConsecutiveTrustedDepthFrames`.
    /// - Parameter now: seconds (the app passes `systemUptime`).
    @discardableResult
    public mutating func begin(at now: TimeInterval) -> DepthReadinessState {
        state = .warming
        consecutiveFrames = 0
        startedAt = now
        lastQualifyingFrameAt = nil
        return state
    }

    /// Feed one report's same-frame readiness facts. Ignored unless `warming`; at or past the
    /// deadline it times out even when the frame qualifies. A non-qualifying frame empties the run.
    /// - Parameters:
    ///   - now: seconds, same clock as `begin`.
    ///   - trackingNormal: `LaneReport.trackingNormal` (read from that exact `ARFrame`).
    ///   - sceneDepthAvailable: `LaneReport.depthAvailable`.
    ///   - reportTrusted: `LaneReport.isTrusted` (the sweep gate).
    /// - Returns: the state after this frame. Pinned by `normalFastWarmupClearsImmediately`,
    ///   `staleGapRestartsTheRun`.
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
    /// A `ready` or `timedOut` gate goes back to `warming` (no-op when idle). Pinned by
    /// `interruptionAndResumeRequireFreshEvidence`.
    @discardableResult
    public mutating func invalidate(at _: TimeInterval) -> DepthReadinessState {
        guard state != .idle else { return state }
        state = .warming
        consecutiveFrames = 0
        lastQualifyingFrameAt = nil
        return state
    }

    /// Check the timeout when no frame has arrived (`AppModel` polls every 100 ms while a route
    /// waits). Pinned by `warmupTimesOutWithoutRecovery`.
    @discardableResult
    public mutating func poll(at now: TimeInterval) -> DepthReadinessState {
        guard state == .warming, expired(at: now) else { return state }
        state = .timedOut
        return state
    }

    /// Cancel a pending route-start request and return to idle (Stop, a newer destination, or the
    /// route starting after `ready`).
    @discardableResult
    public mutating func cancel() -> DepthReadinessState {
        state = .idle
        consecutiveFrames = 0
        startedAt = nil
        lastQualifyingFrameAt = nil
        return state
    }

    /// True once `timeout` has elapsed since `begin`; false when idle.
    private func expired(at now: TimeInterval) -> Bool {
        guard let startedAt else { return false }
        return now - startedAt >= configuration.timeout
    }
}
