//
//  WatchApp.swift
//  CaneKit Watch
//
//  watchOS companion entry point. Step 1: proves the target builds, signs and installs.
//  Step 5 adds WatchConnectivity, haptics, crown input and the walking workout session.
//
//  Implements the process entry for docs/design.md §6.6 (Watch face): one `WatchModel` per
//  process, injected into `WatchContentView` through the Observation environment.
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

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environment(model)
        }
    }
}
