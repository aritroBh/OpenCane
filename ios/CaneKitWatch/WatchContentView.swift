//
//  WatchContentView.swift
//  CaneKit Watch
//
//  Glanceable wrist screen: current instruction, distance, three big buttons, crown = Next.
//  Always dark (docs/design.md §6.6). VoiceOver: instruction is a header, buttons carry hints.
//
//  Implements docs/design.md §6.6 (Watch face) and the watch column of §5. Deviations from the
//  §6.6 wireframe: one page instead of a two-page `TabView` (a paged / scrolling container would
//  take the crown), four buttons (Repeat, Next, Describe, Recenter), the distance lives in the
//  inline navigation title, and button labels are the short visible words rather than the §6.6
//  "Next waypoint" / "Describe surroundings" / "Recentre beacon" copy.
//
//  Accessibility contract: instruction = header with value "N meters to go"; phone-link glyph =
//  "Phone connected" / "Phone not connected"; buttons "Repeat", "Next", "Describe", "Recenter"
//  with hints. No XCUITest runs on the watch, so none of these is a test contract today.
//

import SwiftUI

/// The single watch screen. Reads `WatchModel` from the environment and starts it in `.task`.
struct WatchContentView: View {
    /// Shared watch model (link, haptics, crown accumulator), injected by `WatchApp`.
    @Environment(WatchModel.self) private var model
    /// Raw crown position; only the change between callbacks matters (see `onChange`).
    @State private var crown = 0.0

    var body: some View {
        // NavigationStack reserves the clock strip at the top; we spend that strip on the distance
        // ("120 m") and the phone-link glyph instead of adding rows, so everything fits a 42–46 mm
        // screen without a ScrollView (a ScrollView would take the crown and "Next" never fires).
        NavigationStack {
            content
                .navigationTitle(model.distanceM.map { "\($0) m" } ?? "CaneKit")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        // Phone link state in words for VoiceOver; colour is a companion only.
                        Image(systemName: model.phoneReachable ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                            .foregroundStyle(model.phoneReachable ? WKColor.trusted : WKColor.danger)
                            .accessibilityLabel(model.phoneReachable ? "Phone connected" : "Phone not connected")
                    }
                }
        }
    }

    /// Instruction + buttons + error line, with the crown bound to "Next" and the model started.
    ///
    /// Accessibility: the instruction is a header whose value is the distance ("N meters to go");
    /// each `WKBigButton` is labelled by its title with a one-sentence hint. The error line is a
    /// plain text so VoiceOver reads it in place.
    private var content: some View {
        VStack(alignment: .leading, spacing: WKSpacing.sm) {
                Text(model.instruction)
                    .font(WKFont.instruction)
                    .foregroundStyle(WKColor.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityValue(model.distanceM.map { "\($0) meters to go" } ?? "")
                WKBigButton(title: "Repeat", systemImage: "arrow.counterclockwise",
                            hint: "Says the current instruction again") { model.send(.repeatLast) }
                WKBigButton(title: "Next", systemImage: "forward.fill", role: .secondary,
                            hint: "Skips to the next instruction") { model.send(.nextWaypoint) }
                // Half-width pair: keeps the screen to three button rows (fits 42–46 mm, no scroll).
                HStack(spacing: WKSpacing.xs) {
                    WKBigButton(title: "Describe", systemImage: "eye", role: .secondary,
                                hint: "Asks the phone to describe the scene ahead", compact: true) { model.send(.describe) }
                    WKBigButton(title: "Recenter", systemImage: "location.north.line", role: .secondary,
                                hint: "Sets straight ahead as the beacon's forward direction", compact: true) { model.send(.recenter) }
                }
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

/// Canvas preview with a fresh `WatchModel` (shows "Waiting for the phone" until a phone links).
#Preview {
    WatchContentView()
        .environment(WatchModel())
}
