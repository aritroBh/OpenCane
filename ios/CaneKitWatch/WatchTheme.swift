//
//  WatchTheme.swift
//  CaneKit Watch
//
//  Watch subset of the design system (docs/design.md §6.6). The watch is always dark: OLED,
//  wrist-down, black ground. No lane ladder here; the watch never shows the depth grid.
//  Text on any coloured fill is `WKColor.ink`, same rule as the phone.
//

import SwiftUI

enum WKColor {
    static let background = Color.black
    static let surface    = rgb(0x26231F)   // secondary button fill
    static let text       = rgb(0xF4F1EA)   // cane ivory
    static let secondary  = rgb(0xB5AFA3)
    /// Primary button fill: cane ivory. Ink text on top.
    static let accent     = rgb(0xF4F1EA)
    static let ink        = rgb(0x17140F)
    static let trusted    = rgb(0x4ADE80)
    static let warning    = rgb(0xFBBF24)
    static let danger     = rgb(0xF87171)

    nonisolated private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}

enum WKFont {
    /// Instruction: 3 lines max, scale to 0.7, never truncate.
    static let instruction = Font.system(.title3, design: .default).weight(.semibold)
    /// Distance: rounded, heavy, tabular so "120 m" → "119 m" doesn't jitter.
    static let distance    = Font.system(.title, design: .rounded).weight(.heavy).monospacedDigit()
    static let button      = Font.system(.headline, design: .rounded).weight(.semibold)
    static let pill        = Font.system(.caption, design: .rounded).weight(.bold)
    static let footnote    = Font.footnote
}

enum WKSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    /// HIG minimum is 44; we use 48 so three buttons plus a footer fit a 45 mm screen.
    static let touchTarget: CGFloat = 48
}

/// Full-width watch button: word + symbol, ≥ 48 pt tall, VoiceOver hint required in production.
struct WKBigButton: View {
    enum Role { case primary, secondary, destructive }

    let title: String
    let systemImage: String
    var role: Role = .primary
    var hint: String? = nil
    var value: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: WKSpacing.sm) {
                Image(systemName: systemImage).font(.headline.weight(.bold)).accessibilityHidden(true)
                Text(title).font(WKFont.button).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, WKSpacing.md)
            .frame(maxWidth: .infinity, minHeight: WKSpacing.touchTarget)
            .foregroundStyle(role == .secondary ? WKColor.text : WKColor.ink)
            .background(fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(hint ?? "")
        .accessibilityValue(value ?? "")
    }

    private var fill: Color {
        switch role {
        case .primary: WKColor.accent
        case .secondary: WKColor.surface
        case .destructive: WKColor.danger
        }
    }
}
