//
//  CaneKitWidgetBundle.swift
//  CaneKitWidget
//
//  Widget extension entry: hosts the navigation Live Activity (Dynamic Island + lock screen).
//
//  Implements the extension side of docs/design.md §6.7. No home-screen widgets: the bundle
//  contains only `NavLiveActivity`.
//
//  Why it exists: ActivityKit renders a Live Activity only from a WidgetKit extension, so the
//  app (`LiveActivityController`) cannot draw its own Dynamic Island. Added in Steps 8–9.
//
//  Owner / callers: the system loads the `CaneKitWidget` app-extension target (bundle id
//  `com.aritro.canekit.widget`, frozen — AGENTS.md hard rule 6), embedded in `CaneKit.app` by
//  `ios/project.yml`. ⚠ It must land in `CaneKit.app/PlugIns/`: Step 14 found that a `gen.sh`
//  patch had moved it out, so no installed build had ever shown the Live Activity and nothing
//  failed loudly. `ios/scripts/gen.sh` now asserts the embed phase after a full generate (skipped
//  with `WATCH=0` or `PATCH_WATCH_EMBED=0`); on the phone, check `CaneKit.app/PlugIns/`.
//  Module `watch-widget-shared` in docs/CODE_REFERENCE.md. Does not link CaneKitLogic.
//  Tests: none automated (no XCUITest reaches the lock screen); device test in CHANGELOG
//  "Steps 8–9" (walk the route → Dynamic Island shows the next instruction + distance).
//
//  Accessibility contract: none of its own; see NavLiveActivity.swift.
//

import SwiftUI
import WidgetKit

/// `@main` entry of the `com.aritro.canekit.widget` extension; vends the one Live Activity.
@main
struct CaneKitWidgetBundle: WidgetBundle {
    /// The bundle's only widget. Add a home-screen widget here, not a second `@main`.
    var body: some Widget {
        NavLiveActivity()
    }
}
