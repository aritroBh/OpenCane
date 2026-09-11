//
//  CaneKitApp.swift
//  CaneKit
//
//  App entry point. Owns the single `AppModel`, keeps the screen awake (ARKit dies when the
//  screen locks) and forwards scene-phase changes so the engines can pause/resume.
//

import SwiftUI

@main
struct CaneKitApp: App {
    /// The one model that owns every engine. Created once for the app's lifetime.
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

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
