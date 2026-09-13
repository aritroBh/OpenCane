//
//  TalkControlIntent.swift
//  CaneKit (app + widget extension)
//
//  The App Intent behind the Control Center / Lock Screen / Action button control "Talk to
//  OpenCane" (`TalkControl` in ios/CaneKitWidget/OpenCaneControls.swift, Step 64).
//
//  Why a second intent (not `TalkToOpenCaneIntent`): a `ControlWidgetButton` needs its intent type
//  compiled into the widget extension, and `TalkToOpenCaneIntent`'s `perform` reaches `AppModel`,
//  which the extension does not have. This file is compiled into both targets
//  (`ios/project.yml`: `Shared/Intents`); `openAppWhenRun` makes the system run the APP's copy,
//  whose `perform` toggles push-to-talk exactly like an Action button press. The widget's copy
//  (`CANEKIT_WIDGET`, set only on the widget target) is metadata and never does anything.
//
//  Owner: module `watch-widget-shared`. Not discoverable in Shortcuts (`isDiscoverable = false`):
//  the App Shortcut "Talk to OpenCane" already is, and two entries with one name would confuse.
//  Tests: none automated (App Intents); device: add the control in Control Center, tap it → the
//  app opens listening (`voice_toggle {source: control}` in the trip log).
//

import AppIntents

/// Opens OpenCane and toggles push-to-talk. Foreground only (the camera path needs the app up).
struct TalkControlIntent: AppIntent {
    /// Shown under the control.
    static let title: LocalizedStringResource = "Talk to OpenCane"
    /// Control-only; the App Shortcut is the discoverable one.
    static let isDiscoverable = false
    /// ⚠ Must open the app: obstacle warnings and the microphone live in the app process.
    static let openAppWhenRun: Bool = true

    init() {}

    #if CANEKIT_WIDGET
    /// Widget-extension copy: never runs (`openAppWhenRun`), present so the control compiles.
    func perform() async throws -> some IntentResult { .result() }
    #else
    /// App copy: waits for the model and toggles push-to-talk (`AppModel.toggleVoiceInput`).
    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        model.toggleVoiceInput(source: "control")
        return .result()
    }
    #endif
}
