//
//  IslandPolicy.swift
//  CaneKitLogic
//
//  Pure decisions behind the Dynamic Island / Live Activity (Step 64): which phase it shows, what
//  it may claim about obstacle sensing, how relevant it is to the system, and when an obstacle
//  escalation may light the lock screen with an `AlertConfiguration`.
//
//  Why it exists: the Step 64 audit found the island saying "Path clear" (green check) with the
//  screen locked while `AppModel.scenePhaseChanged(.background)` had paused depth — nothing in the
//  payload said whether the sensors were running. `IslandSensing` is that fact, and the widget may
//  only draw "clear" when it is `.live` (`showsClear`). The phases give the island something true
//  to say before, around and after the walk (warming countdown, listening, indoor steps, stopped).
//
//  Owner: module `navigation-trip`. Callers: `LiveActivityController` (app), which converts these
//  raw values into the widget payload `NavActivityAttributes.ContentState` (ios/Shared — the widget
//  does not link this package, so it mirrors `showsClear` with a ⚠ comment).
//  Isolation: value types and a caseless enum, nonisolated, Sendable.
//  Tests: IslandPolicyTests.swift (`IslandPhasePolicyTests`, `IslandAlertLevelTests`,
//  `IslandAlertThrottleTests`).
//

import Foundation

/// What the Live Activity is about right now. Raw values are the wire strings of
/// `NavActivityAttributes.ContentState.phase`.
public enum IslandPhase: String, Sendable, Codable, CaseIterable {
    /// Route queued; depth readiness gate counting down (`AppModel.queueRouteStart`).
    case warming
    /// Outdoor route guidance.
    case walking
    /// Indoor step script (`IndoorGuide`), step i of n.
    case indoor
    /// Push-to-talk microphone open (or starting).
    case listening
    /// Assistant answering (`ConversationCoordinator.isProcessing`).
    case thinking
    /// Final state on arrival (set by `LiveActivityController.end(final:)`, never by `decide`).
    case arrived
    /// Final state on Stop (set by `LiveActivityController.end(stopped:)`, never by `decide`).
    case stopped

    /// Tolerant decode: an unknown string (a newer app build) is `.walking`, never a crash.
    public init(lenient raw: String) { self = IslandPhase(rawValue: raw) ?? .walking }
}

/// Whether obstacle detection is actually running. Raw values are the wire strings of
/// `ContentState.sensing`.
public enum IslandSensing: String, Sendable, Codable, CaseIterable {
    /// Foreground, LiDAR, trusted depth frames: the glance may say "Path clear".
    case live
    /// A route (or warm-up) with the app in the background: ARKit is paused. "Obstacles paused — unlock".
    case paused
    /// Unknown / not available: no LiDAR, warming up, untrusted frames, or an old payload.
    case none

    /// Tolerant decode: unknown is `.none` (never green).
    public init(lenient raw: String) { self = IslandSensing(rawValue: raw) ?? .none }
}

/// Obstacle urgency as the island shows it (keyline tint, alert escalation). Raw values are the
/// wire strings of `ContentState.alertLevel`.
public enum IslandAlertLevel: String, Sendable, Codable, CaseIterable {
    case none, near, curb, stop, head

    /// A torso-band obstacle at or inside this many metres is `.stop` (the same 0.6 m that arms
    /// `NearHold` and re-fires "Head height."). ⚠ Pinned by `levelFromGlance`.
    public static let stopWithinM = 0.6

    /// Escalation order: none 0, near / curb 1, stop / head 2. ⚠ Pinned by `ranks`.
    public var rank: Int {
        switch self {
        case .none: 0
        case .near, .curb: 1
        case .stop, .head: 2
        }
    }

    /// Maps the payload's obstacle glance. `distanceM == 0` means "unknown" in the payload, so a
    /// warning with no distance is `.near`, not `.stop`.
    public static func from(obstacle: LiveActivityObstacleStatus, distanceM: Double) -> IslandAlertLevel {
        switch obstacle {
        case .clear: return .none
        case .head: return .head
        case .dropOff: return .curb
        case .warning: return distanceM > 0 && distanceM <= stopWithinM ? .stop : .near
        }
    }
}

/// Everything `IslandPhasePolicy.decide` looks at, sampled by `LiveActivityController`.
public struct IslandInputs: Equatable, Sendable {
    /// `NavigationEngine.isNavigating`.
    public var navigating: Bool
    /// `AppModel.routeStartWaiting` (depth readiness gate).
    public var routeStartWaiting: Bool
    /// `VoiceInputEngine.isListening || isStarting`.
    public var voiceListening: Bool
    /// `ConversationCoordinator.isProcessing`.
    public var voiceThinking: Bool
    /// Current indoor step, 0-based (`IndoorProgress.index`); nil when not indoors.
    public var indoorStepIndex: Int?
    /// Number of indoor steps; 0 when not indoors.
    public var indoorStepCount: Int
    /// Not backgrounded (`UIApplication.applicationState != .background`): `.inactive` keeps depth
    /// running, so it counts as active for sensing. (The alert throttle's own `appActive` is the
    /// stricter `== .active`.)
    public var appActive: Bool
    /// The latest depth report is trusted (`LaneReport.isTrusted`) and depth is running.
    public var depthTrusted: Bool
    /// The phone has LiDAR (`DepthEngine.supportsMesh`).
    public var hasLiDAR: Bool

    public init(navigating: Bool = false, routeStartWaiting: Bool = false, voiceListening: Bool = false,
                voiceThinking: Bool = false, indoorStepIndex: Int? = nil, indoorStepCount: Int = 0,
                appActive: Bool = true, depthTrusted: Bool = false, hasLiDAR: Bool = true) {
        self.navigating = navigating
        self.routeStartWaiting = routeStartWaiting
        self.voiceListening = voiceListening
        self.voiceThinking = voiceThinking
        self.indoorStepIndex = indoorStepIndex
        self.indoorStepCount = indoorStepCount
        self.appActive = appActive
        self.depthTrusted = depthTrusted
        self.hasLiDAR = hasLiDAR
    }

    /// True when `indoorStepIndex` names a real step of `indoorStepCount`.
    public var hasIndoorStep: Bool {
        guard let i = indoorStepIndex else { return false }
        return indoorStepCount > 0 && i >= 0 && i < indoorStepCount
    }
}

/// The decided phase + sensing pair.
public struct IslandState: Equatable, Sendable {
    public var phase: IslandPhase
    public var sensing: IslandSensing
    public init(phase: IslandPhase, sensing: IslandSensing) {
        self.phase = phase
        self.sensing = sensing
    }
}

/// Phase priority, sensing truth and relevance for the island.
public enum IslandPhasePolicy {

    /// Phase: listening > thinking > warming > indoor > walking (obstacle alerts are not a phase —
    /// they ride on top as `alertLevel` and win the keyline and relevance). Sensing: no LiDAR →
    /// none; background with a route, a warm-up or an indoor step script (Step 62: it keeps running
    /// locked) → paused; warming → none; foreground + trusted
    /// depth → live; otherwise none. ⚠ Pinned by `phasePriority`, `backgroundWithRouteIsPaused`,
    /// `warmingIsNone`, `noLidarIsNone`, `untrustedDepthIsNone`, `backgroundIndoorIsPaused`.
    public static func decide(_ i: IslandInputs) -> IslandState {
        let phase: IslandPhase
        if i.voiceListening { phase = .listening }
        else if i.voiceThinking { phase = .thinking }
        else if i.routeStartWaiting { phase = .warming }
        else if i.hasIndoorStep { phase = .indoor }
        else { phase = .walking }
        return IslandState(phase: phase, sensing: sensing(i))
    }

    /// The sensing half of `decide`.
    public static func sensing(_ i: IslandInputs) -> IslandSensing {
        guard i.hasLiDAR else { return .none }
        if !i.appActive { return (i.navigating || i.routeStartWaiting || i.hasIndoorStep) ? .paused : .none }
        if i.routeStartWaiting { return .none }
        return i.depthTrusted ? .live : .none
    }

    /// The only condition under which the island may say "Path clear" / draw the green check.
    /// ⚠ Mirrored in ios/CaneKitWidget/NavLiveActivity.swift (`Sensing.showsClear`), which cannot
    /// link this package. Pinned by `showsClearOnlyWhenLive`.
    public static func showsClear(sensing: IslandSensing, isStale: Bool) -> Bool {
        sensing == .live && !isStale
    }

    /// `ActivityContent.relevanceScore`: any obstacle alert 100, guidance (walking / indoor /
    /// warming) 75, voice 50, a final card 10. Only the order matters to the system (it ranks
    /// our activity against others'). ⚠ Pinned by `relevanceOrder`.
    public static func relevance(phase: IslandPhase, alert: IslandAlertLevel) -> Double {
        switch phase {
        case .arrived, .stopped: return 10
        default: break
        }
        if alert != .none { return 100 }
        switch phase {
        case .listening, .thinking: return 50
        default: return 75
        }
    }
}

/// When an obstacle change may carry an `AlertConfiguration` (wakes the screen, expands the island).
/// Escalation only (rank goes up), at most one per `perLevelInterval` per level, never with the app
/// in the foreground (the app's own audio and haptics already warn), never on de-escalation.
/// A throttled escalation is not recorded as `lastLevel` (review round item 7), so the same
/// escalation still alerts once its window has passed instead of reading as "already there".
/// Reset per route. ⚠ Pinned by `IslandAlertThrottleTests` (`throttledEscalationAlertsAfterTheWindow`).
public struct IslandAlertThrottle: Sendable, Equatable {
    /// Seconds between two alerts of the same level. Apple silently drops frequent alerts, and a
    /// lit screen every few seconds in a pocket is a battery and attention cost.
    public static let perLevelInterval: TimeInterval = 30

    /// Last level recorded: every foreground level, every de-escalation / same level, and every
    /// escalation that alerted — never a throttled escalation (foreground included, so "locked while
    /// already near" is not an escalation).
    public private(set) var lastLevel: IslandAlertLevel = .none
    /// When each level last alerted.
    private var lastAlertAt: [IslandAlertLevel: Double] = [:]

    public init() {}

    /// Returns true when this change should alert, recording `level` unless it is an escalation the
    /// per-level window throttled. Caller: `LiveActivityController.push`.
    /// - Parameters:
    ///   - level: the new level.
    ///   - appActive: the app is in the foreground (never alert).
    ///   - now: seconds on any monotonic-enough clock.
    public mutating func shouldAlert(level: IslandAlertLevel, appActive: Bool, now: Double) -> Bool {
        guard !appActive, level.rank > lastLevel.rank else {
            lastLevel = level
            return false
        }
        // Throttled: keep the previous level, so this escalation is still one after the window.
        if let t = lastAlertAt[level], now - t < Self.perLevelInterval { return false }
        lastLevel = level
        lastAlertAt[level] = now
        return true
    }

    /// New route: forget the level and every window.
    public mutating func reset() {
        lastLevel = .none
        lastAlertAt = [:]
    }
}
