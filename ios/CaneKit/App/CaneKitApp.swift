//
//  CaneKitApp.swift
//  CaneKit
//
//  App entry point. Owns the single `AppModel`, keeps the screen awake (ARKit dies when the
//  screen locks) and forwards scene-phase changes so the engines can pause/resume.
//
//  Why it exists: SwiftUI needs one `@main` type. Keeping it this small means every behaviour
//  (engines, settings, the route sequence) lives in `AppModel`, where App Intents can reach it
//  too (`AppModel.shared`). Nothing else in the app creates an `AppModel`.
//
//  Owner: module `app-core` (docs/CODE_REFERENCE.md). The system creates exactly one `CaneKitApp`.
//  Callers: none in code — the system launches it, including when an App Intent wakes the app
//  (the intent then waits for `AppModel.started` in `IntentSupport.model()`).
//
//  Threading / isolation: SwiftUI `App` — main actor (also the project default isolation).
//
//  Key invariants:
//    · Exactly one `AppModel` per process (`@State`), injected with `.environment(model)`.
//    · ⚠ Do not remove `isIdleTimerDisabled = true` without a device walk test — the camera
//      (hence LiDAR obstacle detection) stops the moment the screen locks.
//    · `model.start()` is idempotent, so `.task` re-running is safe.
//
//  Tests: no unit tests (nothing numeric lives here). Launch and `start()` run under every
//  XCUITest (`ios/CaneKitUITests/CaneKitUITests.swift`, `CaneKitVisualTour.swift`) and every
//  `make e2e` scenario (`ios/scripts/e2e.py`, which reads the trip log `start()` opens).
//

import SwiftUI

/// `@main` entry: one window showing `ContentView`, backed by the single `AppModel`.
@main
struct CaneKitApp: App {
    /// The one model that owns every engine. Created once for the app's lifetime.
    @State private var model = AppModel()
    /// Foreground / inactive / background; forwarded to `AppModel.scenePhaseChanged(_:)`.
    @Environment(\.scenePhase) private var scenePhase

    /// Root scene: disables the idle timer and starts the engines on first appearance.
    /// `.task` can run again when the window's view identity is rebuilt; both of its statements
    /// are safe to repeat (`start()` guards on `started`). `.onChange(of: scenePhase)` does not
    /// fire for the initial phase, which is fine: `scenePhaseChanged` is a no-op until `start()`.
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task {
                    // Keep the display on: the camera (and therefore LiDAR) stops the moment the
                    // screen locks, and the app has no background mode that could rescue it.
                    UIApplication.shared.isIdleTimerDisabled = true
                    model.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    model.scenePhaseChanged(phase)
                }
        }
    }
}
