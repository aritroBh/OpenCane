//
//  AppIntents.swift
//  CaneKit
//
//  "Where am I" App Shortcut so the Action button (Settings → Action Button → Shortcut) and Siri
//  can trigger a scene description. The intent opens the app (ARKit needs the foreground) and
//  hands off to the shared model, which waits for a first camera frame.
//

import AppIntents
import Foundation

struct WhereAmIIntent: AppIntent {
    static let title: LocalizedStringResource = "Where am I"
    static let description = IntentDescription("Describes the scene ahead in one sentence.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        model.describeScene()
        return .result()
    }
}

struct StartDemoRouteIntent: AppIntent {
    static let title: LocalizedStringResource = "Start CaneKit route"
    static let description = IntentDescription("Starts the recorded ISR Townsend Hall to CIF route.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        model.startDemoRoute()
        return .result()
    }
}

struct RepeatInstructionIntent: AppIntent {
    static let title: LocalizedStringResource = "Repeat instruction"
    static let description = IntentDescription("Says the current route instruction again.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        model.repeatInstruction()
        return .result()
    }
}

enum IntentSupport {
    struct NotReady: Error, CustomLocalizedStringResourceConvertible {
        var localizedStringResource: LocalizedStringResource { "CaneKit is still starting. Try again." }
    }

    /// On a cold launch from the lock screen the SwiftUI scene may not have created the model
    /// yet; wait briefly instead of silently doing nothing.
    @MainActor
    static func model() async throws -> AppModel {
        for _ in 0..<20 {
            if let m = AppModel.shared { return m }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NotReady()
    }
}

/// Registered at install; phrases must include the app name.
struct CaneKitShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WhereAmIIntent(),
                    phrases: ["Where am I in \(.applicationName)", "\(.applicationName) describe the scene"],
                    shortTitle: "Where am I",
                    systemImageName: "eye")
        AppShortcut(intent: StartDemoRouteIntent(),
                    phrases: ["Start my route in \(.applicationName)"],
                    shortTitle: "Start route",
                    systemImageName: "figure.walk")
        AppShortcut(intent: RepeatInstructionIntent(),
                    phrases: ["Repeat in \(.applicationName)", "\(.applicationName) say that again"],
                    shortTitle: "Repeat",
                    systemImageName: "arrow.counterclockwise")
    }
}
