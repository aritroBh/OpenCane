//
//  NavLiveActivity.swift
//  CaneKitWidget
//
//  Lock screen + Dynamic Island for the current route: manoeuvre glyph, countdown distance, and
//  the obstacle glance — for the sighted spotter looking down at the phone clamped to the cane,
//  and for the walker through VoiceOver (one spoken sentence per presentation).
//
//  Redesigned in Step 47 from the first simulator pictures of the island (`make island`,
//  CaneKitIslandTour). What was wrong, and what this file does instead:
//    · The "straight" glyph was `arrow.up`, which beside the system's blue location arrow (the
//      background-location pill iOS adds during every route, see docs/design.md §6.7) read as the
//      same icon twice. Manoeuvres now use walking / turning figures, never a bare arrow.
//    · The compact trailing bubble carried an icon AND the word "CLEAR" in green; the island was
//      as wide as the status bar and shouted a non-event. Clear is now one small check glyph;
//      words and numbers appear only when there is something to act on (obstacle distance, HEAD,
//      CURB).
//    · Expanded: the instruction was squeezed into the leading column beside the glyph and
//      truncated ("Leaving Townsend…") while the bottom region held one small pill and empty
//      space. The instruction now owns the full-width bottom region (2 lines, never truncated to
//      one word), the leading column is the glyph + manoeuvre word, the trailing column the
//      distance.
//    · A stale activity (app killed mid-route, no update for `staleAfter`) dims the distance and
//      says "No update" instead of showing a live-looking number.
//
//  No interactive buttons on purpose (docs/design.md §6.7): "Next" from the lock screen is too
//  easy to hit accidentally while walking with the phone on the cane shaft. Colours are hard-coded
//  ivory-on-ink so the widget target has no dependency on Theme.swift; the glance tints (green /
//  orange / red / purple) always come with a glyph and, off the compact bubble, a word.
//
//  Owner / callers: rendered by the system from `Activity<NavActivityAttributes>`; the app side is
//  `LiveActivityController` (start / update / end, coalesced by `LiveActivityCoalescer`). Payload
//  in ios/Shared/LiveActivity/NavActivityAttributes.swift. Module `watch-widget-shared`.
//  Tests: none automated for the pixels; `make island` photographs every presentation (compact,
//  expanded, walking, after Stop) and the CHANGELOG entry links the pictures.
//
//  Key invariants:
//    · Every `kind` string the app sends ("turnLeft", "turnRight", "crossing", "arrived",
//      "straight") has a glyph AND a spoken word in `Manoeuvre` — an unknown kind falls back to
//      straight, never to an empty label.
//    · Compact leading = glyph + distance. Compact trailing = glance glyph (+ metres when not
//      clear). Minimal = glance glyph when not clear, else the manoeuvre glyph.
//    · VoiceOver reads a natural sentence, never a raw kind or a hex colour.
//

import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Palette and words (widget-local: no Theme.swift, no CaneKitLogic here)

/// Fixed colours for the Live Activity (design.md §6.7: ink ground, ivory text, glance tints).
private enum Palette {
    /// Card ground (≈ `#171410`).
    static let ink = Color(red: 0.09, green: 0.08, blue: 0.06)
    /// Text on ink (≈ `#F5F2EB`).
    static let ivory = Color(red: 0.96, green: 0.95, blue: 0.92)
    /// Secondary text on ink.
    static let ivoryDim = Color(red: 0.96, green: 0.95, blue: 0.92).opacity(0.62)
    /// Path clear.
    static let clear = Color(red: 0.29, green: 0.87, blue: 0.50)
    /// Obstacle in the torso band.
    static let warning = Color(red: 0.98, green: 0.57, blue: 0.24)
    /// Head height.
    static let head = Color(red: 0.97, green: 0.44, blue: 0.44)
    /// Drop-off / curb.
    static let dropOff = Color(red: 0.75, green: 0.55, blue: 0.98)
}

/// The manoeuvre a `kind` string names: its SF Symbol, its short word and its spoken phrase.
/// One table so the glyph, the caption and VoiceOver can never disagree.
private struct Manoeuvre {
    /// SF Symbol name.
    let symbol: String
    /// Caption under the glyph in the expanded island ("Turn right").
    let word: String
    /// VoiceOver phrase ("turn right").
    let spoken: String
    /// Tint for the glyph; ivory unless the manoeuvre itself means stop / look.
    let tint: Color

    /// Maps the app's `kind` strings. Unknown → straight (a route always has a direction).
    /// ⚠ Add a case here whenever `AppModel.lastNavKind` gains a value.
    init(kind: String) {
        switch kind {
        case "turnLeft":
            self = .init(symbol: "arrow.turn.up.left", word: "Turn left", spoken: "turn left", tint: Palette.ivory)
        case "turnRight":
            self = .init(symbol: "arrow.turn.up.right", word: "Turn right", spoken: "turn right", tint: Palette.ivory)
        case "crossing":
            self = .init(symbol: "figure.walk.diamond.fill", word: "Crossing", spoken: "cross the street",
                         tint: Color(red: 0.99, green: 0.88, blue: 0.28))
        case "arrived":
            self = .init(symbol: "flag.checkered", word: "Arrived", spoken: "destination reached", tint: Palette.clear)
        default:
            self = .init(symbol: "figure.walk", word: "Straight on", spoken: "continue straight", tint: Palette.ivory)
        }
    }

    private init(symbol: String, word: String, spoken: String, tint: Color) {
        self.symbol = symbol; self.word = word; self.spoken = spoken; self.tint = tint
    }
}

/// The obstacle glance: glyph, tint, short word, spoken sentence — derived once per state.
private struct Glance {
    let symbol: String
    let tint: Color
    /// Word for the pill ("Path clear", "Obstacle 1.2 m", "Head height", "Drop-off").
    let word: String
    /// Compact bubble text beside the glyph; empty when clear (the glyph alone is the message).
    let compact: String
    /// VoiceOver clause.
    let spoken: String

    init(status: LiveActivityObstacleGlance, distanceM: Double, headM: Double) {
        switch status {
        case .clear:
            symbol = "checkmark.circle.fill"; tint = Palette.clear
            word = "Path clear"; compact = ""; spoken = "Path is clear."
        case .warning:
            symbol = "exclamationmark.circle.fill"; tint = Palette.warning
            let d = distanceM > 0 ? String(format: "%.1f m", distanceM) : ""
            word = d.isEmpty ? "Obstacle ahead" : "Obstacle \(d)"
            compact = d.isEmpty ? "!" : d
            spoken = d.isEmpty ? "Caution: obstacle ahead." : "Caution: obstacle \(d) ahead."
        case .head:
            symbol = "exclamationmark.triangle.fill"; tint = Palette.head
            let h = headM > 0 ? String(format: " %.1f m", headM) : ""
            word = "Head height\(h)"; compact = "HEAD"
            spoken = "Warning: head-height obstacle\(h) ahead."
        case .dropOff:
            symbol = "arrow.down.to.line"; tint = Palette.dropOff
            word = "Drop-off ahead"; compact = "CURB"
            spoken = "Caution: drop-off or curb ahead."
        }
    }
}

// MARK: - Widget

/// The navigation Live Activity, driven by `Activity<NavActivityAttributes>` from the app.
struct NavLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NavActivityAttributes.self) { context in
            LockScreenCard(state: context.state, routeName: context.attributes.routeName,
                           isStale: context.isStale)
                .activityBackgroundTint(Palette.ink)
                .foregroundStyle(Palette.ivory)
        } dynamicIsland: { context in
            let state = context.state
            let manoeuvre = Manoeuvre(kind: state.kind)
            let glance = Glance(status: state.obstacleStatus, distanceM: state.obstacleDistanceM,
                                headM: state.headClearanceM)
            return DynamicIsland {
                // Leading column: the manoeuvre, big, with its word under it.
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Image(systemName: manoeuvre.symbol)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(manoeuvre.tint)
                            .frame(height: 34)
                        Text(manoeuvre.word)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Palette.ivoryDim)
                            .lineLimit(1)
                    }
                    .padding(.leading, 4)
                    .accessibilityHidden(true)
                }
                // Trailing column: the distance, and what it is a distance to.
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        DistanceText(metres: state.distanceM, isStale: context.isStale)
                            .font(.system(size: 30, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        // "to next · ±5m GPS": the GPS fact lives here, not in a third pill row —
                        // the expanded bottom region has no height to spare (island pictures).
                        Text(Self.trailingCaption(state, isStale: context.isStale))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Palette.ivoryDim)
                            .lineLimit(1)
                    }
                    .padding(.trailing, 4)
                    .accessibilityHidden(true)
                }
                // Bottom: the instruction, full width (2 lines — a third line pushed the pills and
                // the progress bar out of the expanded region, second island pictures), the glance pill with first claim on the width (the phone
                // showed "Head heig…" beside a truncated route name — the route name left the
                // island; the lock screen keeps it), the GPS fact, then the route progress bar
                // (the Google Maps reference the owner sent).
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(state.instruction)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Palette.ivory)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        // One row: the glance pill, then the route progress bar filling the rest
                        // (a bar on its own row fell below the region's clip line).
                        HStack(spacing: 10) {
                            GlancePill(glance: glance)
                                .layoutPriority(1)
                            RouteProgressBar(progress: state.progress, tint: manoeuvre.tint)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.summary(state, routeName: context.attributes.routeName,
                                                     isStale: context.isStale))
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: manoeuvre.symbol)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(manoeuvre.tint)
                    DistanceText(metres: state.distanceM, isStale: context.isStale)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                .padding(.leading, 2)
                .accessibilityLabel(Self.summary(state, routeName: context.attributes.routeName,
                                                 isStale: context.isStale))
            } compactTrailing: {
                HStack(spacing: 3) {
                    Image(systemName: glance.symbol)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(glance.tint)
                    if !glance.compact.isEmpty {
                        Text(glance.compact)
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(glance.tint)
                            .lineLimit(1)
                    }
                }
                .padding(.trailing, 2)
                // The leading bubble's sentence already ends with the glance clause; a second
                // label here would announce the hazard twice (Codex review, Step 47).
                .accessibilityHidden(true)
            } minimal: {
                // One glyph: the hazard when there is one, else where the route goes.
                if state.obstacleStatus != .clear {
                    Image(systemName: glance.symbol)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(glance.tint)
                        .accessibilityLabel(glance.spoken)
                } else {
                    Image(systemName: manoeuvre.symbol)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(manoeuvre.tint)
                        .accessibilityLabel(manoeuvre.spoken)
                }
            }
        }
    }

    /// Trailing caption under the distance: "to next" / "at destination" / "No update", plus the
    /// GPS fact ("· ±5m GPS") when the app sent one.
    fileprivate static func trailingCaption(_ state: NavActivityAttributes.ContentState, isStale: Bool) -> String {
        let base = isStale ? "No update" : (state.kind == "arrived" ? "at destination" : "to next")
        return state.statusDetail.isEmpty ? base : "\(base) · \(state.statusDetail)"
    }

    /// One spoken sentence per presentation: "OpenCane, on route ISR Townsend Hall to CIF: in 120
    /// meters, turn right. Goodwin Avenue. Path is clear." Adds "No update for a while." when stale.
    fileprivate static func summary(_ state: NavActivityAttributes.ContentState, routeName: String,
                                    isStale: Bool) -> String {
        let manoeuvre = Manoeuvre(kind: state.kind)
        let glance = Glance(status: state.obstacleStatus, distanceM: state.obstacleDistanceM,
                            headM: state.headClearanceM)
        let route = routeName.isEmpty ? "" : ", on route \(routeName)"
        let dist = state.distanceM > 0 && state.kind != "arrived" ? "in \(state.distanceM) meters, " : ""
        let stale = isStale ? " No update for a while." : ""
        return "OpenCane\(route): \(dist)\(manoeuvre.spoken). \(state.instruction) \(glance.spoken)\(stale)"
    }
}

// MARK: - Pieces

/// "N m" below 1000 m, "N.N km" from 1000 m; "—" for 0 (unknown / arrived). Dimmed when stale.
private struct DistanceText: View {
    let metres: Int
    let isStale: Bool

    var body: some View {
        Text(label)
            .foregroundStyle(isStale ? Palette.ivoryDim : Palette.ivory)
    }

    private var label: String {
        if metres <= 0 { return "—" }
        return metres >= 1000 ? String(format: "%.1f km", Double(metres) / 1000) : "\(metres) m"
    }
}

/// The glance as a pill: glyph + word on a tinted ground. Words always; colour is a companion.
private struct GlancePill: View {
    let glance: Glance

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: glance.symbol)
                .font(.system(size: 11, weight: .bold))
            Text(glance.word)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(glance.tint.opacity(0.22), in: Capsule())
        .foregroundStyle(glance.tint)
        .accessibilityLabel(glance.spoken)
    }
}

/// A small neutral fact ("±5m GPS") in the same pill shape as the glance.
private struct FactPill: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Palette.ivory.opacity(0.12), in: Capsule())
        .foregroundStyle(Palette.ivoryDim)
        .lineLimit(1)
    }
}

/// A thin route-progress bar: waypoints passed over total, the walker's dot at the head. Ivory
/// on a dim ivory track; the tint follows the manoeuvre so an arrived route reads green.
private struct RouteProgressBar: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let w = max(0, min(1, progress)) * geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.ivory.opacity(0.18))
                if w > 0 { Capsule().fill(tint).frame(width: w) }   // no sliver at 0 % (review)
                Circle().fill(Palette.ivory).frame(width: 8, height: 8)
                    .offset(x: min(max(0, w - 4), geo.size.width - 8))
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)               // the sentence already says the distance
    }
}

/// Lock screen / banner: glyph · instruction over route name · glance pill · distance · progress.
private struct LockScreenCard: View {
    let state: NavActivityAttributes.ContentState
    let routeName: String
    let isStale: Bool

    var body: some View {
        let manoeuvre = Manoeuvre(kind: state.kind)
        let glance = Glance(status: state.obstacleStatus, distanceM: state.obstacleDistanceM,
                            headM: state.headClearanceM)
        HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 2) {
                Image(systemName: manoeuvre.symbol)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(manoeuvre.tint)
                    .frame(width: 40, height: 34)
                Text(manoeuvre.word)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Palette.ivoryDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(state.instruction)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    GlancePill(glance: glance)
                        .layoutPriority(1)
                    Text(routeName)
                        .font(.caption)
                        .foregroundStyle(Palette.ivoryDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                RouteProgressBar(progress: state.progress, tint: manoeuvre.tint)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 0) {
                DistanceText(metres: state.distanceM, isStale: isStale)
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(isStale ? "No update" : (state.kind == "arrived" ? "arrived" : "to next"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Palette.ivoryDim)
            }
        }
        .padding(14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NavLiveActivity.summary(state, routeName: routeName, isStale: isStale))
    }
}
