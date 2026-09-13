//
//  TabBar.swift
//  CaneKit
//
//  Four icon-only root tabs under ContentView: Guide (walk), Sense (obstacles + hazards; nav title
//  "Details"), Settings (cues, haptics, watch, mount, family alerts), Profile (Medical ID +
//  mobility, Step 44). The visible control is an SF Symbol; the word is the
//  VoiceOver label and the XCUITest `app.buttons[...]` key (docs/design.md §6, §9).
//
//  The sliding ivory/ink capsule and the icon scale honour Reduce Motion (instant swap).
//  Tab changes do not speak through SpeechQueue — VoiceOver already announces the selected
//  button; a spoken cue would double-speak (design.md §7).
//
//  Accessibility contract: ⚠ test contract labels "Guide", "Sense", "Settings", "Profile"
//  (CaneKitUITests + CaneKitVisualTour). Hit target ≥ `CKMetrics.touchTarget` (60 pt).
//
//  Owner / caller: `ContentView.body` (`CKTabBar(selection: $tab)` under the page).
//  Tests: `CaneKitUITests.testAccessibilityLabelsExist` and the `openTab(_:)` helper the other
//  tests use; `CaneKitVisualTour` photographs each page. Motion timing is hand-tuned, not tested.
//

import SwiftUI

/// The four pages of the phone app. Raw value is the left-to-right order and the `ForEach`
/// identity; the pill's travel comes from `matchedGeometryEffect`, not from the raw value.
enum RootTab: Int, CaseIterable, Identifiable, Hashable {
    /// Walk a route: Guide card + the trip / arrival card.
    case guide
    /// What the cane sees: depth status, obstacle grid, hazards.
    case sense
    /// Kit configuration: haptics, watch, mount, this phone.
    case settings
    /// Medical ID card, emergency profile and mobility fitness stats.
    case profile

    /// Stable `ForEach` identity; matches `rawValue`.
    var id: Int { rawValue }

    /// VoiceOver label and XCUITest button key. ⚠ test contract: do not rename without the tests.
    var title: String {
        switch self {
        case .guide: "Guide"
        case .sense: "Details"      // UI audit 2026-09-13: was "Sense"; now matches the page title
        case .settings: "Settings"
        case .profile: "Profile"
        }
    }

    /// SF Symbol drawn in the tab. Hidden from VoiceOver (the word is `title`).
    var systemImage: String {
        switch self {
        case .guide: "figure.walk"
        case .sense: "square.grid.3x3.fill"
        case .settings: "gearshape.fill"
        case .profile: "person.crop.circle"
        }
    }

    /// VoiceOver hint: what this page is for, in one sentence.
    var hint: String {
        switch self {
        case .guide: "Walk a route and hear the next instruction"
        case .sense: "What the cane sees: obstacles and hazards ahead"
        case .settings: "Alerts, voice, the phone on the cane and family alerts"
        case .profile: "Medical ID and today's activity"
        }
    }
}

/// Icon-only bottom bar: a sliding accent capsule behind the selected symbol.
///
/// Implements docs/design.md §4 (tab switch) and §6 (four pages). The capsule uses `matchedGeometryEffect`
/// so it travels between icons on a short spring; Reduce Motion skips the travel and the icon scale.
struct CKTabBar: View {
    /// Pill travel animation. Same landing time as the page fade (`ContentView.pageFade`)
    /// so capsule and page arrive together; the old 0.32 s spring was still travelling after
    /// the page had landed, which read as lag.
    private static func pillTravel() -> Animation {
        .spring(duration: 0.16, bounce: 0.08)
    }
    /// Width of the selected capsule (chrome only; the 60 pt hit area is wider).
    private static let pillWidth: CGFloat = 56
    /// Height of the selected capsule. Deliberately under `CKMetrics.touchTarget`: this is the
    /// drawn pill, not the tappable area, so the bar (pill + caption) stays a standard height.
    private static let pillHeight: CGFloat = 32

    /// The currently visible page; written on tap.
    @Binding var selection: RootTab
    /// Shared namespace for the sliding capsule.
    @Namespace private var pillNS
    /// Instant swap when the user asked for less motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Increase Contrast thickens the bar's top hairline.
    @Environment(\.colorSchemeContrast) private var contrast

    /// One row of equal-width tab buttons on the card surface with a top hairline; one VoiceOver
    /// container "OpenCane tabs"; a `.selection` haptic on every change of `selection` (the only
    /// app-owned haptic besides the big-button press).
    ///
    /// UI audit 2026-09-13: the surface now runs down under the home indicator
    /// (`ignoresSafeArea(edges: .bottom)`), so there is no ivory strip below the bar on Face ID
    /// phones and the bar still sits clear of the indicator; on a Home-button phone (no bottom
    /// inset) the `xs` padding keeps it off the edge. Four equal columns fit every iPhone width.
    var body: some View {
        HStack(spacing: 0) {
            ForEach(RootTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(.horizontal, CKSpacing.sm)
        .padding(.top, CKSpacing.xs)
        .padding(.bottom, CKSpacing.xs)
        .background(CKColor.surface.ignoresSafeArea(edges: .bottom))
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
                withAnimation(Self.pillTravel()) { selection = tab }
            }
        } label: {
            // UI audit 2026-09-13: a short visible word under each symbol (the icon-only bar made
            // sighted helpers guess which grid icon was which). The word is `tab.title`, the same
            // string VoiceOver reads, so what is seen and what is heard never differ.
            VStack(spacing: 2) {
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
                Text(tab.title)
                    .font(.caption.weight(selected ? .bold : .semibold))
                    .foregroundStyle(selected ? CKColor.textPrimary : CKColor.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityHidden(true)
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
