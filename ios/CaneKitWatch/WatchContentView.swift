//
//  WatchContentView.swift
//  CaneKit Watch
//
//  Glanceable wrist screen: current instruction, distance, four buttons in three rows (Repeat,
//  Next, Describe | Recenter), crown = Next. Always dark (docs/design.md §6.6). VoiceOver:
//  instruction is a header, buttons carry hints.
//
//  Implements docs/design.md §6.6 (Watch face) and the watch columns of §5. §6.6 now documents
//  what is built: one page, no paging and no `ScrollView` (either container would take the
//  Digital Crown and "Next" would never fire), the distance in the inline navigation title, and
//  the phone-link glyph in the leading toolbar slot. Its "Not built" list — the two-page
//  `TabView`, a TRUSTED pill and a "crown: next" hint line — is the remaining gap. The layout
//  came out of the Step 10 review ("Repeat / Next / Describe / Recenter fit a 42–46 mm screen").
//
//  Owner / callers: created by `WatchApp`; all behaviour is `WatchModel`'s. Isolation: MainActor
//  (target default). Tests: none automated (no watch test bundle); `CrownAccumulator` is pinned
//  by the `crown…` tests in CaneKitLogic `NavSupportTests`; layout is checked by eye on 42 mm and
//  46 mm (CHANGELOG Step 5 / Step 10 device tests).
//
//  Accessibility contract: instruction = header with value "N meters to go"; phone-link glyph =
//  "Phone connected" / "Phone not connected"; buttons "Repeat", "Next", "Describe", "Recenter"
//  with hints. No XCUITest runs on the watch, so none of these is a test contract today; keep
//  them in step with the §6.6 label table instead.
//

import SwiftUI

/// The single watch screen. Reads `WatchModel` from the environment and starts it in `.task`.
struct WatchContentView: View {
    /// Shared watch model (link, haptics, crown accumulator), injected by `WatchApp`.
    @Environment(WatchModel.self) private var model
    /// Raw crown position; only the change between callbacks matters (see `onChange`).
    @State private var crown = 0.0

    /// `content` inside a `NavigationStack` whose inline title is the distance ("120 m", or
    /// "OpenCane" while unknown — the phone's -1 sentinel arrives as `nil`) and whose leading
    /// toolbar item is the phone-link glyph (green radiowaves when reachable, red `iphone.slash`).
    var body: some View {
        // NavigationStack reserves the clock strip at the top; we spend that strip on the distance
        // ("120 m") and the phone-link glyph instead of adding rows, so everything fits a 42–46 mm
        // screen without a ScrollView (a ScrollView would take the crown and "Next" never fires).
        NavigationStack {
            content
                .navigationTitle(model.distanceM.map { "\($0) m" } ?? "OpenCane")
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
    ///
    /// The instruction is capped at 2 lines scaled to 70 % so the three button rows stay on a
    /// 42 mm screen; Repeat is the recovery for a cut line (design.md §10). Modifier order
    /// matters: `.focusable()` must come before `.digitalCrownRotation`, or the crown never
    /// reaches this view. `by: 1` defines the "detent" unit `CrownAccumulator` counts. The
    /// ±1,000,000 range is far beyond any real rotation, so the raw value never reaches an end
    /// (where `isContinuous` would wrap it and hand `crownMoved` one enormous delta).
    /// `.task { model.start() }` may run more than once; `WatchModel.start()` is idempotent.
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
