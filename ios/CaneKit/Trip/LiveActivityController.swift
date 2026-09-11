//
//  LiveActivityController.swift
//  CaneKit
//
//  Starts/updates/ends the navigation Live Activity. Updates are coalesced (waypoint change or
//  ≥ 10 m) because ActivityKit throttles frequent updates.
//
//  Owner: `AppModel.liveActivity` (one instance). Module `navigation-trip` in
//  docs/CODE_REFERENCE.md. Payload type: `NavActivityAttributes` (ios/Shared/LiveActivity,
//  shared with the `CaneKitWidget` target, which renders the Dynamic Island / lock screen).
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
import Foundation
import Observation

/// Thin owner of the single navigation `Activity`.
@MainActor
@Observable
final class LiveActivityController {

    /// True while an activity has been requested and not yet ended.
    private(set) var isActive = false
    /// Last failure (Live Activities disabled, request refused) for the debug UI; nil after success.
    private(set) var lastError: String?

    /// The running activity, nil when none.
    @ObservationIgnored private var activity: Activity<NavActivityAttributes>?
    /// Last state actually sent; the coalescing baseline for `update`.
    @ObservationIgnored private var lastState: NavActivityAttributes.ContentState?

    /// Idle until `start`.
    init() {}

    /// Requests a new activity (ending any previous one) with glyph kind "straight".
    /// Called by `AppModel.beginRoute()`. `distanceM` is metres to the first waypoint (0 if unknown).
    /// No-op with `lastError` set when the user has turned Live Activities off.
    func start(routeName: String, instruction: String, distanceM: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastError = "Live Activities are off in Settings"
            return
        }
        end()
        let state = NavActivityAttributes.ContentState(instruction: instruction, distanceM: distanceM, kind: "straight")
        do {
            activity = try Activity.request(attributes: NavActivityAttributes(routeName: routeName),
                                            content: .init(state: state, staleDate: nil),
                                            pushType: nil)
            lastState = state
            isActive = true
            lastError = nil
        } catch {
            lastError = "Live Activity: \(error.localizedDescription)"
        }
    }

    /// Pushes a new state, unless the instruction and kind are unchanged and the distance moved
    /// less than 10 m. Called on every GPS fix while navigating (AppModel `location.onFix`).
    /// `kind` is `AppModel.lastNavKind` (a `NavCue.rawValue` or "straight").
    func update(instruction: String, distanceM: Int, kind: String) {
        guard let activity else { return }
        let state = NavActivityAttributes.ContentState(instruction: instruction, distanceM: distanceM, kind: kind)
        if let last = lastState, last.instruction == instruction, last.kind == kind, abs(last.distanceM - distanceM) < 10 {
            return
        }
        lastState = state
        // `Activity` is not Sendable but its async API is safe to call from any task.
        nonisolated(unsafe) let act = activity
        Task.detached { await act.update(.init(state: state, staleDate: nil)) }
    }

    /// Ends the activity with an "arrived" glyph and `instruction` (default "Route ended"),
    /// dismissed 60 s later. Called on arrival (`final: nav.instruction`), on `stopRoute()`, and
    /// by `start` to replace a previous activity. No-op when none is running.
    func end(final instruction: String? = nil) {
        guard let activity else { return }
        let state = NavActivityAttributes.ContentState(instruction: instruction ?? "Route ended", distanceM: 0, kind: "arrived")
        nonisolated(unsafe) let act = activity
        // Keep the arrival glyph on the lock screen for a minute, then clear it.
        Task.detached { await act.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now + 60)) }
        self.activity = nil
        isActive = false
    }
}
