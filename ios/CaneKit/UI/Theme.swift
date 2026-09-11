//
//  Theme.swift
//  CaneKit
//
//  Design tokens and the three reusable components. The prose twin is docs/design.md;
//  when the two disagree, fix this file.
//
//  Rules baked in here so views can't get them wrong:
//    · every colour has light / dark / increased-contrast variants (UIKit trait providers)
//    · text on any coloured fill is always `CKColor.ink`
//    · numbers that change use tabular digits
//    · big buttons are ≥ 72 pt tall, carry a word and a symbol, and take a VoiceOver hint
//    · Reduce Motion is honoured by the only animation we own (button press)
//
//  Swift 6, default MainActor isolation (project.yml). The colour helper is `nonisolated`
//  because UIKit may resolve dynamic colours off the main thread.
//

import SwiftUI
import UIKit

// MARK: - Colour

/// Semantic colours. See docs/design.md §2 for the hex table and contrast ratios.
enum CKColor {

    // Surfaces: warm neutrals tinted toward cane ivory, never pure grey.
    static let background    = dynamic(0xF4F1EA, 0x0E0D0B, hcLight: 0xFFFFFF, hcDark: 0x000000)
    static let surface       = dynamic(0xFFFFFF, 0x1A1816, hcLight: 0xFFFFFF, hcDark: 0x0A0A0A)
    static let surfaceRaised = dynamic(0xEAE6DD, 0x26231F, hcLight: 0xE3DED3, hcDark: 0x141210)
    static let border        = dynamic(0xC9C3B6, 0x3A362F, hcLight: 0x000000, hcDark: 0xFFFFFF)

    // Text.
    static let textPrimary   = dynamic(0x17140F, 0xF4F1EA, hcLight: 0x000000, hcDark: 0xFFFFFF)
    static let textSecondary = dynamic(0x5C574D, 0xB5AFA3, hcLight: 0x3A362F, hcDark: 0xD9D4C9)

    /// The brand accent is "cane white on ink": ink in light mode, ivory in dark mode.
    /// It never carries hazard meaning; hazard is only ever the lane ladder below.
    static let accent   = dynamic(0x17140F, 0xF4F1EA, hcLight: 0x000000, hcDark: 0xFFFFFF)
    static let onAccent = dynamic(0xF4F1EA, 0x0E0D0B, hcLight: 0xFFFFFF, hcDark: 0x000000)
    /// Text on every coloured fill (lane tiles, pills, banners). One rule, no exceptions.
    static let ink      = dynamic(0x17140F, 0x17140F, hcLight: 0x000000, hcDark: 0x000000)

    // Lane ladder: identical in light and dark (the fill *is* the signal), brighter in HC.
    // Thresholds live in CaneKitLogic.TileLevel: clear ≥ 2.0 m, far ≥ 1.2, near ≥ 0.7, urgent < 0.7.
    static let laneClear  = dynamic(0x4ADE80, 0x4ADE80, hcLight: 0x22D36B, hcDark: 0x22D36B)
    static let laneFar    = dynamic(0xFDE047, 0xFDE047, hcLight: 0xFFD500, hcDark: 0xFFD500)
    static let laneNear   = dynamic(0xFB923C, 0xFB923C, hcLight: 0xFF7A00, hcDark: 0xFF7A00)
    static let laneUrgent = dynamic(0xF87171, 0xF87171, hcLight: 0xFF6B6B, hcDark: 0xFF6B6B)
    static let laneNoData = surfaceRaised

    // Status.
    static let trusted = laneClear
    static let warning = dynamic(0xFBBF24, 0xFBBF24, hcLight: 0xFFB000, hcDark: 0xFFB000)
    static let danger  = laneUrgent
    static let neutral = surfaceRaised

    /// Builds a `Color` that re-resolves for light/dark and Increase Contrast automatically.
    nonisolated private static func dynamic(_ light: UInt32, _ dark: UInt32,
                                            hcLight: UInt32, hcDark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hc = traits.accessibilityContrast == .high
            let isDark = traits.userInterfaceStyle == .dark
            let hex = isDark ? (hc ? hcDark : dark) : (hc ? hcLight : light)
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        })
    }
}

// MARK: - Type

/// Text styles. System faces only: SF Pro for prose, SF Rounded for glanceable numbers and
/// button labels, SF Mono for the developer footer. Everything scales with Dynamic Type.
enum CKFont {
    /// Distance on Guide. Pass a value from `@ScaledMetric(relativeTo: .largeTitle) var hero = 64`.
    static func hero(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy, design: .rounded).monospacedDigit()
    }
    /// Metres inside a depth tile (28 pt base). Readable from a metre away.
    static let tile        = Font.system(.title, design: .rounded).weight(.bold).monospacedDigit()
    /// Current instruction. Max 3 lines, then `minimumScaleFactor(0.8)`, never truncated.
    static let instruction = Font.system(.title2, design: .default).weight(.semibold)
    /// Big button labels.
    static let button      = Font.system(.title3, design: .rounded).weight(.semibold)
    /// Card titles and settings rows.
    static let label       = Font.headline
    static let body        = Font.body
    /// Status pills: uppercase, 1–2 words, tracking added in the view.
    static let pill        = Font.system(.subheadline, design: .rounded).weight(.bold)
    /// Hints and secondary lines. The smallest user-facing size.
    static let secondary   = Font.subheadline
    /// Developer footer only; the view must be `accessibilityHidden(true)`.
    static let mono        = Font.system(.footnote, design: .monospaced).monospacedDigit()
}

// MARK: - Spacing, radius, metrics

/// 4 pt base. Named for intent so layouts read as decisions, not numbers.
enum CKSpacing {
    static let xs: CGFloat = 4      // icon-to-text inside a pill
    static let sm: CGFloat = 8      // between pills; tile gap
    static let md: CGFloat = 12     // rows inside a card
    static let lg: CGFloat = 16     // card padding; between big buttons
    static let xl: CGFloat = 24     // between sections
    static let xxl: CGFloat = 32    // above the button stack on Guide
    static let gutter: CGFloat = 20 // screen edge
}

enum CKRadius {
    static let tile: CGFloat = 14
    static let button: CGFloat = 18 // ¼ of the 72 pt height: a slab, not a pill
    static let card: CGFloat = 20
    static let pill: CGFloat = 999
}

enum CKMetrics {
    /// Minimum height of anything tappable on the phone. Big buttons use `bigButton`.
    static let touchTarget: CGFloat = 60
    static let bigButton: CGFloat = 72
    /// Hairline normally; a real border under Increase Contrast.
    static func border(for contrast: ColorSchemeContrast) -> CGFloat {
        contrast == .increased ? 3 : 1
    }
}

// MARK: - CKBigButton

/// The only button on Guide, Route and Arrival. ≥ 72 pt tall, full width by default, a word plus
/// an SF Symbol, and a VoiceOver hint that says what happens (docs/design.md §6 has the copy).
struct CKBigButton: View {
    enum Role { case primary, secondary, destructive }

    let title: String
    let systemImage: String
    var role: Role = .primary
    /// VoiceOver hint: what the button does, in one sentence. Optional only for previews.
    var hint: String? = nil
    /// Optional VoiceOver value ("Describing…") while the action is in flight.
    var value: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // At accessibility text sizes the row won't fit, so the label stacks under the icon.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: CKSpacing.md) { icon; text; Spacer(minLength: 0) }
                VStack(spacing: CKSpacing.xs) { icon; text }
            }
            .padding(.horizontal, CKSpacing.lg)
            .padding(.vertical, CKSpacing.md)
            .frame(maxWidth: .infinity, minHeight: CKMetrics.bigButton)
            .contentShape(RoundedRectangle(cornerRadius: CKRadius.button))
        }
        .buttonStyle(CKBigButtonStyle(role: role))
        .accessibilityLabel(title)
        .accessibilityHint(hint ?? "")
        .accessibilityValue(value ?? "")
    }

    private var icon: some View {
        Image(systemName: systemImage)
            .font(.title2.weight(.bold))
            .accessibilityHidden(true)
    }

    private var text: some View {
        Text(title)
            .font(CKFont.button)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Fill + border per role, press feedback that respects Reduce Motion, a visible focus ring.
struct CKBigButtonStyle: ButtonStyle {
    let role: CKBigButton.Role
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: CKRadius.button, style: .continuous)
        configuration.label
            .foregroundStyle(foreground)
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(CKColor.border, lineWidth: role == .secondary
                                        ? CKMetrics.border(for: contrast) + 1 : 0))
            .opacity(isEnabled ? 1 : 0.4)
            .opacity(configuration.isPressed && reduceMotion ? 0.85 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.12), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { $0 == false && $1 }
    }

    private var fill: Color {
        switch role {
        case .primary: CKColor.accent
        case .secondary: CKColor.surfaceRaised
        case .destructive: CKColor.danger
        }
    }

    private var foreground: Color {
        switch role {
        case .primary: CKColor.onAccent
        case .secondary: CKColor.textPrimary
        case .destructive: CKColor.ink
        }
    }
}

// MARK: - CKStatusPill

/// One or two uppercase words on a solid fill: TRUSTED, SWEEPING, HOT, 82%. Ink text always.
struct CKStatusPill: View {
    enum Tone { case trusted, warning, danger, neutral }

    let text: String
    var tone: Tone = .neutral
    var systemImage: String? = nil
    /// VoiceOver value when the visible text is too terse ("82%" → "Battery 82 percent").
    var spoken: String? = nil
    /// Set for pills that change on their own (TRUSTED/SWEEPING) so VoiceOver re-reads them.
    var updatesFrequently: Bool = false

    var body: some View {
        HStack(spacing: CKSpacing.xs) {
            if let systemImage {
                Image(systemName: systemImage).font(.subheadline.weight(.bold))
            }
            Text(text.uppercased())
                .font(CKFont.pill)
                .kerning(0.9)
                .monospacedDigit()
        }
        .foregroundStyle(tone == .neutral ? CKColor.textPrimary : CKColor.ink)
        .padding(.horizontal, CKSpacing.md)
        .frame(minHeight: 32)
        .background(fill, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken ?? text)
        .accessibilityAddTraits(updatesFrequently ? .updatesFrequently : [])
    }

    private var fill: Color {
        switch tone {
        case .trusted: CKColor.trusted
        case .warning: CKColor.warning
        case .danger: CKColor.danger
        case .neutral: CKColor.neutral
        }
    }
}

// MARK: - CKCard

/// A flat surface with a hairline. Groups its children as one VoiceOver container whose label
/// is the title, so the rotor can jump card to card.
struct CKCard<Content: View>: View {
    var title: String? = nil
    @ViewBuilder let content: () -> Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CKRadius.card, style: .continuous)
        VStack(alignment: .leading, spacing: CKSpacing.md) {
            if let title {
                Text(title)
                    .font(CKFont.label)
                    .foregroundStyle(CKColor.textSecondary)
                    .accessibilityAddTraits(.isHeader)
            }
            content()
        }
        .padding(CKSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CKColor.surface, in: shape)
        .overlay(shape.strokeBorder(CKColor.border, lineWidth: CKMetrics.border(for: contrast)))
        .accessibilityElement(children: .contain)
        // An empty label would override the children for VoiceOver; only label titled cards.
        .accessibilityLabel(title.map { Text($0) } ?? Text(""))
    }
}

// MARK: - Preview

#Preview("Components") {
    VStack(spacing: CKSpacing.lg) {
        HStack(spacing: CKSpacing.sm) {
            CKStatusPill(text: "Trusted", tone: .trusted, systemImage: "checkmark", updatesFrequently: true)
            CKStatusPill(text: "Sweeping", tone: .warning)
            CKStatusPill(text: "82%", spoken: "Battery 82 percent")
        }
        CKCard(title: "Next instruction") {
            Text("Turn left onto Goodwin Avenue").font(CKFont.instruction)
            Text("120 m").font(CKFont.hero(64)).foregroundStyle(CKColor.textPrimary)
        }
        CKBigButton(title: "Stop route", systemImage: "stop.fill", role: .destructive,
                    hint: "Ends guidance and shows the arrival summary") {}
        HStack(spacing: CKSpacing.lg) {
            CKBigButton(title: "Recenter", systemImage: "location.north.line", role: .secondary,
                        hint: "Sets straight ahead as the beacon's forward direction") {}
            CKBigButton(title: "Next", systemImage: "forward.fill", hint: "Skips to the next instruction") {}
        }
    }
    .padding(CKSpacing.gutter)
    .background(CKColor.background)
}
