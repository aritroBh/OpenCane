//
//  LiveActivityController.swift
//  CaneKit
//
//  Starts/updates/ends the navigation Live Activity. Updates are coalesced (waypoint change or
//  ≥ 10 m) because ActivityKit throttles frequent updates.
//

import ActivityKit
import Foundation
import Observation

@MainActor
@Observable
final class LiveActivityController {

    private(set) var isActive = false
    private(set) var lastError: String?

    @ObservationIgnored private var activity: Activity<NavActivityAttributes>?
    @ObservationIgnored private var lastState: NavActivityAttributes.ContentState?

    init() {}

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
