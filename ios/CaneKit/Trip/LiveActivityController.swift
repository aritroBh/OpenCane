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
//  Owner: `AppModel.liveActivity` (one instance). Module `navigation-trip` in
//  docs/CODE_REFERENCE.md. Payload type: `NavActivityAttributes` (ios/Shared/LiveActivity,
//  shared with the `CaneKitWidget` target, which renders the Dynamic Island / lock screen).
//  Callers: `start` from `AppModel.startRouteNow`; `update` on every GPS fix while navigating
//  (`wireNavigation`); `end(final:)` on arrival, `end()` from `stopRoute`, `end(immediate: true)`
//  from `endRouteQuietly` (route restart).
//  Tests: none (app target, ActivityKit). Verify on a device walk: one activity on the lock
//  screen after a restart (Step 20), Dynamic Island shows the next instruction + distance.
//
//  Threading / isolation: `@MainActor @Observable`. `Activity.update` / `.end` are called from
//  `Task.detached` through a `nonisolated(unsafe)` local, because `Activity` is not Sendable but
//  its async API is safe from any task.
//
//  Key invariants:
//    · ⚠ Keep the ≥ 10 m / instruction-or-kind-change coalescing — ActivityKit rate-limits and
//      silently drops bursts; verify on a device walk.
//    · Any new `kind` string must also be handled by the widget's glyph switch.
//    · Needs `NSSupportsLiveActivities: true` (ios/project.yml); failures are recorded in
//      `lastError`, never thrown — guidance never depends on the Live Activity.
//

import ActivityKit
import CaneKitLogic
import Foundation
import Observation

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
    /// Pure decision state machine that gates updates to prevent ActivityKit rate throttling.
    @ObservationIgnored private var coalescer = LiveActivityCoalescer()
    /// Last state actually sent; the coalescing baseline for `update`.
    @ObservationIgnored private var lastState: NavActivityAttributes.ContentState?

    /// Idle until `start`.
    init() {}

    /// Requests a new activity with initial navigation and obstacle clearance state.
    func start(
        routeName: String,
        instruction: String,
        distanceM: Int,
        obstacleStatus: LiveActivityObstacleGlance = .clear,
        obstacleDistanceM: Double = 0.0,
        headClearanceM: Double = 0.0,
        statusDetail: String = ""
    ) {
        let auth = ActivityAuthorizationInfo().areActivitiesEnabled
        print("[LiveActivity] start requested: routeName=\(routeName), areActivitiesEnabled=\(auth)")
        guard auth else {
            lastError = "Live Activities are off in Settings"
            print("[LiveActivity] ABORT: Live Activities are off in Settings")
            return
        }
        end(immediate: true)
        coalescer.reset()
        let logicStatus = LiveActivityObstacleStatus(rawValue: obstacleStatus.rawValue) ?? .clear
        let snap = LiveActivitySnapshot(
            instruction: instruction,
            distanceM: distanceM,
            kind: "straight",
            obstacleStatus: logicStatus,
            obstacleDistanceM: obstacleDistanceM,
            headClearanceM: headClearanceM,
            statusDetail: statusDetail
        )
        _ = coalescer.shouldEmit(snapshot: snap, now: Date().timeIntervalSinceReferenceDate)

        let state = NavActivityAttributes.ContentState(
            instruction: instruction,
            distanceM: distanceM,
            kind: "straight",
            obstacleStatus: obstacleStatus,
            obstacleDistanceM: obstacleDistanceM,
            headClearanceM: headClearanceM,
            statusDetail: statusDetail
        )
        do {
            activity = try Activity.request(attributes: NavActivityAttributes(routeName: routeName),
                                            content: .init(state: state, staleDate: nil),
                                            pushType: nil)
            lastState = state
            isActive = true
            lastError = nil
            print("[LiveActivity] SUCCESS: activity id=\(activity?.id ?? "nil"), state=\(String(describing: activity?.activityState))")
        } catch {
            lastError = "Live Activity: \(error.localizedDescription)"
            print("[LiveActivity] ERROR: request threw: \(error)")
        }
    }

    /// Pushes an update if the pure coalescing rules permit.
    func update(
        instruction: String,
        distanceM: Int,
        kind: String,
        obstacleStatus: LiveActivityObstacleGlance = .clear,
        obstacleDistanceM: Double = 0.0,
        headClearanceM: Double = 0.0,
        statusDetail: String = "",
        now: Double = Date().timeIntervalSinceReferenceDate
    ) {
        guard let activity else { return }
        let logicStatus = LiveActivityObstacleStatus(rawValue: obstacleStatus.rawValue) ?? .clear
        let snap = LiveActivitySnapshot(
            instruction: instruction,
            distanceM: distanceM,
            kind: kind,
            obstacleStatus: logicStatus,
            obstacleDistanceM: obstacleDistanceM,
            headClearanceM: headClearanceM,
            statusDetail: statusDetail
        )
        guard coalescer.shouldEmit(snapshot: snap, now: now) else { return }

        let state = NavActivityAttributes.ContentState(
            instruction: instruction,
            distanceM: distanceM,
            kind: kind,
            obstacleStatus: obstacleStatus,
            obstacleDistanceM: obstacleDistanceM,
            headClearanceM: headClearanceM,
            statusDetail: statusDetail
        )
        lastState = state
        nonisolated(unsafe) let act = activity
        Task.detached { await act.update(.init(state: state, staleDate: nil)) }
    }

    /// Ends the activity with an "arrived" glyph and `instruction`.
    func end(final instruction: String? = nil, immediate: Bool = false) {
        guard let activity else { return }
        coalescer.reset()
        let state = NavActivityAttributes.ContentState(
            instruction: instruction ?? "Route ended",
            distanceM: 0,
            kind: "arrived",
            obstacleStatus: .clear,
            obstacleDistanceM: 0.0,
            headClearanceM: 0.0,
            statusDetail: ""
        )
        nonisolated(unsafe) let act = activity
        let policy: ActivityUIDismissalPolicy = immediate ? .immediate : .after(.now + 60)
        Task.detached { await act.end(.init(state: state, staleDate: nil), dismissalPolicy: policy) }
        self.activity = nil
        isActive = false
    }
}
