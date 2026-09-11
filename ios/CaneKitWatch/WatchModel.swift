//
//  WatchModel.swift
//  CaneKit Watch
//
//  State for the watch UI. Step 1: static placeholder. Step 5 wires WCSession, haptics,
//  the workout session and the crown → nextWaypoint mapping.
//

import CaneKitLogic
import Observation

@MainActor
@Observable
final class WatchModel {
    /// Current instruction text from the phone (step 5). Placeholder until then.
    var instruction = "Waiting for the phone"
    /// Distance to the next waypoint in metres, if known.
    var distanceM: Int?
    /// Whether the phone app is reachable over WatchConnectivity.
    var phoneReachable = false

    init() {}
}
