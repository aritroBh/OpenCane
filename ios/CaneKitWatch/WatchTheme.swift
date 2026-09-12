//
//  WatchTheme.swift
//  CaneKit Watch
//
//  Watch subset of the design system (docs/design.md §6.6). The watch is always dark: OLED,
//  wrist-down, black ground. No lane ladder here; the watch never shows the depth grid.
//  Text on any coloured fill is `WKColor.ink`, same rule as the phone.
//
//  Implements docs/design.md §6.6 and §8 ("`WKBigButton`, `WKFont`, `WKColor` in
//  WatchTheme.swift; watch is always dark"), with hex values taken from the dark column of §2.
//  Deviation from §3: the watch touch target is 44 pt (HIG minimum), not 48 pt — see
//  `WKSpacing.touchTarget` for why.
//
//  Accessibility contract: `WKBigButton` exposes `accessibilityLabel(title)`, hint and value;
//  its SF Symbol is hidden so VoiceOver reads the word once.
//

import SwiftUI

/// Watch colours: fixed dark-mode values (no light / HC variants; the watch is always dark).
enum WKColor {
    /// Screen ground: true black (OLED pixels off).
    static let background = Color.black
    /// Secondary button fill (the phone's dark `surfaceRaised`).
    static let surface    = rgb(0x26231F)   // secondary button fill
    /// Primary text on black and on `surface`: cane ivory.
    static let text       = rgb(0xF4F1EA)   // cane ivory
    /// Secondary text (the phone's dark `textSecondary`). Currently unused on the watch face.
    static let secondary  = rgb(0xB5AFA3)
    /// Primary button fill: cane ivory. Ink text on top.
    static let accent     = rgb(0xF4F1EA)
    /// Text on every coloured fill (primary / destructive buttons).
    static let ink        = rgb(0x17140F)
    /// "Phone connected" glyph (= phone `laneClear`).
    static let trusted    = rgb(0x4ADE80)
    /// Degraded-state colour (= phone `warning`). Currently unused on the watch face.
    static let warning    = rgb(0xFBBF24)
    /// "Phone not connected" glyph, error line, destructive fill (= phone `laneUrgent`).
    static let danger     = rgb(0xF87171)

    /// 0xRRGGBB → opaque sRGB `Color`. `nonisolated`: a pure helper callable from any isolation.
    nonisolated private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}

/// Watch text styles (system faces, Dynamic Type–relative).
enum WKFont {
    /// Instruction: 3 lines max, scale to 0.7, never truncate.
    /// (WatchContentView currently caps it at 2 lines + 0.7 scale to fit the buttons.)
    static let instruction = Font.system(.title3, design: .default).weight(.semibold)
    /// Distance: rounded, heavy, tabular so "120 m" → "119 m" doesn't jitter.
    /// Currently unused: the distance is shown in the inline navigation title (system font).
    static let distance    = Font.system(.title, design: .rounded).weight(.heavy).monospacedDigit()
    /// Full-width button labels.
    static let button      = Font.system(.headline, design: .rounded).weight(.semibold)
    /// Status pills. Currently unused: no pill is drawn on the watch face.
    static let pill        = Font.system(.caption, design: .rounded).weight(.bold)
    /// Error / status line under the buttons.
    static let footnote    = Font.footnote
}

/// Watch spacing and touch-target metrics.
enum WKSpacing {
    /// 4 pt: gap between the half-width buttons; screen side padding.
    static let xs: CGFloat = 4
    /// 8 pt: between rows on the watch face.
    static let sm: CGFloat = 8
    /// 12 pt: inner horizontal padding of a full-width button.
    static let md: CGFloat = 12
    /// HIG minimum. Instruction (2 lines) + three 44 pt rows fit a 42 mm screen under the
    /// inline title; 48 pushed the bottom row off the 46 mm bezel.
    static let touchTarget: CGFloat = 44
}

/// Full-width watch button: word + symbol, ≥ 48 pt tall, VoiceOver hint required in production.
///
/// (Actual minimum height is `WKSpacing.touchTarget`, 44 pt.) Accessibility: label = `title`,
/// hint = `hint`, value = `value`; the symbol is `accessibilityHidden`. The compact variant keeps
/// the full title as the label even when the caption shrinks.
struct WKBigButton: View {
    /// Fill pairing: `primary` = ivory with ink text, `secondary` = `surface` with ivory text,
    /// `destructive` = `danger` with ink text.
    enum Role { case primary, secondary, destructive }

    /// Visible word and VoiceOver label.
    let title: String
    /// SF Symbol beside (or above, when compact) the word; hidden from VoiceOver.
    let systemImage: String
    /// Visual role; see `Role`.
    var role: Role = .primary
    /// VoiceOver hint: what happens, in one sentence.
    var hint: String? = nil
    /// Optional VoiceOver value (e.g. "Describing…").
    var value: String? = nil
    /// Half-width variant: symbol over a caption, centred — two of these share a row without
    /// truncating ("De…" / "Rece…" at 46 mm). VoiceOver still reads the full title.
    var compact: Bool = false
    /// Tap handler (runs on the main actor).
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if compact {
                    VStack(spacing: 2) {
                        Image(systemName: systemImage).font(.headline.weight(.bold)).accessibilityHidden(true)
                        Text(title).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .padding(.horizontal, WKSpacing.xs)
                } else {
                    HStack(spacing: WKSpacing.sm) {
                        Image(systemName: systemImage).font(.headline.weight(.bold)).accessibilityHidden(true)
                        Text(title).font(WKFont.button).lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, WKSpacing.md)
                }
            }
            .frame(maxWidth: .infinity, minHeight: WKSpacing.touchTarget)
            .foregroundStyle(role == .secondary ? WKColor.text : WKColor.ink)
            .background(fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(hint ?? "")
        .accessibilityValue(value ?? "")
    }

    /// Background colour per role.
    private var fill: Color {
        switch role {
        case .primary: WKColor.accent
        case .secondary: WKColor.surface
        case .destructive: WKColor.danger
        }
    }
}
