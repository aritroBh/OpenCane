//
//  WatchContentView.swift
//  CaneKit Watch
//
//  Glanceable wrist screen: current instruction, distance, three big buttons, crown = Next.
//  Always dark (docs/design.md §6.6). VoiceOver: instruction is a header, buttons carry hints.
//

import SwiftUI

struct WatchContentView: View {
    @Environment(WatchModel.self) private var model
    @State private var crown = 0.0

    var body: some View {
        // No ScrollView: it would take the crown for scrolling and "Next" would never fire.
        VStack(alignment: .leading, spacing: WKSpacing.sm) {
                Text(model.instruction)
                    .font(WKFont.instruction)
                    .foregroundStyle(WKColor.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                if let d = model.distanceM {
                    Text("\(d) m")
                        .font(WKFont.distance)
                        .foregroundStyle(WKColor.text)
                        .accessibilityLabel("\(d) meters to go")
                }
                WKBigButton(title: "Next", systemImage: "forward.fill",
                            hint: "Skips to the next instruction") { model.send(.nextWaypoint) }
                WKBigButton(title: "Describe", systemImage: "eye", role: .secondary,
                            hint: "Asks the phone to describe the scene ahead") { model.send(.describe) }
                WKBigButton(title: "Recenter", systemImage: "location.north.line", role: .secondary,
                            hint: "Sets straight ahead as the beacon's forward direction") { model.send(.recenter) }
                HStack(spacing: WKSpacing.xs) {
                    Image(systemName: model.phoneReachable ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                    Text(model.phoneReachable ? "Phone connected" : "Phone not connected")
                    Spacer()
                    Text(model.keepAlive)
                }
                .font(WKFont.footnote)
                .foregroundStyle(WKColor.secondary)
                if let err = model.lastError {
                    Text(err).font(WKFont.footnote).foregroundStyle(WKColor.danger).lineLimit(1)
                }
        }
        .padding(.horizontal, WKSpacing.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WKColor.background)
        .focusable()
        // Crown rotation → "next" after three detents in either direction (debounced in the model).
        .digitalCrownRotation($crown, from: -1_000_000, through: 1_000_000, by: 1, sensitivity: .low,
                              isContinuous: true, isHapticFeedbackEnabled: true)
        .onChange(of: crown) { old, new in
            model.crownMoved(delta: new - old, now: Date().timeIntervalSinceReferenceDate)
        }
        .task { model.start() }
    }
}

#Preview {
    WatchContentView()
        .environment(WatchModel())
}
