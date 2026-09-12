//
//  WatchApp.swift
//  CaneKit Watch
//
//  watchOS companion entry point (`@main` of the `CaneKitWatch` target, bundle id
//  `com.aritro.canekit.watchkitapp`, display name OpenCane). Scaffolded in Steps 1–2 to prove the
//  target builds, signs and installs; Step 5 added WatchConnectivity, wrist haptics, crown input
//  and the walking-workout keep-alive, all of which live in `WatchModel`, not here.
//
//  Why it exists: the watch is the walker's second hand — wrist taps for turns / crossings /
//  arrival and mirrored obstacle cues, plus Repeat / Next / Describe / Recenter without touching
//  the phone clamped to the cane (AGENTS.md "What this is").
//
//  Implements the process entry for docs/design.md §6.6 (Watch face): one `WatchModel` per
//  process, injected into `WatchContentView` through the Observation environment.
//
//  Owner / callers: the system launches it; module `watch-widget-shared` in
//  docs/CODE_REFERENCE.md. Isolation: MainActor (target default).
//  Tests: none automated — the watch target has no test bundle and no XCUITest reaches it. The
//  logic it relies on is unit-tested in CaneKitLogic (`WatchMessageTests`, the `crown…` tests in
//  `NavSupportTests`); the rest is the CHANGELOG "Step 5 — Watch" device test and
//  docs/devices_setup.md.
//
//  Accessibility contract: none of its own; all labels live in WatchContentView / WatchTheme.
//

import SwiftUI

/// The watch app. Owns the single `WatchModel` for the process lifetime; the view starts it
/// (`model.start()` in `.task`), so creating it here has no side effects.
@main
struct WatchApp: App {
    /// The one model: link to the phone, wrist haptics, crown accumulator, keep-alive session.
    @State private var model = WatchModel()

    /// One window showing the wrist screen, with `model` in the environment (read there as
    /// `@Environment(WatchModel.self)`). No other scenes: no complications, no notifications UI.
    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environment(model)
        }
    }
}
