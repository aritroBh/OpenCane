//
//  TabBar.swift
//  CaneKit
//
//  Three icon-only root tabs under ContentView: Guide (walk), Sense (obstacles + hazards),
//  Settings (haptics, watch, mount). The visible control is an SF Symbol; the word is the
//  VoiceOver label and the XCUITest `app.buttons[...]` key (docs/design.md §6, §9).
//
//  The sliding ivory/ink capsule and the icon scale honour Reduce Motion (instant swap).
//  Tab changes do not speak through SpeechQueue — VoiceOver already announces the selected
//  button; a spoken cue would double-speak (design.md §7).
//
//  Accessibility contract: ⚠ test contract labels "Guide", "Sense", "Settings"
//  (CaneKitUITests + CaneKitVisualTour). Hit target ≥ `CKMetrics.touchTarget` (60 pt).
//

import SwiftUI

/// The three pages of the phone app. Raw value is left-to-right order (used to slide the pill).
enum RootTab: Int, CaseIterable, Identifiable, Hashable {
    /// Walk a route: Guide card + the trip / arrival card.
    case guide
    /// What the cane sees: depth status, obstacle grid, hazards.
    case sense
    /// Kit configuration: haptics, watch, mount, this phone.
    case settings

    /// Stable `ForEach` identity; matches `rawValue`.
    var id: Int { rawValue }

    /// VoiceOver label and XCUITest button key. ⚠ test contract: do not rename without the tests.
    var title: String {
        switch self {
        case .guide: "Guide"
        case .sense: "Sense"
        case .settings: "Settings"
        }
    }

    /// SF Symbol drawn in the tab. Hidden from VoiceOver (the word is `title`).
    var systemImage: String {
        switch self {
        case .guide: "figure.walk"
        case .sense: "square.grid.3x3.fill"
        case .settings: "gearshape.fill"
        }
    }

    /// VoiceOver hint: what this page is for, in one sentence.
    var hint: String {
        switch self {
        case .guide: "Walk a route and hear the next instruction"
        case .sense: "Obstacles, depth and hazards ahead"
        case .settings: "Haptics, watch, mount and this phone"
        }
    }
}

/// Icon-only bottom bar: a sliding accent capsule behind the selected symbol.
///
/// Implements docs/design.md §4 (tab switch) and §6 (three pages). The capsule uses `matchedGeometryEffect`
/// so it travels between icons on a short spring; Reduce Motion skips the travel and the icon scale.
struct CKTabBar: View {
    /// Width of the selected capsule (chrome only; the 60 pt hit area is wider).
    private static let pillWidth: CGFloat = 62
    /// Height of the selected capsule. Deliberately under `CKMetrics.touchTarget`: this is the
    /// drawn pill, not the tappable area, so the bar stays a standard height.
    private static let pillHeight: CGFloat = 36

    /// The currently visible page; written on tap.
    @Binding var selection: RootTab
    /// Shared namespace for the sliding capsule.
    @Namespace private var pillNS
    /// Instant swap when the user asked for less motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Increase Contrast thickens the bar's top hairline.
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 0) {
            ForEach(RootTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(.horizontal, CKSpacing.sm)
        .padding(.vertical, CKSpacing.xs)
        .background(CKColor.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(CKColor.border)
                .frame(height: CKMetrics.border(for: contrast))
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("OpenCane tabs")
        .sensoryFeedback(.selection, trigger: selection)
    }

    /// One icon-only tab. The word lives only in VoiceOver / XCUITest (`title`).
    ///
    /// Layout: a fixed `pill` box holds the symbol and the selected capsule, so the bar keeps a
    /// compact standard height. A `Capsule` is a flexible shape — drawn as a sibling in a `ZStack`
    /// it accepts the whole proposed height and the bar grows to fill the screen, so it goes in
    /// `.background` of a fixed frame instead. The 60 pt hit area (design.md §3) sits outside it.
    /// - Parameter tab: which page this control selects.
    private func tabButton(_ tab: RootTab) -> some View {
        let selected = selection == tab
        return Button {
            guard selection != tab else { return }
            if reduceMotion {
                selection = tab
            } else {
                withAnimation(.spring(duration: 0.32, bounce: 0.14)) { selection = tab }
            }
        } label: {
            Image(systemName: tab.systemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(selected ? CKColor.onAccent : CKColor.textSecondary)
                .scaleEffect(selected && !reduceMotion ? 1.06 : 1)
                .frame(width: Self.pillWidth, height: Self.pillHeight)
                .background {
                    if selected {
                        Capsule()
                            .fill(CKColor.accent)
                            .matchedGeometryEffect(id: "tab-pill", in: pillNS)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: CKMetrics.touchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // ⚠ test contract: the label is exactly `tab.title`.
        .accessibilityLabel(tab.title)
        .accessibilityHint(tab.hint)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("Tab bar") {
    @Previewable @State var tab = RootTab.guide
    VStack {
        Spacer()
        CKTabBar(selection: $tab)
    }
    .background(CKColor.background)
}
