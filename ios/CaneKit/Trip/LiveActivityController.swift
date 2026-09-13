//
//  LiveActivityController.swift
//  CaneKit
//
//  Starts/updates/ends the navigation Live Activity. Updates are coalesced (instruction or glyph
//  kind change, or ≥ 10 m) because ActivityKit throttles frequent updates.
//
//  Why it exists: the spotter walking beside a blind tester (and the walker's own lock screen /
//  Dynamic Island) sees the next instruction and distance without unlocking (Steps 8–9).
//
//  Step 64 (island redesign): the activity now has a phase and a sensing fact.
//    · Phase (`IslandPhasePolicy.decide`, CaneKitLogic): warming (started from
//      `AppModel.queueRouteStart` with a countdown to `warmupEndsAt`, then updated in place by
//      `start` — never a second activity), walking, indoor step i/n (`setIndoor`), listening /
//      thinking (`setVoicePhase`), and the final arrived / stopped cards (`end`).
//    · Sensing: live / paused / none. ⚠ The widget draws "Path clear" only when `.live`; with the
//      app in the background depth is paused, so `setSensors(appActive: false, …)` makes it
//      `.paused` and the obstacle fields are sent as clear/none. This fixes the audit's safety bug
//      (green "Path clear" on the lock screen while ARKit was paused).
//    · Phase / sensing changes bypass the coalescer's floor (`LiveActivityCoalescer` rule 0).
//    · `relevanceScore` on every content (`IslandPhasePolicy.relevance`), and an
//      `AlertConfiguration` on an escalation that `IslandAlertThrottle` lets through while the app
//      is not frontmost (`UIApplication.applicationState != .active`).
//
//  Steps 62 + 64 review round:
//    · One activity per trip: `beginIndoor` requests it for an indoor walk (Step 62 never did), and
//      `beginWarmup` / `start` / `beginIndoor` update an existing activity in place — the indoor →
//      outdoor handover keeps the same island (its static `routeName` is the trip's, set by
//      `IndoorGuide.start`). `endIfIdle` ends one that nothing drives any more (a failed build).
//    · `Activity.request` is serialized behind `activityOperation` (the closing card's end and any
//      update), runs in a main-actor task after `await predecessor?.value`, and is dropped when
//      `requestGeneration` moved on (an `end` or a newer request).
//    · ⚠ `Activity.request` throws from the background: a request made while the app is not
//      `.active` (the handover can fire locked) is kept as `requestSpec` and performed by
//      `flushPendingRequest()` on the next `.active` (`AppModel.scenePhaseChanged`); logged
//      `live_activity {action: deferred | flushed | requested | request_failed | request_cancelled}`
//      through `onLog`.
//
//  Owner: `AppModel.liveActivity` (one instance). Module `navigation-trip` in
//  docs/CODE_REFERENCE.md. Payload type: `NavActivityAttributes` (ios/Shared/LiveActivity,
//  shared with the `CaneKitWidget` target, which renders the Dynamic Island / lock screen).
//  Callers: `beginIndoor` from `IndoorGuide.start`, `flushPendingRequest` from
//  `AppModel.scenePhaseChanged(.active)`, `endIfIdle` from `IndoorGuide.handOver` and
//  `AppModel.buildRoute`'s failures, `beginWarmup` from `AppModel.queueRouteStart`, `cancelWarmup` from
//  `cancelPendingRouteStart`; `start` from `AppModel.startRouteNow`; `update` on every GPS fix
//  while navigating (`wireNavigation`); `setSensors` from `scenePhaseChanged`; `setVoicePhase` from
//  `AppModel`'s voice observation; `setIndoor` from the indoor guide (`AppModel+Indoor`);
//  `end(final:)` on arrival, `end(stopped: true)` from `stopRoute`, `end(immediate: true)` from
//  `endRouteQuietly` (route restart).
//  Tests: the decisions are pinned in CaneKitLogic (`IslandPolicyTests`,
//  `LiveActivityCoalescerTests`); this class itself has none (app target, ActivityKit). Verify on a
//  device walk: one activity on the lock screen after a restart (Step 20), Dynamic Island shows the
//  next instruction + distance, lock → "Obstacles paused — unlock".
//
//  Threading / isolation: `@MainActor @Observable`. `Activity.update` / `.end` are called from
//  one chained detached task at a time through a `nonisolated(unsafe)` local, because `Activity`
//  is not Sendable but its async API is safe from any task. The chain is the ordering fence: an
//  older update always completes before `end`, and a new route's first update waits for the old
//  end instead of reviving stale lock-screen state.
//
//  Key invariants:
//    · ⚠ Keep the ≥ 10 m / instruction-or-kind-change coalescing — ActivityKit rate-limits and
//      silently drops bursts; verify on a device walk.
//    · Any new `kind` string must also be handled by the widget's glyph switch.
//    · Needs `NSSupportsLiveActivities: true` (ios/project.yml); failures are recorded in
//      `lastError`, never thrown — guidance never depends on the Live Activity.
//    · Every request / update carries `staleDate = now + LiveActivityCoalescer.staleAfter` (5 min):
//      an activity the app can no longer update (killed mid-route) dims instead of lying.
//    · ⚠ `Activity.request` throws from the background, so a request is only performed while the
//      app is `.active`; otherwise it waits for `flushPendingRequest` (review round item 5).
//    · `setVoicePhase` / `setIndoor` never start an activity: no-ops without one (their inputs are
//      kept, so a queued request picks them up).
//

import ActivityKit
import CaneKitLogic
import Foundation
import Observation
import UIKit

/// Thin owner of the single navigation `Activity`.
@MainActor
@Observable
final class LiveActivityController {

    /// True while an activity has been requested and not yet ended. Not observed by any view today.
    private(set) var isActive = false
    /// Last failure ("Live Activities are off in Settings", "Live Activity: <request error>"); nil
    /// after a successful `start`.
    private(set) var lastError: String?

    /// The running activity, nil when none. Only this class touches it (main actor); the async
    /// ActivityKit calls get a `nonisolated(unsafe)` copy.
    @ObservationIgnored private var activity: Activity<NavActivityAttributes>?
    /// Route name the running activity was requested with (its static attribute).
    @ObservationIgnored private var activityRouteName: String?
    /// Pure decision state machine that gates updates to prevent ActivityKit rate throttling.
    @ObservationIgnored private var coalescer = LiveActivityCoalescer()
    /// Last state actually sent; the coalescing baseline for `update`.
    @ObservationIgnored private var lastState: NavActivityAttributes.ContentState?
    /// Serializes ActivityKit mutations. A task is never detached independently of its
    /// predecessor, so update/end/start replacement cannot reorder on the system's executor.
    @ObservationIgnored private var activityOperation: Task<Void, Never>?
    /// Step 64: what `IslandPhasePolicy.decide` looks at. `hasLiDAR` fixed at init.
    @ObservationIgnored private var inputs = IslandInputs(hasLiDAR: DepthEngine.supportsMesh)
    /// Step 64: the current indoor step's line, shown as the instruction while indoors.
    @ObservationIgnored private var indoorSay: String?
    /// Step 64: escalation-only alert gate, reset per route.
    @ObservationIgnored private var alertThrottle = IslandAlertThrottle()
    /// Step 64: a stopped activity showing its "Route stopped" card until `closingTask` ends it.
    /// The Dynamic Island drops an *ended* activity at once (first Step 64 pictures: an empty
    /// island 4 s after Stop), so Stop updates first and ends 10 s later.
    @ObservationIgnored private var closingActivity: Activity<NavActivityAttributes>?
    /// Ends `closingActivity` after `stoppedCardSeconds`; cancelled by a new request.
    @ObservationIgnored private var closingTask: Task<Void, Never>?
    /// How long the "Route stopped" card stays in the island and on the lock screen.
    static let stoppedCardSeconds: TimeInterval = 10

    /// What a queued or deferred `Activity.request` asks for. Phase, sensing, the indoor line and
    /// step come from `inputs` / `indoorSay` when it is performed, not when it was asked.
    private struct RequestSpec {
        /// Static attribute of the new activity.
        var routeName: String
        /// First instruction (replaced by the indoor line while indoors).
        var instruction: String
        /// Whole metres to the next waypoint.
        var distanceM: Int
        /// Obstacle glance (gated on sensing at perform time).
        var obstacleStatus: LiveActivityObstacleGlance = .clear
        /// Obstacle distance, metres.
        var obstacleDistanceM: Double = 0
        /// Head clearance, metres.
        var headClearanceM: Double = 0
        /// Status badge.
        var statusDetail: String = ""
        /// Warming countdown end, nil outside a warm-up.
        var warmupEndsAt: Date?
    }

    /// Review round (items 4 / 5): the request waiting behind `activityOperation` or for the
    /// foreground; nil when none. Later `beginWarmup` / `start` / `beginIndoor` calls rewrite it.
    @ObservationIgnored private var requestSpec: RequestSpec?
    /// `requestSpec` waits for `.active` (made while not frontmost), not for the chain.
    @ObservationIgnored private var requestDeferred = false
    /// Bumped by every `request` and `end`; a queued request of an older generation is dropped.
    @ObservationIgnored private var requestGeneration: UInt64 = 0
    /// `live_activity {…}` fields for the trip log (`AppModel.start()` wires `logger.event`).
    @ObservationIgnored var onLog: (([String: Any]) -> Void)?

    /// Idle until `beginWarmup` / `start`.
    init() {}

    /// Terminates any stale activities left by previous app crashes or Xcode rebuilds. Each end is
    /// chained on `activityOperation` (review round item 4), so a request right after launch waits
    /// for them instead of racing an orphan's end. Caller: `AppModel.start()`.
    func endAllOrphanedActivities() {
        for a in Activity<NavActivityAttributes>.activities {
            nonisolated(unsafe) let stale = a
            let predecessor = activityOperation
            activityOperation = Task.detached(priority: .utility) {
                _ = await predecessor?.value
                await stale.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: Lifecycle

    /// Step 64: the activity in the `warming` phase while the depth readiness gate runs, so the
    /// island shows OpenCane and a countdown (`Text(timerInterval:)`, no updates needed) instead of
    /// nothing. `start` later updates this same activity to walking. Review round: an existing
    /// activity (the indoor walk's, at the handover) is updated in place, a queued / deferred request
    /// is rewritten; only with neither is one requested.
    /// - Parameters:
    ///   - routeName: the route's name (static attribute of a newly requested activity only).
    ///   - line: what the island says ("Obstacle detection warming up").
    ///   - waitSeconds: the readiness timeout (`DepthReadiness.standardConfiguration.timeout`).
    /// Caller: `AppModel.queueRouteStart`.
    func beginWarmup(routeName: String, line: String, waitSeconds: TimeInterval) {
        inputs.routeStartWaiting = true
        inputs.navigating = false
        inputs.indoorStepIndex = nil
        inputs.indoorStepCount = 0
        inputs.appActive = UIApplication.shared.applicationState != .background
        inputs.depthTrusted = false
        indoorSay = nil
        let endsAt = Date(timeIntervalSinceNow: max(0, waitSeconds))
        if activity != nil, lastState != nil {
            print("[LiveActivity] warming in place (existing activity)")
            alertThrottle.reset()
            coalescer.reset()
            lastState?.warmupEndsAt = endsAt
            push(instruction: line, distanceM: 0, kind: "straight", obstacleStatus: .clear, obstacleDistanceM: 0,
                 headClearanceM: 0, statusDetail: "", progress: 0, stepIndex: 0, stepCount: 0,
                 now: Date().timeIntervalSinceReferenceDate)
            return
        }
        if requestSpec != nil {
            requestSpec?.instruction = line
            requestSpec?.distanceM = 0
            requestSpec?.warmupEndsAt = endsAt
            return
        }
        request(RequestSpec(routeName: routeName, instruction: line, distanceM: 0, warmupEndsAt: endsAt))
    }

    /// Step 64: a queued route was cancelled before it started — end a `warming` activity (or a
    /// warming request still queued / deferred) at once. No-op for any other phase (a replacement
    /// request while walking must not end the walk here; `endRouteQuietly` owns that).
    /// Caller: `AppModel.cancelPendingRouteStart`.
    func cancelWarmup() {
        inputs.routeStartWaiting = false
        let warmingActivity = activity != nil && lastState?.phase == .warming
        let warmingRequest = activity == nil && requestSpec?.warmupEndsAt != nil
        guard warmingActivity || warmingRequest else { return }
        end(immediate: true)
    }

    /// Review round item 3: the indoor walk's island (Step 62 never started one, so `setIndoor` was a
    /// no-op). Ends a closing "Route stopped" card at once (through `request`), requests an activity
    /// in the `.indoor` phase when there is none (performed only while `.active`, else deferred), or
    /// updates the existing one / the queued request in place.
    /// - Parameters:
    ///   - name: the trip's name — the static `routeName` the outdoor leg keeps after the handover
    ///     (`IndoorGuide.start`: the bundled route's name for CIF, "To <destination>" otherwise).
    ///   - say: the current step's line (`IndoorProgress.currentSay`).
    ///   - stepIndex: current step, 0-based.
    ///   - stepCount: steps in the script.
    /// Caller: `IndoorGuide.start`, before its first `setIndoor`.
    func beginIndoor(name: String, say: String, stepIndex: Int, stepCount: Int) {
        inputs.routeStartWaiting = false
        inputs.navigating = false
        inputs.indoorStepIndex = stepIndex
        inputs.indoorStepCount = max(0, stepCount)
        inputs.appActive = UIApplication.shared.applicationState != .background
        inputs.depthTrusted = false
        indoorSay = inputs.hasIndoorStep ? say : nil
        alertThrottle.reset()
        if activity != nil, lastState != nil {
            coalescer.reset()
            push(instruction: say, distanceM: 0, kind: "straight", obstacleStatus: .clear, obstacleDistanceM: 0,
                 headClearanceM: 0, statusDetail: "", progress: 0, stepIndex: stepIndex, stepCount: stepCount,
                 now: Date().timeIntervalSinceReferenceDate)
            return
        }
        if requestSpec != nil {
            requestSpec?.instruction = say
            requestSpec?.distanceM = 0
            requestSpec?.warmupEndsAt = nil
            return
        }
        request(RequestSpec(routeName: name, instruction: say, distanceM: 0, warmupEndsAt: nil))
    }

    /// Ends the activity (or a queued / deferred request) at once when nothing drives it any more:
    /// no route, no warm-up, no indoor step. Why: since the handover reuses the indoor activity, an
    /// outdoor leg that never starts (no fix, MapKit error, location refused) would otherwise leave
    /// a frozen island. Callers: `IndoorGuide.handOver`, `AppModel.buildRoute`'s failure branches.
    func endIfIdle() {
        guard activity != nil || requestSpec != nil else { return }
        guard !inputs.navigating, !inputs.routeStartWaiting, !inputs.hasIndoorStep else { return }
        onLog?(["action": "end_idle"])
        end(immediate: true)
    }

    /// The next `.active` scene phase: performs a request that was deferred because the app was not
    /// frontmost (review round item 5). No-op without one. Caller: `AppModel.scenePhaseChanged(.active)`
    /// (so the scene is frontmost; `performRequest` still refuses from `.background`).
    func flushPendingRequest() {
        guard requestDeferred, requestSpec != nil else { return }
        onLog?(["action": "flushed"])
        enqueueRequest()
    }

    /// Starts guidance on the island: updates an existing activity in place (the warming one, or the
    /// indoor walk's after the handover — review round item 3), rewrites a queued / deferred request,
    /// otherwise requests a new one (ending any previous activity immediately, Step 20; a restart
    /// has already ended the old one through `endRouteQuietly`).
    /// - Parameters: the first instruction / distance / glance; `depthTrusted` is whether depth is
    ///   running with a trusted report right now (sensing live vs none).
    /// Caller: `AppModel.startRouteNow`.
    func start(
        routeName: String,
        instruction: String,
        distanceM: Int,
        obstacleStatus: LiveActivityObstacleGlance = .clear,
        obstacleDistanceM: Double = 0.0,
        headClearanceM: Double = 0.0,
        statusDetail: String = "",
        depthTrusted: Bool = false
    ) {
        inputs.routeStartWaiting = false
        inputs.navigating = true
        inputs.appActive = UIApplication.shared.applicationState != .background
        inputs.depthTrusted = depthTrusted
        alertThrottle.reset()
        if activity != nil, lastState != nil {
            print("[LiveActivity] → walking in place: routeName=\(routeName)")
            coalescer.reset()
            push(instruction: instruction, distanceM: distanceM, kind: "straight",
                 obstacleStatus: obstacleStatus, obstacleDistanceM: obstacleDistanceM,
                 headClearanceM: headClearanceM, statusDetail: statusDetail, progress: 0,
                 stepIndex: 0, stepCount: 0, now: Date().timeIntervalSinceReferenceDate)
            lastError = nil
            return
        }
        if let pending = requestSpec {
            requestSpec = RequestSpec(routeName: pending.routeName, instruction: instruction, distanceM: distanceM,
                                      obstacleStatus: obstacleStatus, obstacleDistanceM: obstacleDistanceM,
                                      headClearanceM: headClearanceM, statusDetail: statusDetail, warmupEndsAt: nil)
            return
        }
        request(RequestSpec(routeName: routeName, instruction: instruction, distanceM: distanceM,
                            obstacleStatus: obstacleStatus, obstacleDistanceM: obstacleDistanceM,
                            headClearanceM: headClearanceM, statusDetail: statusDetail, warmupEndsAt: nil))
    }

    /// Asks for a fresh activity (shared by `beginWarmup`, `start`, `beginIndoor`): ends the closing
    /// card and any previous activity immediately (keeping the caller's new inputs), stores `spec`,
    /// then either defers it (app not `.active` — `Activity.request` throws from the background;
    /// logged `deferred`) or queues it behind `activityOperation`. `isActive` is true from here until
    /// `end` or a failed request. `lastError` is only set synchronously for "Live Activities are off".
    private func request(_ spec: RequestSpec) {
        let auth = ActivityAuthorizationInfo().areActivitiesEnabled
        print("[LiveActivity] request: routeName=\(spec.routeName), areActivitiesEnabled=\(auth)")
        guard auth else {
            lastError = "Live Activities are off in Settings"
            print("[LiveActivity] ABORT: Live Activities are off in Settings")
            return
        }
        // `end` resets the phase inputs for the old activity; the caller has just set this one's.
        let wanted = inputs
        let wantedIndoorSay = indoorSay
        endClosingCard()
        end(immediate: true)
        inputs = wanted
        indoorSay = wantedIndoorSay
        requestSpec = spec
        isActive = true
        lastError = nil
        guard UIApplication.shared.applicationState == .active else {
            requestDeferred = true
            onLog?(["action": "deferred", "route": spec.routeName])
            return
        }
        enqueueRequest()
    }

    /// Queues `performRequest` for the current generation behind `activityOperation` (review round
    /// item 4: the request waits for the closing card's end / the previous activity's end).
    private func enqueueRequest() {
        requestDeferred = false
        let generation = requestGeneration
        let predecessor = activityOperation
        activityOperation = Task { @MainActor [weak self] in
            _ = await predecessor?.value
            self?.performRequest(generation: generation)
        }
    }

    /// Performs the queued `requestSpec` on the main actor, after its predecessors: dropped when the
    /// generation moved on (an `end` or a newer request) or the spec is gone; re-deferred when the
    /// app went to the background meanwhile. Phase, sensing, the indoor line / step and the warming
    /// countdown are decided now from `inputs`. Logs `requested` / `request_failed`.
    private func performRequest(generation: UInt64) {
        guard generation == requestGeneration, let spec = requestSpec, !requestDeferred else { return }
        guard UIApplication.shared.applicationState != .background else {
            requestDeferred = true
            onLog?(["action": "deferred", "route": spec.routeName])
            return
        }
        requestSpec = nil
        coalescer.reset()
        let decided = IslandPhasePolicy.decide(inputs)
        let glance = Self.gatedGlance(spec.obstacleStatus, spec.obstacleDistanceM, spec.headClearanceM,
                                      sensing: decided.sensing)
        let logicStatus = LiveActivityObstacleStatus(rawValue: glance.status.rawValue) ?? .clear
        let indoor = decided.phase == .indoor || (decided.phase != .walking && inputs.hasIndoorStep)
        let shown = indoor ? (indoorSay ?? spec.instruction) : spec.instruction
        _ = coalescer.shouldEmit(snapshot: LiveActivitySnapshot(
            instruction: shown, distanceM: spec.distanceM, kind: "straight", obstacleStatus: logicStatus,
            obstacleDistanceM: glance.distance, headClearanceM: glance.head, statusDetail: spec.statusDetail,
            phase: decided.phase.rawValue, sensing: decided.sensing.rawValue),
            now: Date().timeIntervalSinceReferenceDate)
        let alert = IslandAlertLevel.from(obstacle: logicStatus, distanceM: glance.distance)
        let state = NavActivityAttributes.ContentState(
            instruction: shown, distanceM: spec.distanceM, kind: "straight",
            obstacleStatus: glance.status, obstacleDistanceM: glance.distance, headClearanceM: glance.head,
            statusDetail: spec.statusDetail, progress: 0,
            phase: NavIslandPhase(rawValue: decided.phase.rawValue) ?? .walking,
            sensing: NavIslandSensing(rawValue: decided.sensing.rawValue) ?? .none,
            stepIndex: indoor ? (inputs.indoorStepIndex ?? 0) : 0,
            stepCount: indoor ? inputs.indoorStepCount : 0,
            // Kept while the warm-up runs even under a voice phase, so the countdown survives it.
            warmupEndsAt: inputs.routeStartWaiting ? spec.warmupEndsAt : nil,
            alertLevel: NavIslandAlert(rawValue: alert.rawValue) ?? .none)
        do {
            activity = try Activity.request(
                attributes: NavActivityAttributes(routeName: spec.routeName),
                content: .init(state: state, staleDate: Self.staleDate(),
                               relevanceScore: IslandPhasePolicy.relevance(phase: decided.phase, alert: alert)),
                pushType: nil)
            activityRouteName = spec.routeName
            lastState = state
            isActive = true
            lastError = nil
            onLog?(["action": "requested", "phase": decided.phase.rawValue, "route": spec.routeName])
            print("[LiveActivity] SUCCESS: activity id=\(activity?.id ?? "nil"), phase=\(decided.phase), sensing=\(decided.sensing)")
        } catch {
            activity = nil
            isActive = false
            lastError = "Live Activity: \(error.localizedDescription)"
            onLog?(["action": "request_failed", "error": error.localizedDescription])
            print("[LiveActivity] ERROR: request threw: \(error)")
        }
    }

    // MARK: Updates

    /// Pushes an update if the pure coalescing rules permit.
    /// - Parameters:
    ///   - depthTrusted: Step 64 — when non-nil, records whether depth is running with a trusted
    ///     report (the GPS glance passes it); the scene phase is read from `UIApplication`.
    ///   - waypointIndex / waypointCount: Step 64 — "3 of 6" in the expanded island; nil keeps the
    ///     last values.
    func update(
        instruction: String,
        distanceM: Int,
        kind: String,
        obstacleStatus: LiveActivityObstacleGlance = .clear,
        obstacleDistanceM: Double = 0.0,
        headClearanceM: Double = 0.0,
        statusDetail: String = "",
        progress: Double = 0,
        depthTrusted: Bool? = nil,
        waypointIndex: Int? = nil,
        waypointCount: Int? = nil,
        now: Double = Date().timeIntervalSinceReferenceDate
    ) {
        guard activity != nil else { return }
        if let depthTrusted {
            inputs.depthTrusted = depthTrusted
            inputs.appActive = UIApplication.shared.applicationState != .background
        }
        push(instruction: instruction, distanceM: distanceM, kind: kind, obstacleStatus: obstacleStatus,
             obstacleDistanceM: obstacleDistanceM, headClearanceM: headClearanceM, statusDetail: statusDetail,
             progress: progress, stepIndex: waypointIndex ?? lastState?.stepIndex ?? 0,
             stepCount: waypointCount ?? lastState?.stepCount ?? 0, now: now)
    }

    /// The one path to `Activity.update`: decides phase + sensing, gates the glance on sensing,
    /// runs the coalescer, attaches relevance and (maybe) an alert, and chains the ActivityKit call.
    private func push(instruction: String, distanceM: Int, kind: String,
                      obstacleStatus: LiveActivityObstacleGlance, obstacleDistanceM: Double,
                      headClearanceM: Double, statusDetail: String, progress: Double,
                      stepIndex: Int, stepCount: Int, now: Double) {
        guard let activity else { return }
        let decided = IslandPhasePolicy.decide(inputs)
        let glance = Self.gatedGlance(obstacleStatus, obstacleDistanceM, headClearanceM, sensing: decided.sensing)
        let logicStatus = LiveActivityObstacleStatus(rawValue: glance.status.rawValue) ?? .clear
        // Indoors the step script's line is the instruction, and the step counter replaces the
        // waypoint counter.
        let indoor = decided.phase == .indoor || (decided.phase != .walking && inputs.hasIndoorStep)
        let shownInstruction = indoor ? (indoorSay ?? instruction) : instruction
        let snap = LiveActivitySnapshot(
            instruction: shownInstruction, distanceM: distanceM, kind: kind, obstacleStatus: logicStatus,
            obstacleDistanceM: glance.distance, headClearanceM: glance.head, statusDetail: statusDetail,
            phase: decided.phase.rawValue, sensing: decided.sensing.rawValue)
        guard coalescer.shouldEmit(snapshot: snap, now: now) else { return }

        let alert = IslandAlertLevel.from(obstacle: logicStatus, distanceM: glance.distance)
        let foreground = UIApplication.shared.applicationState == .active
        let alertConfig: AlertConfiguration? =
            alertThrottle.shouldAlert(level: alert, appActive: foreground, now: now) ? Self.alertConfiguration(alert, glance) : nil
        let state = NavActivityAttributes.ContentState(
            instruction: shownInstruction, distanceM: distanceM, kind: kind,
            obstacleStatus: glance.status, obstacleDistanceM: glance.distance, headClearanceM: glance.head,
            statusDetail: statusDetail, progress: progress,
            phase: NavIslandPhase(rawValue: decided.phase.rawValue) ?? .walking,
            sensing: NavIslandSensing(rawValue: decided.sensing.rawValue) ?? .none,
            stepIndex: indoor ? (inputs.indoorStepIndex ?? 0) : stepIndex,
            stepCount: indoor ? inputs.indoorStepCount : stepCount,
            // Kept while the warm-up runs even under a voice phase, so the countdown survives it.
            warmupEndsAt: inputs.routeStartWaiting ? lastState?.warmupEndsAt : nil,
            alertLevel: NavIslandAlert(rawValue: alert.rawValue) ?? .none)
        lastState = state
        nonisolated(unsafe) let act = activity
        let content = ActivityContent(state: state, staleDate: Self.staleDate(),
                                      relevanceScore: IslandPhasePolicy.relevance(phase: decided.phase, alert: alert))
        let predecessor = activityOperation
        activityOperation = Task.detached(priority: .utility) {
            _ = await predecessor?.value
            if let alertConfig {
                await act.update(content, alertConfiguration: alertConfig)
            } else {
                await act.update(content)
            }
        }
    }

    /// Re-sends the last state with a freshly decided phase / sensing (voice, indoor, scene phase).
    /// The coalescer emits at once when either changed and suppresses a no-op.
    private func republish() {
        guard activity != nil, let last = lastState else { return }
        push(instruction: last.instruction, distanceM: last.distanceM, kind: last.kind,
             obstacleStatus: last.obstacleStatus, obstacleDistanceM: last.obstacleDistanceM,
             headClearanceM: last.headClearanceM, statusDetail: last.statusDetail, progress: last.progress,
             stepIndex: last.stepIndex, stepCount: last.stepCount,
             now: Date().timeIntervalSinceReferenceDate)
    }

    /// ⚠ Step 64 safety gate: obstacle fields are only meaningful while sensing is `.live`. Paused /
    /// unknown sensing sends clear with zero distances — the widget shows the sensing state instead,
    /// never a stale hazard or a false "Path clear".
    private static func gatedGlance(_ status: LiveActivityObstacleGlance, _ distance: Double, _ head: Double,
                                    sensing: IslandSensing) -> (status: LiveActivityObstacleGlance, distance: Double, head: Double) {
        sensing == .live ? (status, distance, head) : (.clear, 0, 0)
    }

    /// The lock-screen alert for an escalation (`IslandAlertThrottle` let it through). Default
    /// sound only: the app's own audio and haptics are the real warning.
    private static func alertConfiguration(_ level: IslandAlertLevel,
                                           _ glance: (status: LiveActivityObstacleGlance, distance: Double, head: Double)) -> AlertConfiguration? {
        let d = glance.distance > 0 ? String(format: "%.1f m", glance.distance) : ""
        switch level {
        case .none:
            return nil
        case .head:
            return AlertConfiguration(title: "Head height", body: "Obstacle at head height ahead. Stop.", sound: .default)
        case .stop:
            return AlertConfiguration(title: "Stop", body: d.isEmpty ? "Obstacle right ahead." : "Obstacle \(d) ahead.", sound: .default)
        case .near:
            return AlertConfiguration(title: "Obstacle ahead", body: d.isEmpty ? "Slow down." : "Obstacle \(d) ahead.", sound: .default)
        case .curb:
            return AlertConfiguration(title: "Drop-off ahead", body: "Curb or step ahead.", sound: .default)
        }
    }

    /// `LiveActivityCoalescer.staleAfter` from now: past it the widget dims the distance and says
    /// "No update" (`context.isStale`). Set on every request and update, never on `end` (an ended
    /// activity is already final). Why: ActivityKit keeps an activity in the island for hours after
    /// the app is killed mid-route; without a stale date a spotter would read a frozen "120 m" as
    /// live (Step 47, first island pictures).
    private static func staleDate() -> Date {
        Date(timeIntervalSinceNow: LiveActivityCoalescer.staleAfter)
    }

    /// Obstacle-only refresh from the depth path (a point-blank hold or a head cell while the
    /// walker stands still and no GPS fix arrives): keeps the last navigation fields and pushes
    /// the new glance through the coalescer, whose hazard-transition rule emits at once.
    func refreshObstacle(status: LiveActivityObstacleGlance, distanceM: Double, headM: Double) {
        guard let last = lastState else { return }
        update(instruction: last.instruction, distanceM: last.distanceM, kind: last.kind,
               obstacleStatus: status, obstacleDistanceM: distanceM, headClearanceM: headM,
               statusDetail: last.statusDetail, progress: last.progress)
    }

    /// Navigation-only refresh (waypoint advanced by Next / the crown / skip-ahead, with no fix to
    /// carry the obstacle fields): keeps the last obstacle glance and GPS detail and pushes the new
    /// line, distance, glyph and progress through the same coalescer. The waypoint counter is
    /// re-derived from `progress` × the last known count.
    func refreshNavigation(instruction: String, distanceM: Int, kind: String, progress: Double) {
        let last = lastState
        let count = last?.stepCount ?? 0
        update(instruction: instruction, distanceM: distanceM, kind: kind,
               obstacleStatus: last?.obstacleStatus ?? .clear,
               obstacleDistanceM: last?.obstacleDistanceM ?? 0,
               headClearanceM: last?.headClearanceM ?? 0,
               statusDetail: last?.statusDetail ?? "",
               progress: progress,
               waypointIndex: count > 0 ? Int((progress * Double(count)).rounded()) : nil)
    }

    // MARK: Step 64 phase inputs

    /// Records the scene phase and depth trust; re-publishes when phase / sensing changed.
    /// - Parameters:
    ///   - appActive: false once the app is in the background (depth paused → sensing `.paused`).
    ///   - depthTrusted: depth running with a trusted report.
    /// Callers: `AppModel.scenePhaseChanged` (.background → false/false, .active → true/false; the
    /// next GPS fix brings the real trust).
    func setSensors(appActive: Bool, depthTrusted: Bool) {
        inputs.appActive = appActive
        inputs.depthTrusted = depthTrusted
        republish()
    }

    /// Voice shell state → listening / thinking phase. No-op without an activity (voice never
    /// starts one). Caller: `AppModel`'s voice observation.
    func setVoicePhase(listening: Bool, thinking: Bool) {
        guard inputs.voiceListening != listening || inputs.voiceThinking != thinking else { return }
        inputs.voiceListening = listening
        inputs.voiceThinking = thinking
        republish()
    }

    /// Indoor step script → indoor phase, "step i of n" and the step's line as the instruction.
    /// No-op without an activity.
    /// - Parameters:
    ///   - stepIndex: current step, **0-based** (`IndoorProgress.index`); nil leaves indoor mode.
    ///   - stepCount: number of steps (`IndoorScript.steps.count`); 0 leaves indoor mode.
    ///   - say: the current step's line (`IndoorProgress.currentSay`).
    /// Caller: the indoor guide (`AppModel+Indoor`, Step 62/63).
    func setIndoor(stepIndex: Int?, stepCount: Int, say: String?) {
        inputs.indoorStepIndex = stepIndex
        inputs.indoorStepCount = max(0, stepCount)
        indoorSay = inputs.hasIndoorStep ? say : nil
        guard activity != nil, let last = lastState else { return }
        // A new step is new content even when the phase stays `.indoor`: bypass the floor by
        // resetting the coalescer's baseline, then push.
        coalescer.reset()
        push(instruction: last.instruction, distanceM: last.distanceM, kind: last.kind,
             obstacleStatus: last.obstacleStatus, obstacleDistanceM: last.obstacleDistanceM,
             headClearanceM: last.headClearanceM, statusDetail: last.statusDetail, progress: last.progress,
             stepIndex: last.stepIndex, stepCount: last.stepCount,
             now: Date().timeIntervalSinceReferenceDate)
    }

    // MARK: End

    /// Ends the "Route stopped" card now (its timer fired, or a new activity is being requested).
    private func endClosingCard() {
        closingTask?.cancel()
        closingTask = nil
        guard let closing = closingActivity else { return }
        closingActivity = nil
        nonisolated(unsafe) let act = closing
        let predecessor = activityOperation
        activityOperation = Task.detached(priority: .utility) {
            _ = await predecessor?.value
            await act.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Ends the activity, and drops a queued / deferred request (bumps `requestGeneration`; logs
    /// `request_cancelled` when only a request existed). Clears `activity` at once.
    /// - Parameters:
    ///   - instruction: the arrival line (`AppModel` `onArrived` → `end(final: nav.instruction)`);
    ///     non-nil means arrived (phase `.arrived`, full progress bar, 60 s on the lock screen).
    ///   - immediate: remove at once (route restart, a cancelled warm-up, a replacement request).
    ///   - stopped: Step 64 — Stop: phase `.stopped`, "Route stopped", last progress; sent as an
    ///     update and ended `stoppedCardSeconds` later (`closingTask`), because the island removes an
    ///     ended activity at once.
    func end(final instruction: String? = nil, immediate: Bool = false, stopped: Bool = false) {
        inputs.navigating = false
        inputs.routeStartWaiting = false
        inputs.indoorStepIndex = nil
        inputs.indoorStepCount = 0
        indoorSay = nil
        alertThrottle.reset()
        requestGeneration &+= 1
        let hadRequest = requestSpec != nil
        requestSpec = nil
        requestDeferred = false
        guard let activity else {
            if hadRequest {
                isActive = false
                onLog?(["action": "request_cancelled"])
            }
            return
        }
        coalescer.reset()
        let arrived = instruction != nil
        // Stop and an immediate end (restart / cancelled warm-up, removed at once) both close as `.stopped`.
        let phase: NavIslandPhase = arrived ? .arrived : .stopped
        let state = NavActivityAttributes.ContentState(
            instruction: instruction ?? (stopped ? "Route stopped" : "Route ended"),
            distanceM: 0,
            kind: "arrived",
            obstacleStatus: .clear,
            obstacleDistanceM: 0.0,
            headClearanceM: 0.0,
            statusDetail: "",
            // Full bar on arrival, the last known progress on an abandoned route — never a full bar
            // for a cancelled walk.
            progress: arrived ? 1 : (lastState?.progress ?? 0),
            phase: phase,
            sensing: .none,
            stepIndex: lastState?.stepIndex ?? 0,
            stepCount: lastState?.stepCount ?? 0
        )
        nonisolated(unsafe) let act = activity
        let content = ActivityContent(state: state, staleDate: nil,
                                      relevanceScore: IslandPhasePolicy.relevance(phase: arrived ? .arrived : .stopped, alert: .none))
        let predecessor = activityOperation
        if stopped && !immediate {
            // Stop: show the card as a live update (the island keeps it), end it 10 s later. The
            // stale date makes a card the app never got to end (suspended) dim instead of linger live.
            let closing = ActivityContent(state: state, staleDate: Date(timeIntervalSinceNow: Self.stoppedCardSeconds),
                                          relevanceScore: content.relevanceScore)
            activityOperation = Task.detached(priority: .utility) {
                _ = await predecessor?.value
                await act.update(closing)
            }
            closingActivity = activity
            let seconds = Self.stoppedCardSeconds
            closingTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self?.endClosingCard()
            }
        } else {
            let policy: ActivityUIDismissalPolicy = immediate ? .immediate : .after(.now + 60)
            activityOperation = Task.detached(priority: .utility) {
                _ = await predecessor?.value
                await act.end(content, dismissalPolicy: policy)
            }
        }
        self.activity = nil
        activityRouteName = nil
        lastState = nil
        isActive = false
    }
}
