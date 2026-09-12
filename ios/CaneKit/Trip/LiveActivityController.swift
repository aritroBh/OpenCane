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
import Foundation
import Observation

/// Thin owner of the single navigation `Activity`.
@MainActor
@Observable
final class LiveActivityController {

    /// True while an activity has been requested and not yet ended. Not observed by any view today.
    private(set) var isActive = false
    /// Last failure ("Live Activities are off in Settings", "Live Activity: <request error>"); nil
    /// after a successful `start`. Not shown by any view today (the debug footer is gone) — read it
    /// in the debugger.
    private(set) var lastError: String?

    /// The running activity, nil when none. Only this class touches it (main actor); the async
    /// ActivityKit calls get a `nonisolated(unsafe)` copy.
    @ObservationIgnored private var activity: Activity<NavActivityAttributes>?
    /// Last state actually sent; the coalescing baseline for `update`. Not reset by `end` — the
    /// next `start` overwrites it.
    @ObservationIgnored private var lastState: NavActivityAttributes.ContentState?

    /// Idle until `start`.
    init() {}

    /// Requests a new activity (ending any previous one immediately — Step 20: rapid restarts
    /// stacked stale activities on the lock screen) with glyph kind "straight".
    /// Called by `AppModel.startRouteNow` (after `nav.start`, so `instruction` is WP1's line).
    /// - Parameters:
    ///   - routeName: the static attribute ("ISR Townsend Hall to CIF", "To Grainger …").
    ///   - instruction: first content line.
    ///   - distanceM: metres to the first waypoint (0 if unknown).
    /// No-op with `lastError` set when the user has turned Live Activities off; a refused request
    /// also only sets `lastError` — guidance never depends on the Live Activity.
    func start(routeName: String, instruction: String, distanceM: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastError = "Live Activities are off in Settings"
            return
        }
        end(immediate: true)
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
    /// - Parameters:
    ///   - instruction: `nav.instruction`.
    ///   - distanceM: `nav.distanceToNext ?? 0`, metres.
    ///   - kind: `AppModel.lastNavKind` (a `NavCue.rawValue` — including "turnLeft"/"turnRight" from a
    ///     veer — or "straight"). ⚠ Any new value needs a case in `NavLiveActivity.glyph(_:)`.
    /// Fire-and-forget: the update runs in a detached task and its outcome is not observed. There
    /// is no time floor, so a walker standing still gets no updates (design.md §6.7).
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
    /// dismissed 60 s later (or immediately if `immediate` is true). Called on arrival (`final: nav.instruction`),
    /// on `stopRoute()` (so a stopped route also shows the arrived glyph for a minute), by
    /// `AppModel.endRouteQuietly()` and by `start` (both `immediate: true`) to replace a previous
    /// activity. No-op when none is running. `activity` is cleared synchronously, before the
    /// detached end completes.
    func end(final instruction: String? = nil, immediate: Bool = false) {
        guard let activity else { return }
        let state = NavActivityAttributes.ContentState(instruction: instruction ?? "Route ended", distanceM: 0, kind: "arrived")
        nonisolated(unsafe) let act = activity
        let policy: ActivityUIDismissalPolicy = immediate ? .immediate : .after(.now + 60)
        Task.detached { await act.end(.init(state: state, staleDate: nil), dismissalPolicy: policy) }
        self.activity = nil
        isActive = false
    }
}
