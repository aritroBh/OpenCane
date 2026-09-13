//
//  WatchCard.swift
//  CaneKit
//
//  Step 5 controls: link state, fallback toggle, and buttons that send each wrist cue so the
//  haptic map can be felt without walking a route.
//
//  Implements docs/design.md §5 (the "Shown (watch)" / wrist-haptic column: one button per
//  NavCue) and the "Mirror cues to watch" row of §6.5.
//
//  Accessibility contract: the link pill speaks "Watch: <state>" and updates live; each send
//  button is labelled "Send <cue> cue to the watch" and is disabled (VoiceOver: "dimmed") while
//  the watch is unreachable. No XCUITest queries this card (the simulator has no watch), so
//  none of its strings are a test contract; the visual tour only photographs it.
//
//  Owner / caller: `SettingsPage` in ContentView.swift (between `HapticsCard` and the Mount card).
//  Data: `AppModel.watch` (`PhoneWatchLink`, WatchConnectivity state) and `fallbackToWatch`.
//  Tests: none automated; the wire format it sends through is pinned by `WatchMessageTests`.
//

import CaneKitLogic
import SwiftUI

/// "Watch" card: WatchConnectivity link state, last command received from the watch, the
/// mirror-obstacles-to-watch toggle, and four wrist-cue test buttons.
struct WatchCard: View {
    /// App-wide owner of `watch` (PhoneWatchLink) and the `fallbackToWatch` setting.
    @Environment(AppModel.self) private var model

    /// Link pill (+ the last watch command, e.g. "describe", when one arrived), link error in red,
    /// the persisted mirror toggle, and the four send buttons in one row.
    var body: some View {
        @Bindable var model = model
        CKCard(title: "Watch", systemImage: "applewatch") {
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
            CKToggleRow(title: "Also tap my wrist", subtitle: "Sends obstacle taps to the watch too",
                        isOn: $model.fallbackToWatch,
                        hint: "Also taps the wrist for every obstacle; happens by itself if the phone can't vibrate")
            Text("Try a wrist tap").font(CKFont.secondary).foregroundStyle(CKColor.textSecondary)
            HStack(spacing: CKSpacing.sm) {
                testButton("Left", "arrow.turn.up.left", .turnLeft)
                testButton("Right", "arrow.turn.up.right", .turnRight)
                testButton("Cross", "figure.walk", .crossing)
                testButton("Arrive", "flag.checkered", .arrived)
            }
        }
    }

    /// Link pill word. First failing check wins: "Unsupported" → "Not paired" →
    /// "App not installed" → "Reachable" / "Asleep" (paired and installed but not reachable).
    private var linkWord: String {
        if !model.watch.isSupported { return "No watch" }
        if !model.watch.isPaired { return "Not paired" }
        if !model.watch.isWatchAppInstalled { return "App not installed" }
        return model.watch.isReachable ? "Connected" : "Asleep"
    }

    /// A 60 pt button that sends one `NavCue` to the watch so its wrist haptic can be felt
    /// without walking a route. Disabled unless the watch is reachable.
    ///
    /// Accessibility: label "Send <title lowercased> cue to the watch"; the icon + caption are
    /// the visible word-plus-symbol pair.
    /// - Parameters:
    ///   - title: visible caption and the word inside the VoiceOver label.
    ///   - symbol: SF Symbol drawn above the caption.
    ///   - cue: the navigation cue sent via `AppModel.watchTest(_:)`.
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
