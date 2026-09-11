//
//  WatchApp.swift
//  CaneKit Watch
//
//  watchOS companion entry point. Step 1: proves the target builds, signs and installs.
//  Step 5 adds WatchConnectivity, haptics, crown input and the walking workout session.
//

import SwiftUI

@main
struct WatchApp: App {
    @State private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environment(model)
        }
    }
}
