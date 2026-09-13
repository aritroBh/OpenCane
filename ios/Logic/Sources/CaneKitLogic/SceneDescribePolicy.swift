//
//  SceneDescribePolicy.swift
//  CaneKitLogic
//
//  Whether a "Where am I" run may still speak after a lock (Step 63).
//
//  Why this file exists: `ConversationCoordinator.cancelForBackground` already drops a cloud
//  *question* so its pre-lock answer cannot speak after the unlock (Codex, 2026-09-13).
//  `SceneDescriber` used an unstructured `Task` with no generation check, so a JPEG captured
//  before the lock could still `speech.say` the scene the walker had left. The fence is a
//  generation compare — the same shape as `TripRefreshGeneration.accepts` — so the rule is
//  testable without UIKit.
//
//  Owner / callers: `SceneDescriber.run` / `cancelForBackground` (app). Isolation: stateless
//  and nonisolated. Tests: SceneDescribePolicyTests.swift.
//

import Foundation

/// Generation fence for an in-flight scene description.
public enum SceneDescribePolicy {

    /// A run may speak only while its start generation is still the live one.
    ///
    /// `AppModel.scenePhaseChanged(.background)` bumps the generation and cancels the task, so a
    /// late `await` after the lock returns here as false and never reaches `speech.say`.
    /// Pinned by `aLockGenerationDropsThePreLockScene`.
    public static func maySpeak(started: Int, current: Int) -> Bool {
        started == current
    }
}
