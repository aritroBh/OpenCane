//
//  Theme.swift
//  CaneKit
//
//  Design tokens and the three reusable components. The prose twin is docs/design.md;
//  when the two disagree, fix this file.
//
//  Implements docs/design.md §1 (typography → CKFont), §2 (colour tokens → CKColor),
//  §3 (spacing, radius, touch targets → CKSpacing / CKRadius / CKMetrics), §4 (the one owned
//  animation: big-button press), §7 ("Do not" list) and §8 (implementation notes for the twin).
//
//  Rules baked in here so views can't get them wrong:
//    · every colour has light / dark / increased-contrast variants (UIKit trait providers)
//    · text on any coloured fill is always `CKColor.ink`
//    · numbers that change use tabular digits
//    · big buttons are ≥ 72 pt tall, carry a word and a symbol, and take a VoiceOver hint
//    · Reduce Motion is honoured by the only animation we own (button press)
//
//  Accessibility contract:
//    · `CKBigButton` exposes `accessibilityLabel(title)`. XCUITests query `app.buttons[title]`,
//      so every `title` string passed in from GuideCard is a ⚠ test contract (AGENTS.md rule 9).
//    · `CKBigButtonStyle` is also applied to plain `Button`s (Go, haptic / wrist test buttons);
//      those set their own labels at the call site.
//    · `CKStatusPill` is one VoiceOver element whose label is `spoken ?? text`.
//    · `CKCard` is a `.contain` container: titled cards are rotor stops, children stay reachable.
//
//  Swift 6, default MainActor isolation (project.yml). The colour helper is `nonisolated`
//  because UIKit may resolve dynamic colours off the main thread.
//

import SwiftUI
import UIKit

// MARK: - Colour

/// Semantic colours. See docs/design.md §2 for the hex table and contrast ratios.
///
/// Every token is a dynamic `Color` that re-resolves for light / dark and Increase Contrast, so
/// no view in the app constructs a `Color` literal (design.md §8). Nothing here is colour-only
/// meaning: every lane fill is paired with a level word and a number in `LaneTile`.
enum CKColor {

    // Surfaces: warm neutrals tinted toward cane ivory, never pure grey.
    /// Screen ground behind every card (`ContentView`). Ivory in light, near-black in dark.
    static let background    = dynamic(0xF4F1EA, 0x0E0D0B, hcLight: 0xFFFFFF, hcDark: 0x000000)
    /// `CKCard` fill. Flat: elevation is a fill change plus a hairline, never a shadow (§7).
    static let surface       = dynamic(0xFFFFFF, 0x1A1816, hcLight: 0xFFFFFF, hcDark: 0x0A0A0A)
    /// Secondary-button fill and the no-data tile fill (via `laneNoData` / `neutral`).
    static let surfaceRaised = dynamic(0xEAE6DD, 0x26231F, hcLight: 0xE3DED3, hcDark: 0x141210)
    /// Hairlines on cards and secondary buttons; flips to pure black / white under Increase Contrast.
    static let border        = dynamic(0xC9C3B6, 0x3A362F, hcLight: 0x000000, hcDark: 0xFFFFFF)

    // Text.
    /// Body text on `background` / `surface` (≥ 14:1).
    static let textPrimary   = dynamic(0x17140F, 0xF4F1EA, hcLight: 0x000000, hcDark: 0xFFFFFF)
    /// Hints, card titles, secondary rows (≥ 6.5:1). Never used for text a hazard depends on.
    static let textSecondary = dynamic(0x5C574D, 0xB5AFA3, hcLight: 0x3A362F, hcDark: 0xD9D4C9)

    /// The brand accent is "cane white on ink": ink in light mode, ivory in dark mode.
    /// It never carries hazard meaning; hazard is only ever the lane ladder below.
    static let accent   = dynamic(0x17140F, 0xF4F1EA, hcLight: 0x000000, hcDark: 0xFFFFFF)
    /// Text / symbols on an `accent` fill (primary `CKBigButton`).
    static let onAccent = dynamic(0xF4F1EA, 0x0E0D0B, hcLight: 0xFFFFFF, hcDark: 0x000000)
    /// Text on every coloured fill (lane tiles, pills, banners). One rule, no exceptions.
    static let ink      = dynamic(0x17140F, 0x17140F, hcLight: 0x000000, hcDark: 0x000000)

    // Lane ladder: identical in light and dark (the fill *is* the signal), brighter in HC.
    // Thresholds live in CaneKitLogic.TileLevel: clear ≥ 2.0 m, far ≥ 1.2, near ≥ 0.7, urgent < 0.7.
    /// Tile ≥ 2.0 m (level word CLEAR). 11.4:1 against `ink`. Also the `trusted` pill tone.
    static let laneClear  = dynamic(0x4ADE80, 0x4ADE80, hcLight: 0x22D36B, hcDark: 0x22D36B)
    /// Tile 1.2–2.0 m (level word FAR). 15.2:1 against `ink`.
    static let laneFar    = dynamic(0xFDE047, 0xFDE047, hcLight: 0xFFD500, hcDark: 0xFFD500)
    /// Tile 0.7–1.2 m (level word NEAR). 8.9:1 against `ink`. Close in hue to `laneFar` for
    /// deuteranopes, which is why the tile's word and number are mandatory.
    static let laneNear   = dynamic(0xFB923C, 0xFB923C, hcLight: 0xFF7A00, hcDark: 0xFF7A00)
    /// Tile < 0.7 m (level word STOP). 7.1:1 against `ink`. Also error-line text and `danger`.
    static let laneUrgent = dynamic(0xF87171, 0xF87171, hcLight: 0xFF6B6B, hcDark: 0xFF6B6B)
    /// Tile with no depth data ("—" / NO DATA); text on it is `textSecondary`, not `ink`.
    static let laneNoData = surfaceRaised

    // Status.
    /// Pill tone for a healthy state (TRUSTED, Engine OK, Reachable, GPS within 15 m).
    static let trusted = laneClear
    /// Pill tone for a degraded-but-working state (SWEEPING, GPS weak, Speaking, No AirPods).
    static let warning = dynamic(0xFBBF24, 0xFBBF24, hcLight: 0xFFB000, hcDark: 0xFFB000)
    /// Destructive button fill (Stop route) and failure pills (Engine down).
    static let danger  = laneUrgent
    /// Idle / informational pill tone; text on it is `textPrimary` (the only non-ink pill).
    static let neutral = surfaceRaised

    /// Builds a `Color` that re-resolves for light/dark and Increase Contrast automatically.
    ///
    /// - Parameters: 0xRRGGBB for light, dark, high-contrast light and high-contrast dark.
    /// - Note: `nonisolated` because UIKit may call the trait provider off the main thread; the
    ///   closure touches only its value-type captures.
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
///
/// Implements the scale table in docs/design.md §1. `secondary` (15 pt) is the smallest size a
/// user ever reads; `mono` (13 pt) is allowed only inside `accessibilityHidden` developer views.
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
    /// Toggle labels, scene description text, route names.
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
///
/// docs/design.md §3. Values are layout only; none of them carry meaning.
enum CKSpacing {
    /// 4 pt: icon-to-text inside a pill.
    static let xs: CGFloat = 4      // icon-to-text inside a pill
    /// 8 pt: between pills; tile gap.
    static let sm: CGFloat = 8      // between pills; tile gap
    /// 12 pt: rows inside a card.
    static let md: CGFloat = 12     // rows inside a card
    /// 16 pt: card padding; between big buttons.
    static let lg: CGFloat = 16     // card padding; between big buttons
    /// 24 pt: between sections (cards on the root scroll view).
    static let xl: CGFloat = 24     // between sections
    /// 32 pt: above the button stack on Guide.
    static let xxl: CGFloat = 32    // above the button stack on Guide
    /// 20 pt: screen-edge padding.
    static let gutter: CGFloat = 20 // screen edge
}

/// Corner radii (docs/design.md §3). All shapes use `.continuous` corners.
enum CKRadius {
    /// Depth tiles.
    static let tile: CGFloat = 14
    /// Big buttons: ¼ of the 72 pt height so they read as slabs, not pills.
    static let button: CGFloat = 18 // ¼ of the 72 pt height: a slab, not a pill
    /// Cards.
    static let card: CGFloat = 20
    /// Status pills (effectively a capsule).
    static let pill: CGFloat = 999
}

/// Touch-target and stroke metrics (docs/design.md §3 "Touch targets", §8 "Border width").
enum CKMetrics {
    /// Minimum height of anything tappable on the phone. Big buttons use `bigButton`.
    static let touchTarget: CGFloat = 60
    /// `CKBigButton` minimum height (design.md §3: 72 pt, full or half width).
    static let bigButton: CGFloat = 72
    /// Hairline normally; a real border under Increase Contrast.
    static func border(for contrast: ColorSchemeContrast) -> CGFloat {
        contrast == .increased ? 3 : 1
    }
}

// MARK: - CKBigButton

/// The only button on Guide, Route and Arrival. ≥ 72 pt tall, full width by default, a word plus
/// an SF Symbol, and a VoiceOver hint that says what happens (docs/design.md §6 has the copy).
///
/// Accessibility: label = `title` (⚠ test contract: XCUITests find it as `app.buttons[title]`),
/// hint = `hint`, value = `value`; the SF Symbol is hidden so VoiceOver reads the word once.
/// The visible text never truncates: it wraps, and at accessibility sizes the row restacks.
struct CKBigButton: View {
    /// Fill / foreground pairing: `primary` = accent (ink / ivory), `secondary` = raised surface
    /// with a border, `destructive` = `danger` fill with ink text (Stop route).
    enum Role { case primary, secondary, destructive }

    /// Visible word and VoiceOver label. ⚠ test contract for every title used by the XCUITests.
    let title: String
    /// SF Symbol shown beside the word; hidden from VoiceOver (a companion, never the only cue).
    let systemImage: String
    /// Visual role; see `Role`.
    var role: Role = .primary
    /// VoiceOver hint: what the button does, in one sentence. Optional only for previews.
    var hint: String? = nil
    /// Optional VoiceOver value ("Describing…") while the action is in flight.
    var value: String? = nil
    /// Tap handler. Runs on the main actor.
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
        // ⚠ test contract: the label is exactly `title`; do not decorate it.
        .accessibilityLabel(title)
        .accessibilityHint(hint ?? "")
        .accessibilityValue(value ?? "")
    }

    /// The companion SF Symbol, hidden from VoiceOver so the label is read once.
    private var icon: some View {
        Image(systemName: systemImage)
            .font(.title2.weight(.bold))
            .accessibilityHidden(true)
    }

    /// The visible word; wraps vertically instead of truncating (design.md §1, §7).
    private var text: some View {
        Text(title)
            .font(CKFont.button)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Fill + border per role, press feedback that respects Reduce Motion, a visible focus ring.
///
/// Implements docs/design.md §4 "Big button press": scale 0.97 on a 120 ms spring, or opacity
/// 0.85 only under Reduce Motion; the light impact haptic is kept either way (it fires on
/// release). This is the only animation and the only non-cue haptic the app owns (§7).
/// Disabled buttons drop to 40 % opacity; VoiceOver announces "dimmed" from `.disabled`.
struct CKBigButtonStyle: ButtonStyle {
    /// Picks fill, foreground and border; shared with `CKBigButton.Role`.
    let role: CKBigButton.Role
    /// Reduce Motion swaps the scale spring for a plain opacity change.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Increase Contrast thickens the secondary border (via `CKMetrics.border(for:)`).
    @Environment(\.colorSchemeContrast) private var contrast
    /// Drives the 40 % disabled opacity.
    @Environment(\.isEnabled) private var isEnabled

    /// Applies fill, border, disabled / pressed feedback and the release haptic to the label.
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

    /// Background colour per role.
    private var fill: Color {
        switch role {
        case .primary: CKColor.accent
        case .secondary: CKColor.surfaceRaised
        case .destructive: CKColor.danger
        }
    }

    /// Text / symbol colour per role; `ink` on the coloured destructive fill (one rule, §2).
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
///
/// Accessibility: one element (children ignored) labelled `spoken ?? text`, so a terse visible
/// word can carry a full spoken sentence. Always has a word: never colour-only (design.md §7).
/// Adds `.updatesFrequently` when asked, so VoiceOver re-reads a live pill on focus (§5 rule).
struct CKStatusPill: View {
    /// Fill colour family: `trusted` / `warning` / `danger` use `ink` text; `neutral` uses
    /// `textPrimary` on the raised surface; `accent` is ink-on-ivory / ivory-on-ink (the brand
    /// pairing) for a mark that is not a state — today only the "Campus" badge on a destination
    /// suggestion (design.md §2, §6.3). Accent never carries hazard meaning.
    enum Tone { case trusted, warning, danger, neutral, accent }

    /// Visible word(s); uppercased when drawn. Also the VoiceOver label when `spoken` is nil.
    let text: String
    /// Fill colour family; see `Tone`.
    var tone: Tone = .neutral
    /// Optional leading SF Symbol (a companion; the element's label comes from the text).
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
                .lineLimit(1)                       // a pill never hyphenates ("SPEAK-ING")
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, CKSpacing.md)
        .frame(minHeight: 32)
        .background(fill, in: Capsule())
        // One element: the icon and the uppercased text are replaced by the spoken label.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken ?? text)
        .accessibilityAddTraits(updatesFrequently ? .updatesFrequently : [])
    }

    /// Capsule fill per tone.
    private var fill: Color {
        switch tone {
        case .trusted: CKColor.trusted
        case .warning: CKColor.warning
        case .danger: CKColor.danger
        case .neutral: CKColor.neutral
        case .accent: CKColor.accent
        }
    }

    /// Text / symbol colour: `ink` on every coloured fill (§2, one rule), `textPrimary` on the
    /// raised neutral surface, `onAccent` on the accent fill.
    private var foreground: Color {
        switch tone {
        case .neutral: CKColor.textPrimary
        case .accent: CKColor.onAccent
        default: CKColor.ink
        }
    }
}

// MARK: - CKCard

/// A flat surface with a hairline. Groups its children as one VoiceOver container whose label
/// is the title, so the rotor can jump card to card.
///
/// docs/design.md §3 (radius 20, `lg` padding, no shadow) and §8 ("`CKCard(title:)` groups
/// children as one VoiceOver container"). The title is drawn as a `.isHeader` so the headings
/// rotor stops on "Guide", "Obstacles", "Haptics", "Watch", "Mount", "This phone", "Arrived" /
/// "This trip". An untitled card (ContentView's status card) gets an empty label here and sets
/// its own label afterwards.
struct CKCard<Content: View>: View {
    /// Optional card heading; also the container's VoiceOver label.
    var title: String? = nil
    /// The card's rows.
    @ViewBuilder let content: () -> Content
    /// Increase Contrast thickens the card border to 3 pt.
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

/// Xcode canvas preview of every component in one stack (design review only; no test uses it).
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
