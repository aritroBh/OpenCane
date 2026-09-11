//
//  NavActivityAttributes.swift
//  CaneKit (app + widget extension)
//
//  Live Activity payload: the next instruction and distance in the Dynamic Island / lock screen
//  so the sighted teammate can glance at the phone on the cane without unlocking it.
//

import ActivityKit
import Foundation

/// `nonisolated`: ActivityKit encodes this off the main actor.
nonisolated struct NavActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var instruction: String
        var distanceM: Int
        /// "turnLeft" / "turnRight" / "crossing" / "arrived" / "straight" — picks the glyph.
        var kind: String
    }
    var routeName: String
}
