//
//  AppIntents.swift
//  CaneKit
//
//  "Where am I" App Shortcut so the Action button (Settings → Action Button → Shortcut) and Siri
//  can trigger a scene description. The intent opens the app (ARKit needs the foreground) and
//  hands off to the shared model, which waits for a first camera frame.
//
//  Purpose: the three App Intents (Where am I / Start route / Repeat) plus their
//  `AppShortcutsProvider`. Each intent only forwards to a public `AppModel` method, so the
//  Action button, Siri and the on-screen buttons share one code path.
//
//  Owner: module `app-core` (docs/CODE_REFERENCE.md). The system instantiates the intents; they
//  reach the live model through `AppModel.shared` (intents run inside the app process).
//
//  Threading / isolation: `perform()` is `@MainActor` (AppModel is main-actor). The intent structs
//  themselves are value types with only static metadata.
//
//  Key invariants:
//    · ⚠ `supportedModes` must stay `.foreground(.immediate)` — `describeScene()` needs a live
//      ARKit frame, which exists only while the app is frontmost.
//    · Every shortcut phrase must contain `\(.applicationName)` (App Shortcuts requirement).
//

import AppIntents
import Foundation

/// Action button / Siri "Where am I": one-sentence scene description via `AppModel.describeScene()`.
struct WhereAmIIntent: AppIntent {
    /// Shown in Shortcuts and the Action button picker.
    static let title: LocalizedStringResource = "Where am I"
    /// Subtitle in Shortcuts.
    static let description = IntentDescription("Describes the scene ahead in one sentence.")
    /// ⚠ Foreground only: ARKit (and therefore the describer) needs the app frontmost.
    static let supportedModes: IntentModes = .foreground(.immediate)

    /// Waits for the model (cold launch) and triggers a scene description.
    /// Throws `IntentSupport.NotReady` if the model never appears within 2 s.
    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        model.describeScene()
        return .result()
    }
}

/// Siri / Shortcuts "Start my route": starts the bundled ISR Townsend Hall → CIF demo route.
struct StartDemoRouteIntent: AppIntent {
    /// Shown in Shortcuts.
    static let title: LocalizedStringResource = "Start CaneKit route"
    /// Subtitle in Shortcuts.
    static let description = IntentDescription("Starts the recorded ISR Townsend Hall to CIF route.")
    /// Foreground: guidance needs ARKit, the audio session and the screen kept awake.
    static let supportedModes: IntentModes = .foreground(.immediate)

    /// Waits for the model and calls `AppModel.startDemoRoute()`.
    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        model.startDemoRoute()
        return .result()
    }
}

/// Siri / Shortcuts "Repeat": says the last route line again (same path as the watch Repeat).
struct RepeatInstructionIntent: AppIntent {
    /// Shown in Shortcuts.
    static let title: LocalizedStringResource = "Repeat instruction"
    /// Subtitle in Shortcuts.
    static let description = IntentDescription("Says the current route instruction again.")
    /// Foreground, like the other intents, so it lands in the running guidance session.
    static let supportedModes: IntentModes = .foreground(.immediate)

    /// Waits for the model and calls `AppModel.repeatInstruction()`.
    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        model.repeatInstruction()
        return .result()
    }
}

/// Shared helpers for the intents above.
enum IntentSupport {
    /// Thrown when the SwiftUI scene has not created `AppModel` within the wait window; Siri
    /// speaks the localized message instead of silently doing nothing.
    struct NotReady: Error, CustomLocalizedStringResourceConvertible {
        /// Spoken / shown by the system when the intent fails.
        var localizedStringResource: LocalizedStringResource { "CaneKit is still starting. Try again." }
    }

    /// On a cold launch from the lock screen the SwiftUI scene may not have created the model
    /// yet; wait briefly instead of silently doing nothing.
    /// Polls `AppModel.shared` 20 × 100 ms (2 s total), then throws `NotReady`.
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
/// `shortTitle` / `systemImageName` are what the Action button and Spotlight show.
struct CaneKitShortcuts: AppShortcutsProvider {
    /// The three shortcuts, in display order.
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
