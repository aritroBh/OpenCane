//
//  HapticsCard.swift
//  CaneKit
//
//  Step 3 debug/controls: engine health, the cue currently rendering, silence toggle, and four
//  test buttons that bypass the decider so the patterns can be felt through the clamp.
//

import CaneKitLogic
import SwiftUI

struct HapticsCard: View {
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
            Toggle("Silence haptics", isOn: $model.hapticsSilenced)
                .font(CKFont.body).foregroundStyle(CKColor.textPrimary)
                .accessibilityHint("Cues are still decided and logged, but the phone does not vibrate")
            Text("Test patterns").font(CKFont.secondary).foregroundStyle(CKColor.textSecondary)
            HStack(spacing: CKSpacing.sm) {
                testButton("Left", "arrow.left", .left)
                testButton("Center", "arrow.up", .center)
                testButton("Right", "arrow.right", .right)
                testButton("Head", "arrow.up.to.line", .head)
            }
        }
    }

    private var cueWord: String {
        switch model.activeCue {
        case .clear: return "Clear"
        case .center: return "Center"
        case .left: return "Left"
        case .right: return "Right"
        case .head: return "Head"
        }
    }

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
        .accessibilityLabel("Test \(title.lowercased()) haptic")
        .accessibilityHint(kind == .center ? "Plays the approach loop for two seconds" : "Plays the pattern once")
    }
}
