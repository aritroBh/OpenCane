//
//  WatchTheme.swift
//  CaneKit Watch
//
//  Watch subset of the design system (docs/design.md §6.6). The watch is always dark: OLED,
//  wrist-down, black ground. No lane ladder here; the watch never shows the depth grid.
//  Text on any coloured fill is `WKColor.ink`, same rule as the phone.
//
//  Implements docs/design.md §6.6 and §8 ("`WKBigButton`, `WKFont`, `WKColor`, `WKSpacing` in
//  WatchTheme.swift; the watch is always dark"), with hex values taken from the dark column of §2.
//  The watch touch target is 44 pt (HIG minimum), not the phone's 60 pt; §3 records why
//  (48 pt pushed the bottom row off a 46 mm screen) — see `WKSpacing.touchTarget`.
//
//  Why a separate file: the phone's `Theme.swift` is compiled only into the iOS target and
//  resolves every colour through a UIKit trait-collection provider (`CKColor.dynamic`), and the
//  watch needs none of its light / high-contrast variants. Colours here are fixed `Color` values
//  on purpose (design.md §8), copied from the phone's dark column.
//
//  Owner / callers: `WatchContentView` only. Isolation: MainActor (target default); `rgb` is
//  `nonisolated`. Tests: none (visual; checked by eye on the watch). Tokens marked "unused" are
//  kept so a future row can match the phone palette without re-deriving the hex.
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
    /// Instruction: `.title3` semibold. `WatchContentView` caps it at 2 lines scaled to 70 % so the
    /// three button rows fit; a longer line is cut and Repeat speaks it in full (design.md §6.6).
    static let instruction = Font.system(.title3, design: .default).weight(.semibold)
    /// Distance: rounded, heavy, tabular so "120 m" → "119 m" doesn't jitter.
    /// Currently unused: the distance is shown in the inline navigation title (system font).
    static let distance    = Font.system(.title, design: .rounded).weight(.heavy).monospacedDigit()
    /// Full-width button labels.
    static let button      = Font.system(.headline, design: .rounded).weight(.semibold)
    /// Status pills. Currently unused: no pill is drawn on the watch face.
    static let pill        = Font.system(.caption, design: .rounded).weight(.bold)
    /// The red one-line error under the buttons (`WatchModel.lastError`).
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

/// Watch button: word + symbol, at least `WKSpacing.touchTarget` (44 pt) tall, radius 14
/// continuous; full width by default, half width when `compact`. Give every production button a
/// `hint` (the watch face is used eyes-free with VoiceOver).
///
/// Accessibility: label = `title`, hint = `hint`, value = `value`; the symbol is
/// `accessibilityHidden`. The compact variant keeps the full title as the label even when the
/// caption shrinks. `.buttonStyle(.plain)`: no system press highlight — the send confirm is the
/// `.click` haptic `WatchModel.send` plays.
struct WKBigButton: View {
    /// Fill pairing: `primary` = ivory with ink text, `secondary` = `surface` with ivory text,
    /// `destructive` = `danger` with ink text. The watch face uses primary (Repeat) and secondary
    /// (Next, Describe, Recenter); `destructive` has no caller today.
    enum Role { case primary, secondary, destructive }

    /// Visible word and VoiceOver label.
    let title: String
    /// SF Symbol beside (or above, when compact) the word; hidden from VoiceOver.
    let systemImage: String
    /// Visual role; see `Role`.
    var role: Role = .primary
    /// VoiceOver hint: what happens, in one sentence.
    var hint: String? = nil
    /// Optional VoiceOver value (e.g. "Describing…"). No watch button passes one today.
    var value: String? = nil
    /// Half-width variant: symbol over a caption, centred — two of these share a row without
    /// truncating ("De…" / "Rece…" at 46 mm). VoiceOver still reads the full title.
    var compact: Bool = false
    /// Tap handler (runs on the main actor).
    let action: () -> Void

    /// Compact: symbol (`.headline` bold) over a `.caption2` semibold title (1 line, scales to
    /// 70 %), 4 pt side padding. Full width: symbol + `WKFont.button` title (1 line, scales to
    /// 80 %) + trailing spacer, 12 pt side padding. Foreground is ivory on `secondary`, ink on
    /// the ivory / danger fills (text on any coloured fill is `WKColor.ink`).
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
