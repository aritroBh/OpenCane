//
//  NavActivityAttributes.swift
//  CaneKit (app + widget extension)
//
//  Live Activity payload: the next instruction and distance in the Dynamic Island / lock screen
//  so the sighted teammate can glance at the phone on the cane without unlocking it.
//
//  Owner: module `watch-widget-shared` (docs/CODE_REFERENCE.md). Compiled into two targets:
//  the app (producer: `LiveActivityController`) and `CaneKitWidget` (consumer: `NavLiveActivity`).
//
//  Threading / isolation: `nonisolated` value type — ActivityKit encodes/decodes it off the
//  main actor, so it must not inherit the app target's MainActor default isolation.
//
//  Key invariants:
//    · This is a wire contract between two processes: renaming or retyping a field breaks the
//      widget until both targets are rebuilt and reinstalled together.
//    · Every `kind` string the app sends must be handled by the widget's glyph switch
//      (`CaneKitWidget/NavLiveActivity.swift`).
//

import ActivityKit
import Foundation

/// `nonisolated`: ActivityKit encodes this off the main actor.
nonisolated struct NavActivityAttributes: ActivityAttributes {
    /// The dynamic part, replaced on every (coalesced) update from `LiveActivityController`.
    struct ContentState: Codable, Hashable {
        /// The next waypoint's spoken line (`NavigationEngine.instruction`), or the final line.
        var instruction: String
        /// Metres to the next waypoint, rounded; 0 when unknown or arrived.
        var distanceM: Int
        /// "turnLeft" / "turnRight" / "crossing" / "arrived" / "straight" — picks the glyph.
        var kind: String
    }
    /// Static for the activity's lifetime: the route name ("ISR Townsend Hall to CIF", "To …").
    var routeName: String
}
