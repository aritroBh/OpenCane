//
//  HapticsCard.swift
//  CaneKit
//
//  Step 3 debug/controls: engine health, the cue currently rendering, silence toggle, and four
//  test buttons that bypass the decider so the patterns can be felt through the clamp.
//  Also the obstacle-name toggle, speech status / voice-backend pills and a speech test.
//
//  Implements docs/design.md §5 (the "Felt" column: each test button plays one CueKind pattern)
//  and the CUES group of §6.5 ("Silence phone haptics", with the watch + speech taking over).
//
//  Accessibility contract (AGENTS.md rule 9):
//    ⚠ test contract buttons: "Test left haptic", "Test center haptic", "Test right haptic",
//      "Test head haptic" (built from the testButton titles) — used by both XCUITest classes.
//    ⚠ test contract switch: "Silence haptics" (`app.switches["Silence haptics"]`).
//  Pills speak full sentences via `spoken`; the live ones carry `.updatesFrequently`.
//

import CaneKitLogic
import SwiftUI

/// "Haptics" card: Taptic engine health, active obstacle cue, silence toggle, four pattern test
/// buttons, the obstacle-name toggle, speech pills and the speech test button.
struct HapticsCard: View {
    /// App-wide owner of `haptics`, `speech`, `activeCue` and the persisted toggles.
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        CKCard(title: "Haptics") {
            HStack(spacing: CKSpacing.sm) {
                CKStatusPill(text: model.haptics.isHealthy ? "Engine OK" : "Engine down",
                             tone: model.haptics.isHealthy ? .trusted : .danger,
                             systemImage: model.haptics.isHealthy ? "waveform" : "exclamationmark.triangle",
                             spoken: model.haptics.isHealthy ? "Haptic engine running" : "Haptic engine not running")
                CKStatusPill(text: cueWord, tone: model.activeCue == .clear ? .neutral : .warning,
                             spoken: "Active cue: \(cueWord)", updatesFrequently: true)
            }
            if let err = model.haptics.lastError {
                Text(err).font(CKFont.secondary).foregroundStyle(CKColor.laneUrgent)
            }
            // ⚠ test contract: switches["Silence haptics"].
            Toggle("Silence haptics", isOn: $model.hapticsSilenced)
                .font(CKFont.body).foregroundStyle(CKColor.textPrimary)
                .accessibilityHint("The phone stops vibrating; obstacle cues go to the watch and are spoken instead")
            Text("Test patterns").font(CKFont.secondary).foregroundStyle(CKColor.textSecondary)
            // ⚠ test contract: these titles become "Test <title lowercased> haptic".
            HStack(spacing: CKSpacing.sm) {
                testButton("Left", "arrow.left", .left)
                testButton("Center", "arrow.up", .center)
                testButton("Right", "arrow.right", .right)
                testButton("Head", "arrow.up.to.line", .head)
            }
            Toggle("Speak obstacle names", isOn: $model.obstacleNamesEnabled)
                .font(CKFont.body).foregroundStyle(CKColor.textPrimary)
                .accessibilityHint("Says door, wall, seat, window or table when one is straight ahead")
            HStack(spacing: CKSpacing.sm) {
                CKStatusPill(text: model.speech.isSpeaking ? "Speaking" : "Quiet",
                             tone: model.speech.isSpeaking ? .warning : .neutral,
                             systemImage: "speaker.wave.2", updatesFrequently: true)
                // "System" / "ElevenLabs": one word so the pill row fits a 17 Pro Max with the button.
                CKStatusPill(text: model.speech.naturalVoice == nil ? "System" : model.speech.backendName,
                             tone: model.speech.naturalVoice == nil ? .neutral : .trusted,
                             systemImage: "waveform.and.mic",
                             spoken: model.speech.naturalVoice == nil ? "System voice; add an ElevenLabs key for the natural voice" : "Voice: \(model.speech.backendName)")
                Spacer(minLength: 0)
            }
            // Own row: sharing the pill row squeezed "Speaking" to "SPEAKI…" on a 17 Pro Max.
            CKBigButton(title: "Speech test", systemImage: "speaker.wave.3", role: .secondary,
                        hint: "Speaks a scene line, then an obstacle line that interrupts it") { model.speechTest() }
            if let err = model.speech.audioSessionError {
                Text(err).font(CKFont.secondary).foregroundStyle(CKColor.laneUrgent)
            }
        }
    }

    /// Visible word for the active obstacle cue (`CueKind`): Clear / Center / Left / Right / Head.
    private var cueWord: String {
        switch model.activeCue {
        case .clear: return "Clear"
        case .center: return "Center"
        case .left: return "Left"
        case .right: return "Right"
        case .head: return "Head"
        }
    }

    /// A 60 pt pattern test button that plays `kind` directly on the haptic player, bypassing
    /// `CueDecider`, so each pattern can be felt through the clamp without an obstacle.
    ///
    /// Accessibility: label "Test <title lowercased> haptic" (⚠ test contract for the four
    /// titles above); hint says the center pattern is a two-second approach loop, the others
    /// play once. The icon + caption are the visible word-plus-symbol pair (design.md §7).
    /// - Parameters:
    ///   - title: visible caption and the word inside the VoiceOver label.
    ///   - symbol: SF Symbol drawn above the caption.
    ///   - kind: the obstacle cue pattern to play.
    private func testButton(_ title: String, _ symbol: String, _ kind: CueKind) -> some View {
        Button {
            model.haptics.test(kind)
        } label: {
            VStack(spacing: CKSpacing.xs) {
                Image(systemName: symbol).font(.title3.weight(.bold))
                Text(title).font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: CKMetrics.touchTarget)
        }
        .buttonStyle(CKBigButtonStyle(role: .secondary))
        // ⚠ test contract: "Test left/center/right/head haptic".
        .accessibilityLabel("Test \(title.lowercased()) haptic")
        .accessibilityHint(kind == .center ? "Plays the approach loop for two seconds" : "Plays the pattern once")
    }
}
