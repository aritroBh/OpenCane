//
//  WatchCard.swift
//  CaneKit
//
//  Step 5 controls: link state, fallback toggle, and buttons that send each wrist cue so the
//  haptic map can be felt without walking a route.
//

import CaneKitLogic
import SwiftUI

struct WatchCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        CKCard(title: "Watch") {
            HStack(spacing: CKSpacing.sm) {
                CKStatusPill(text: linkWord, tone: model.watch.isReachable ? .trusted : .neutral,
                             systemImage: model.watch.isReachable ? "applewatch.radiowaves.left.and.right" : "applewatch.slash",
                             spoken: "Watch: \(linkWord)", updatesFrequently: true)
                if let cmd = model.watch.lastReceived {
                    CKStatusPill(text: cmd.rawValue, spoken: "Last watch command: \(cmd.rawValue)")
                }
            }
            if let err = model.watch.lastError {
                Text(err).font(CKFont.secondary).foregroundStyle(CKColor.laneUrgent)
            }
            Toggle("Mirror obstacle cues to the watch", isOn: $model.fallbackToWatch)
                .font(CKFont.body).foregroundStyle(CKColor.textPrimary)
                .accessibilityHint("Also taps the wrist for every obstacle; automatic when the phone's haptic engine fails")
            Text("Send wrist cue").font(CKFont.secondary).foregroundStyle(CKColor.textSecondary)
            HStack(spacing: CKSpacing.sm) {
                testButton("Left", "arrow.turn.up.left", .turnLeft)
                testButton("Right", "arrow.turn.up.right", .turnRight)
                testButton("Cross", "figure.walk", .crossing)
                testButton("Arrive", "flag.checkered", .arrived)
            }
        }
    }

    private var linkWord: String {
        if !model.watch.isSupported { return "Unsupported" }
        if !model.watch.isPaired { return "Not paired" }
        if !model.watch.isWatchAppInstalled { return "App not installed" }
        return model.watch.isReachable ? "Reachable" : "Asleep"
    }

    private func testButton(_ title: String, _ symbol: String, _ cue: NavCue) -> some View {
        Button {
            model.watchTest(cue)
        } label: {
            VStack(spacing: CKSpacing.xs) {
                Image(systemName: symbol).font(.title3.weight(.bold))
                Text(title).font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: CKMetrics.touchTarget)
        }
        .buttonStyle(CKBigButtonStyle(role: .secondary))
        .disabled(!model.watch.isReachable)
        .accessibilityLabel("Send \(title.lowercased()) cue to the watch")
    }
}
