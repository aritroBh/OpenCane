//
//  SensorModeInterlock.swift
//  CaneKitLogic
//
//  Pure route-time policy for AR session configuration changes. `AppModel` owns the effects
//  (ARSession, speech and settings); this type decides whether a requested sensor-mode restart
//  is safe while a route is being prepared or guided.
//
//  Safety rule: a user must never create a camera/depth gap by changing face tracking or camera
//  rate during a route. Thermal mesh changes are different: the processor can stop using mesh
//  classifications immediately, while the expensive ARSession reconfiguration waits until the
//  route is over. Tests: SensorModeInterlockTests.swift.
//

import Foundation

/// AR-backed modes whose configuration changes can restart the camera/depth session.
public enum SensorMode: String, CaseIterable, Sendable, Equatable, Hashable {
    /// `ARWorldTrackingConfiguration.userFaceTrackingEnabled` (TrueDepth + LiDAR).
    case faceTracking
    /// The 30/60 fps ARKit video format.
    case highFrameRate
    /// Classified scene reconstruction / mesh lookup.
    case meshClassification
}

/// Why a sensor-mode change was requested.
public enum SensorModeRequestSource: String, Sendable, Equatable {
    /// A walker or a settings/intent action explicitly requested the change.
    case user
    /// The thermal watchdog requested a mesh downgrade or restoration.
    case thermal
}

/// Decision returned to the app adapter. The adapter must not restart ARKit for a refusal or a
/// deferred thermal request.
public enum SensorModeDecision: String, Sendable, Equatable {
    /// The route is idle; the adapter may apply the setting and restart if needed.
    case allowRestart
    /// A user request was refused while a route is warming up.
    case refuseWhileStarting
    /// A user request was refused while guidance is active.
    case refuseWhileNavigating
    /// A user request was refused while a previous route's camera teardown is draining.
    case refuseWhileFinishing
    /// Thermal may change processor behavior now, but the ARSession restart waits for route end.
    case deferUntilRouteEnds
}

/// Pure state machine preventing AR session reconfiguration from creating a blind window during
/// route start or navigation. Owned by `AppModel` on the main actor.
public struct SensorModeInterlock: Sendable, Equatable {
    /// The route lifecycle relevant to sensor changes.
    public enum Phase: String, Sendable, Equatable {
        /// No route request or guidance is active.
        case idle
        /// A route request is waiting for fresh trusted depth.
        case starting
        /// Navigation is actively guiding the walker.
        case navigating
        /// Guidance has ended, but a camera transition is still draining before deferred
        /// configuration may be applied. User changes remain blocked in this phase.
        case finishing
    }

    /// Current route phase, exposed for diagnostics and tests.
    public private(set) var phase: Phase = .idle
    /// Thermal changes that requested an AR restart while a route was active. A set keeps rapid
    /// thermal flapping idempotent; the adapter applies the final requested configuration once.
    private var deferredModes: Set<SensorMode> = []

    /// Creates an idle policy with no deferred thermal changes. Caller: `AppModel` at launch;
    /// tests instantiate it directly to exercise route transitions without ARKit.
    public init() {}

    /// Reserve the sensor configuration while a route-start freshness gate is running.
    public mutating func routeStartQueued() {
        phase = .starting
    }

    /// Mark the moment the normal route effects begin.
    public mutating func routeStarted() {
        phase = .navigating
    }

    /// Mark the end of guidance while an external camera transition is still in flight. The
    /// adapter calls `routeEnded()` only after that transition drains; keeping a non-idle phase
    /// prevents a deferred thermal restart from racing a new route or a still-running MultiCam
    /// session.
    public mutating func routeFinishing() {
        guard phase != .idle else { return }
        phase = .finishing
    }

    /// End a queued start without guidance. Returns any thermal modes whose restart can now run.
    public mutating func routeStartCanceled() -> [SensorMode] {
        finishRoute()
    }

    /// End guidance (arrival, Stop or a deliberate route replacement). Returns deferred thermal
    /// modes in a stable order so callers and logs are deterministic.
    public mutating func routeEnded() -> [SensorMode] {
        finishRoute()
    }

    /// Decide whether the adapter may perform the ARSession restart for one mode.
    public mutating func request(_ mode: SensorMode,
                                 source: SensorModeRequestSource) -> SensorModeDecision {
        guard phase != .idle else { return .allowRestart }
        switch source {
        case .user:
            switch phase {
            case .starting: return .refuseWhileStarting
            case .navigating: return .refuseWhileNavigating
            case .finishing: return .refuseWhileFinishing
            case .idle: return .allowRestart
            }
        case .thermal:
            deferredModes.insert(mode)
            return .deferUntilRouteEnds
        }
    }

    /// Whether at least one thermal restart is waiting for the route to end.
    public var hasDeferredRestart: Bool { !deferredModes.isEmpty }

    private mutating func finishRoute() -> [SensorMode] {
        phase = .idle
        let result = deferredModes.sorted { $0.rawValue < $1.rawValue }
        deferredModes.removeAll(keepingCapacity: true)
        return result
    }
}
