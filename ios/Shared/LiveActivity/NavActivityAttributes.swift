//
//  NavActivityAttributes.swift
//  CaneKit (app + widget extension)
//
//  Live Activity payload: the next instruction and distance in the Dynamic Island / lock screen
//  so the sighted teammate can glance at the phone on the cane without unlocking it.
//
//  Owner: module `watch-widget-shared` (docs/CODE_REFERENCE.md). Compiled into two targets
//  (`ios/project.yml` lists `Shared/LiveActivity` as a source of both, not the watch):
//  the app (producer: `LiveActivityController`) and `CaneKitWidget` (consumer: `NavLiveActivity`).
//  Why `Shared/`: the widget extension does not link the app, and `CaneKitLogic` must stay
//  ActivityKit-free (Foundation only), so the one type both sides need lives here.
//
//  Threading / isolation: `nonisolated` value type — ActivityKit encodes/decodes it off the
//  main actor, so it must not inherit the app target's MainActor default isolation.
//
//  Tests: none automated (ActivityKit needs a device); CHANGELOG "Steps 8–9" device test.
//
//  Key invariants:
//    · This is a wire contract between two processes: renaming or retyping a field breaks the
//      widget until both targets are rebuilt and reinstalled together.
//    · Every `kind` string the app sends must be handled by the widget's glyph switch
//      (`CaneKitWidget/NavLiveActivity.swift`).
//

import ActivityKit
import Foundation

/// The navigation Live Activity's attributes: the static route name plus the `ContentState`
/// that changes during the walk. `nonisolated`: ActivityKit encodes this off the main actor.
nonisolated struct NavActivityAttributes: ActivityAttributes {
    /// The dynamic part, replaced on every (coalesced) update from `LiveActivityController`:
    /// a new state is pushed only when `instruction` or `kind` changes or `distanceM` moves ≥ 10 m.
    struct ContentState: Codable, Hashable {
        /// The current waypoint's spoken line (`NavigationEngine.instruction`); on `end` the final
        /// line (`"Arrived: <say>"` on arrival, "Route ended" on Stop).
        var instruction: String
        /// Whole metres to the next waypoint (`NavigationEngine.distanceToNext`, rounded); 0 when
        /// unknown and at the end. Unlike the watch status there is no -1 sentinel.
        var distanceM: Int
        /// "turnLeft" / "turnRight" / "crossing" / "arrived" / "straight" — picks the glyph.
        /// `NavCue.rawValue` of the last wrist cue (veers included), "straight" at route start,
        /// "arrived" on `end`. `NavCue.obstacle` exists but the navigation engine never emits it.
        var kind: String
    }
    /// Static for the activity's lifetime: the route name ("ISR Townsend Hall to CIF" for the
    /// bundled route, "To <place>" for a MapKit route — `RouteSource`).
    var routeName: String
}
