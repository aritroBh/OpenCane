//
//  NavLiveActivity.swift
//  CaneKitWidget
//
//  Lock screen + Dynamic Island + StandBy + watch Smart Stack for OpenCane: the brand mark, the
//  phase (warming countdown, walking, indoor step, listening / thinking, arrived, stopped), the
//  manoeuvre glyph and countdown distance, the obstacle glance and whether obstacle sensing is
//  actually running — for the sighted spotter looking down at the phone clamped to the cane, and
//  for the walker through VoiceOver (one spoken sentence per presentation).
//
//  Step 64 redesign (owner: "the island looks kind of bad… just a location icon thing"). The Step 64
//  audit and the `make island` pictures found:
//    · Nothing said OpenCane: a bare `figure.walk` + metres and a lone green check read as Fitness
//      or a system indicator. Every presentation now carries the contour-ring mark
//      (`OpenCaneMark`, ios/Shared/Brand) and the island keyline is tinted by alert level.
//    · ⚠ SAFETY: the green "Path clear" showed on the lock screen while depth was paused. The
//      glance now draws clear only when `state.sensing.showsClear(isStale:)` (sensing `.live`, not
//      stale); paused says "Obstacles paused — unlock", unknown says "Sensing unknown".
//    · The instruction was cut at 2 lines; now 3 lines at ≥ 85 % scale, with a short manoeuvre
//      caption and "3 of 6" progress beside the bar.
//    · The island vanished on Stop: a "Route stopped" card stays 10 s.
//    · Nothing before the route: the warming phase shows a `Text(timerInterval:)` countdown.
//
//  No interactive buttons on purpose (docs/design.md §6.7): "Next" / "Stop" from the lock screen is
//  too easy to hit accidentally while walking with the phone on the cane shaft. Tapping anywhere
//  opens the app (`widgetURL` opencane://guide). Colours are hard-coded ivory-on-ink so the widget
//  target has no dependency on Theme.swift; every tint comes with a glyph and, off the compact
//  bubble, a word.
//
//  Owner / callers: rendered by the system from `Activity<NavActivityAttributes>`; the app side is
//  `LiveActivityController` (beginWarmup / start / update / setSensors / setVoicePhase / setIndoor /
//  end, coalesced by `LiveActivityCoalescer`). Payload in
//  ios/Shared/LiveActivity/NavActivityAttributes.swift. Module `watch-widget-shared`.
//  Tests: pixels none automated; `make island` photographs compact, expanded, walking and the
//  stopped card, and the CHANGELOG entry lists what they show. The decisions are pinned in
//  CaneKitLogic (`IslandPolicyTests`).
//
//  Key invariants:
//    · Every `kind` string the app sends ("turnLeft", "turnRight", "crossing", "arrived",
//      "straight") has a glyph AND a spoken word in `Manoeuvre` — an unknown kind falls back to
//      straight, never to an empty label.
//    · ⚠ "Path clear" / the green check only when `sensing.showsClear(isStale:)`.
//    · Minimal = the mark, tinted by level. Compact leading = mark + glyph (+ distance / step /
//      countdown); compact trailing = progress ring (check inside only when sensing is live).
//    · VoiceOver reads a natural sentence, never a raw kind or a hex colour.
//

import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Palette and words (widget-local: no Theme.swift, no CaneKitLogic here)

/// Fixed colours for the Live Activity (design.md §6.7: ink ground, ivory text, glance tints).
enum IslandPalette {
    /// Card ground (≈ `#171410`).
    static let ink = Color(red: 0.09, green: 0.08, blue: 0.06)
    /// Text on ink (≈ `#F5F2EB`).
    static let ivory = Color(red: 0.96, green: 0.95, blue: 0.92)
    /// Secondary text on ink.
    static let ivoryDim = Color(red: 0.96, green: 0.95, blue: 0.92).opacity(0.62)
    /// Path clear (only while sensing is live).
    static let clear = Color(red: 0.29, green: 0.87, blue: 0.50)
    /// Obstacle in the torso band.
    static let warning = Color(red: 0.98, green: 0.57, blue: 0.24)
    /// Head height / stop.
    static let head = Color(red: 0.97, green: 0.44, blue: 0.44)
    /// Drop-off / curb.
    static let dropOff = Color(red: 0.75, green: 0.55, blue: 0.98)
    /// Sensing paused (screen locked) — amber, not green, not red.
    static let paused = Color(red: 0.99, green: 0.80, blue: 0.30)
    /// Voice shell (listening / thinking) — the app's calm blue.
    static let voice = Color(red: 0.45, green: 0.70, blue: 1.0)

    /// Tint for an alert level; nil when there is no alert.
    static func tint(_ level: NavIslandAlert) -> Color? {
        switch level {
        case .none: nil
        case .near: warning
        case .curb: dropOff
        case .stop, .head: head
        }
    }
}

/// The manoeuvre a `kind` string names: its SF Symbol, its short word and its spoken phrase.
/// One table so the glyph, the caption and VoiceOver can never disagree.
private struct Manoeuvre {
    /// SF Symbol name.
    let symbol: String
    /// Caption under the glyph ("Turn right").
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
            self = .init(symbol: "arrow.turn.up.left", word: "Turn left", spoken: "turn left", tint: IslandPalette.ivory)
        case "turnRight":
            self = .init(symbol: "arrow.turn.up.right", word: "Turn right", spoken: "turn right", tint: IslandPalette.ivory)
        case "crossing":
            self = .init(symbol: "figure.walk.diamond.fill", word: "Crossing", spoken: "cross the street",
                         tint: Color(red: 0.99, green: 0.88, blue: 0.28))
        case "arrived":
            self = .init(symbol: "flag.checkered", word: "Arrived", spoken: "destination reached", tint: IslandPalette.clear)
        default:
            self = .init(symbol: "figure.walk", word: "Straight on", spoken: "continue straight", tint: IslandPalette.ivory)
        }
    }

    private init(symbol: String, word: String, spoken: String, tint: Color) {
        self.symbol = symbol; self.word = word; self.spoken = spoken; self.tint = tint
    }
}

/// The obstacle / sensing glance: glyph, tint, short word, spoken sentence — derived once per state.
/// ⚠ Safety: an obstacle is shown only while sensing is live; "Path clear" only then too.
private struct Glance {
    let symbol: String
    let tint: Color
    /// Word for the pill ("Path clear", "Obstacle 1.2 m", "Obstacles paused — unlock").
    let word: String
    /// Compact bubble text beside the glyph; empty when the glyph alone is the message.
    let compact: String
    /// VoiceOver clause.
    let spoken: String
    /// True when there is an obstacle to act on (tint wins the keyline).
    let isAlert: Bool
    /// True only for the live, clear case (the green check).
    let isClear: Bool

    init(state: NavActivityAttributes.ContentState, isStale: Bool) {
        let live = state.sensing.showsClear(isStale: isStale)
        isAlert = live && state.obstacleStatus != .clear
        isClear = live && state.obstacleStatus == .clear
        guard live else {
            // Not live: say what the sensing is, never a hazard or a clear path.
            if state.sensing == .paused && !isStale {
                symbol = "pause.circle.fill"; tint = IslandPalette.paused
                word = "Obstacles paused — unlock"; compact = ""
                spoken = "Obstacle warnings are paused until you unlock."
            } else {
                symbol = "questionmark.circle"; tint = IslandPalette.ivoryDim
                word = isStale ? "No update · sensing unknown" : "Sensing unknown"; compact = ""
                spoken = "Obstacle sensing unknown."
            }
            return
        }
        switch state.obstacleStatus {
        case .clear:
            symbol = "checkmark.circle.fill"; tint = IslandPalette.clear
            word = "Path clear"; compact = ""; spoken = "Path is clear."
        case .warning:
            let stop = state.alertLevel == .stop
            symbol = stop ? "hand.raised.fill" : "exclamationmark.circle.fill"
            tint = stop ? IslandPalette.head : IslandPalette.warning
            let d = state.obstacleDistanceM > 0 ? String(format: "%.1f m", state.obstacleDistanceM) : ""
            word = stop ? (d.isEmpty ? "Stop" : "Stop · \(d)") : (d.isEmpty ? "Obstacle ahead" : "Obstacle \(d)")
            compact = stop ? "STOP" : (d.isEmpty ? "!" : d)
            spoken = d.isEmpty ? "Caution: obstacle ahead." : "Caution: obstacle \(d) ahead."
        case .head:
            symbol = "exclamationmark.triangle.fill"; tint = IslandPalette.head
            let h = state.headClearanceM > 0 ? String(format: " %.1f m", state.headClearanceM) : ""
            word = "Head height\(h)"; compact = "HEAD"
            spoken = "Warning: head-height obstacle\(h) ahead."
        case .dropOff:
            symbol = "arrow.down.to.line"; tint = IslandPalette.dropOff
            word = "Drop-off ahead"; compact = "CURB"
            spoken = "Caution: drop-off or curb ahead."
        }
    }
}

/// Per-phase presentation facts shared by every layout.
private struct PhaseLook {
    /// Leading glyph (manoeuvre while walking).
    let symbol: String
    /// Short caption ("Turn right", "Warming up", "Indoors", "Listening").
    let caption: String
    /// Glyph tint.
    let tint: Color

    init(state: NavActivityAttributes.ContentState) {
        let m = Manoeuvre(kind: state.kind)
        switch state.phase {
        case .warming:   self.init("hourglass", "Warming up", IslandPalette.paused)
        case .walking:   self.init(m.symbol, m.word, m.tint)
        case .indoor:    self.init(m.symbol, "Indoors", IslandPalette.ivory)
        case .listening: self.init("waveform", "Listening", IslandPalette.voice)
        case .thinking:  self.init("ellipsis", "Thinking", IslandPalette.voice)
        case .arrived:   self.init("flag.checkered", "Arrived", IslandPalette.clear)
        case .stopped:   self.init("stop.circle", "Stopped", IslandPalette.ivoryDim)
        }
    }

    private init(_ symbol: String, _ caption: String, _ tint: Color) {
        self.symbol = symbol; self.caption = caption; self.tint = tint
    }
}

// MARK: - Widget

/// The navigation Live Activity, driven by `Activity<NavActivityAttributes>` from the app.
struct NavLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NavActivityAttributes.self) { context in
            ActivityRootView(state: context.state, routeName: context.attributes.routeName,
                             isStale: context.isStale)
                .activityBackgroundTint(IslandPalette.ink)
                .foregroundStyle(IslandPalette.ivory)
                .widgetURL(OpenCaneLinks.guide)
        } dynamicIsland: { context in
            let state = context.state
            let isStale = context.isStale
            let look = PhaseLook(state: state)
            let glance = Glance(state: state, isStale: isStale)
            let keyline = Self.keyline(state, glance: glance)
            return DynamicIsland {
                // Leading: the phase / manoeuvre glyph over its caption, with the mark.
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            OpenCaneMark().stroke(keyline, lineWidth: 1.4).frame(width: 22, height: 22)
                            Image(systemName: look.symbol)
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(look.tint)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .frame(height: 24)
                        Text(look.caption)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(IslandPalette.ivoryDim)
                            .lineLimit(1)
                    }
                    .padding(.leading, 2)
                    .accessibilityHidden(true)
                }
                // Trailing: the number that matters for the phase, and what it counts.
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        TrailingFigure(state: state, isStale: isStale)
                            .font(.system(size: 24, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(height: 24)
                        Text(Self.trailingCaption(state, isStale: isStale))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(IslandPalette.ivoryDim)
                            .lineLimit(1)
                    }
                    .padding(.trailing, 2)
                    .accessibilityHidden(true)
                }
                // Bottom: instruction (3 lines at ≥ 85 %), then one row: glance pill · progress bar
                // · "3 of 6" / route name.
                DynamicIslandExpandedRegion(.bottom) {
                    // Step 64 pictures: at .subheadline, 3 lines pushed the pill row below the region's
                    // clip ("Sensing unknown" half cut, "1 of…"). 14 pt and tighter spacing keep all of it.
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.instruction)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(IslandPalette.ivory)
                            .lineLimit(3)
                            .minimumScaleFactor(0.85)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            if Self.showsGlance(state) {
                                GlancePill(glance: glance).layoutPriority(1)
                            }
                            RouteProgressBar(progress: state.progress, tint: glance.isAlert ? glance.tint : IslandPalette.ivory)
                            Text(Self.progressLabel(state) ?? context.attributes.routeName)
                                .font(.caption2.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(IslandPalette.ivoryDim)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .fixedSize(horizontal: Self.progressLabel(state) != nil, vertical: false)
                                .contentTransition(.numericText())
                        }
                    }
                    // Leading 2, trailing 10: the island's bottom corners are round and clipped the last
                    // character of "1 of 9" (second Step 64 pictures).
                    .padding(.leading, 2)
                    .padding(.trailing, 10)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.summary(state, routeName: context.attributes.routeName, isStale: isStale))
                }
            } compactLeading: {
                HStack(spacing: 5) {
                    OpenCaneMark().stroke(keyline, lineWidth: 1.2).frame(width: 17, height: 17)
                    Image(systemName: look.symbol)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(look.tint)
                    CompactFigure(state: state, isStale: isStale)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .padding(.leading, 2)
                .accessibilityLabel(Self.summary(state, routeName: context.attributes.routeName, isStale: isStale))
            } compactTrailing: {
                CompactTrailing(state: state, glance: glance, isStale: isStale)
                    .padding(.trailing, 2)
                    // The leading bubble's sentence already carries the glance clause (Codex, Step 47).
                    .accessibilityHidden(true)
            } minimal: {
                // The brand mark, tinted by what matters (alert > paused > phase).
                OpenCaneMark()
                    .stroke(glance.isAlert ? glance.tint : keyline, lineWidth: 1.5)
                    .frame(width: 18, height: 18)
                    .accessibilityLabel(Self.summary(state, routeName: context.attributes.routeName, isStale: isStale))
            }
            .keylineTint(keyline)
            .widgetURL(OpenCaneLinks.guide)
            .contentMargins(.horizontal, 14, for: .expanded)
        }
        .supplementalActivityFamilies([.small])
    }

    /// Keyline / mark tint: alert colour, else paused amber, else voice blue, else ivory.
    fileprivate static func keyline(_ state: NavActivityAttributes.ContentState, glance: Glance) -> Color {
        if glance.isAlert { return glance.tint }
        switch state.phase {
        case .listening, .thinking: return IslandPalette.voice
        case .arrived: return IslandPalette.clear
        default: break
        }
        if state.sensing == .paused { return IslandPalette.paused }
        return IslandPalette.ivory
    }

    /// The glance pill belongs to guidance phases; the final cards and warm-up have none.
    fileprivate static func showsGlance(_ state: NavActivityAttributes.ContentState) -> Bool {
        switch state.phase {
        case .walking, .indoor, .listening, .thinking: true
        case .warming, .arrived, .stopped: false
        }
    }

    /// "3 of 6" (indoor steps or waypoints), nil when unknown.
    fileprivate static func progressLabel(_ state: NavActivityAttributes.ContentState) -> String? {
        guard state.stepCount > 0 else { return nil }
        let shown = state.phase == .arrived ? state.stepCount : min(state.stepCount, state.stepIndex + 1)
        return state.phase == .indoor ? "Step \(shown) of \(state.stepCount)" : "\(shown) of \(state.stepCount)"
    }

    /// Trailing caption under the big figure.
    fileprivate static func trailingCaption(_ state: NavActivityAttributes.ContentState, isStale: Bool) -> String {
        if isStale { return "No update" }
        switch state.phase {
        case .warming: return "to start"
        case .indoor: return state.stepCount > 0 ? "indoor step" : "indoors"
        case .listening, .thinking: return "OpenCane"
        case .arrived: return "at destination"
        case .stopped: return "route ended"
        case .walking:
            return state.statusDetail.isEmpty ? "to next" : "to next · \(state.statusDetail)"
        }
    }

    /// One spoken sentence per presentation: "OpenCane, on route ISR Townsend Hall to CIF: in 120
    /// meters, turn right. Goodwin Avenue. Path is clear." Phase-specific openers for warming,
    /// indoor, voice and the final cards. Adds "No update for a while." when stale.
    fileprivate static func summary(_ state: NavActivityAttributes.ContentState, routeName: String,
                                    isStale: Bool) -> String {
        let manoeuvre = Manoeuvre(kind: state.kind)
        let glance = Glance(state: state, isStale: isStale)
        let route = routeName.isEmpty ? "" : ", on route \(routeName)"
        let stale = isStale ? " No update for a while." : ""
        switch state.phase {
        case .warming:
            return "OpenCane\(route): obstacle detection warming up. The route starts automatically."
        case .indoor:
            let step = progressLabel(state).map { "\($0). " } ?? ""
            return "OpenCane indoors\(route): \(step)\(state.instruction) \(glance.spoken)\(stale)"
        case .listening:
            return "OpenCane is listening\(route). \(glance.spoken)"
        case .thinking:
            return "OpenCane is thinking\(route). \(glance.spoken)"
        case .arrived:
            return "OpenCane\(route): arrived. \(state.instruction)"
        case .stopped:
            return "OpenCane\(route): route stopped."
        case .walking:
            let dist = state.distanceM > 0 ? "in \(state.distanceM) meters, " : ""
            return "OpenCane\(route): \(dist)\(manoeuvre.spoken). \(state.instruction) \(glance.spoken)\(stale)"
        }
    }
}

/// Deep links the widget opens. The scheme is registered in ios/project.yml (`CFBundleURLTypes`);
/// the app needs no handler — opening the app on the Guide is the whole action.
enum OpenCaneLinks {
    /// The Guide.
    static let guide = URL(string: "opencane://guide")!
    /// Talk to OpenCane (accessory widget).
    static let talk = URL(string: "opencane://talk")!
}

// MARK: - Pieces

/// "N m" below 1000 m, "N.N km" from 1000 m; "—" for 0 (unknown / arrived). Dimmed when stale.
private struct DistanceText: View {
    let metres: Int
    let isStale: Bool

    var body: some View {
        Text(label)
            .foregroundStyle(isStale ? IslandPalette.ivoryDim : IslandPalette.ivory)
            .contentTransition(.numericText(value: Double(metres)))
    }

    private var label: String {
        if metres <= 0 { return "—" }
        return metres >= 1000 ? String(format: "%.1f km", Double(metres) / 1000) : "\(metres) m"
    }
}

/// Countdown to `warmupEndsAt` ("0:04"), or "…" when unknown / past.
private struct WarmupCountdown: View {
    let endsAt: Date?

    var body: some View {
        if let endsAt, endsAt > Date() {
            Text(timerInterval: Date()...endsAt, countsDown: true, showsHours: false)
                .multilineTextAlignment(.trailing)
        } else {
            Text("…")
        }
    }
}

/// The expanded island's big trailing figure per phase.
private struct TrailingFigure: View {
    let state: NavActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        switch state.phase {
        case .warming:
            WarmupCountdown(endsAt: state.warmupEndsAt).foregroundStyle(IslandPalette.paused)
        case .indoor where state.stepCount > 0:
            Text("\(min(state.stepCount, state.stepIndex + 1))/\(state.stepCount)")
                .contentTransition(.numericText(value: Double(state.stepIndex)))
        case .arrived:
            Image(systemName: "checkmark.seal.fill").foregroundStyle(IslandPalette.clear)
        case .stopped:
            // Same 1-based step as `progressLabel` (Muse M8: it showed one less than the step).
            Text(state.stepCount > 0 ? "\(min(state.stepCount, state.stepIndex + 1))/\(state.stepCount)" : "—")
                .foregroundStyle(IslandPalette.ivoryDim)
        default:
            DistanceText(metres: state.distanceM, isStale: isStale)
        }
    }
}

/// The compact leading figure beside the glyph: distance, step, countdown — or nothing.
private struct CompactFigure: View {
    let state: NavActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        switch state.phase {
        case .walking:
            DistanceText(metres: state.distanceM, isStale: isStale)
        case .indoor where state.stepCount > 0:
            Text("\(min(state.stepCount, state.stepIndex + 1))/\(state.stepCount)")
        case .warming:
            WarmupCountdown(endsAt: state.warmupEndsAt)
                .frame(maxWidth: 40)
                .foregroundStyle(IslandPalette.paused)
        default:
            EmptyView()
        }
    }
}

/// Compact trailing bubble: an alert word, a phase word, or the progress ring (check inside only
/// when sensing is live and clear; pause glyph when paused).
private struct CompactTrailing: View {
    let state: NavActivityAttributes.ContentState
    let glance: Glance
    let isStale: Bool

    var body: some View {
        if glance.isAlert {
            HStack(spacing: 3) {
                Image(systemName: glance.symbol).font(.system(size: 13, weight: .bold))
                if !glance.compact.isEmpty {
                    Text(glance.compact)
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .foregroundStyle(glance.tint)
        } else {
            switch state.phase {
            case .listening, .thinking, .arrived, .stopped:
                Text(PhaseLook(state: state).caption)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(PhaseLook(state: state).tint)
                    .lineLimit(1)
            default:
                ProgressRing(progress: state.progress, tint: glance.isClear ? IslandPalette.clear : IslandPalette.ivory) {
                    if glance.isClear {
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .black))
                            .foregroundStyle(IslandPalette.clear)
                    } else if state.sensing == .paused && !isStale {
                        Image(systemName: "pause.fill").font(.system(size: 7, weight: .black))
                            .foregroundStyle(IslandPalette.paused)
                    }
                }
                .frame(width: 20, height: 20)
            }
        }
    }
}

/// A small ring: dim track, tinted arc for `progress`, any content in the middle.
private struct ProgressRing<Inner: View>: View {
    let progress: Double
    let tint: Color
    @ViewBuilder let inner: () -> Inner

    var body: some View {
        ZStack {
            Circle().stroke(IslandPalette.ivory.opacity(0.22), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            inner()
        }
        .accessibilityHidden(true)
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

/// A thin route-progress bar: waypoints passed over total, the walker's dot at the head.
private struct RouteProgressBar: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let w = max(0, min(1, progress)) * geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(IslandPalette.ivory.opacity(0.18))
                if w > 0 { Capsule().fill(tint).frame(width: w) }   // no sliver at 0 % (review)
                Circle().fill(IslandPalette.ivory).frame(width: 8, height: 8)
                    .offset(x: min(max(0, w - 4), geo.size.width - 8))
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)               // the sentence already says the distance
    }
}

// MARK: - Lock screen, StandBy, Smart Stack

/// Chooses the layout: watch Smart Stack (`.small`), StandBy (`isActivityFullscreen`), else the
/// lock-screen card.
private struct ActivityRootView: View {
    let state: NavActivityAttributes.ContentState
    let routeName: String
    let isStale: Bool
    @Environment(\.activityFamily) private var family
    @Environment(\.isActivityFullscreen) private var isFullscreen

    var body: some View {
        Group {
            if family == .small {
                SmallCard(state: state, isStale: isStale)
            } else if isFullscreen {
                StandByCard(state: state, routeName: routeName, isStale: isStale)
            } else {
                LockScreenCard(state: state, routeName: routeName, isStale: isStale)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NavLiveActivity.summary(state, routeName: routeName, isStale: isStale))
    }
}

/// Lock screen / banner:
///   ◎ OpenCane · To CIF                 ● LiDAR live
///   ↱  Turn right onto Goodwin…              42 m
///   [● Path clear]  ▬▬▬▬○──────        3 of 6
private struct LockScreenCard: View {
    let state: NavActivityAttributes.ContentState
    let routeName: String
    let isStale: Bool

    var body: some View {
        let look = PhaseLook(state: state)
        let glance = Glance(state: state, isStale: isStale)
        let keyline = NavLiveActivity.keyline(state, glance: glance)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                OpenCaneMark().stroke(keyline, lineWidth: 1.3).frame(width: 18, height: 18)
                Text(routeName.isEmpty ? "OpenCane" : "OpenCane · \(routeName)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(IslandPalette.ivoryDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                SensingBadge(state: state, isStale: isStale)
            }
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: look.symbol)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(look.tint)
                    .frame(width: 36)
                Text(state.instruction)
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 0) {
                    TrailingFigure(state: state, isStale: isStale)
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(NavLiveActivity.trailingCaption(state, isStale: isStale))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(IslandPalette.ivoryDim)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                if NavLiveActivity.showsGlance(state) { GlancePill(glance: glance).layoutPriority(1) }
                RouteProgressBar(progress: state.progress, tint: glance.isAlert ? glance.tint : IslandPalette.ivory)
                if let p = NavLiveActivity.progressLabel(state) {
                    Text(p).font(.caption2.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(IslandPalette.ivoryDim).lineLimit(1)
                }
            }
        }
        .padding(14)
    }
}

/// "● LiDAR live" / "Ⅱ Paused" / "? Unknown" — the sensing fact in words.
private struct SensingBadge: View {
    let state: NavActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let (dot, word): (Color, String) = {
            if isStale { return (IslandPalette.ivoryDim, "No update") }
            switch state.sensing {
            case .live: return (IslandPalette.clear, "LiDAR live")
            case .paused: return (IslandPalette.paused, "Sensing paused")
            case .none: return (IslandPalette.ivoryDim, state.phase == .warming ? "Warming up" : "Sensing unknown")
            }
        }()
        HStack(spacing: 4) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(word).font(.caption2.weight(.bold)).foregroundStyle(dot).lineLimit(1)
        }
    }
}

/// StandBy (phone on its side, charging): a giant glyph and figure, a level colour band.
private struct StandByCard: View {
    let state: NavActivityAttributes.ContentState
    let routeName: String
    let isStale: Bool

    var body: some View {
        let look = PhaseLook(state: state)
        let glance = Glance(state: state, isStale: isStale)
        let band = glance.isAlert ? glance.tint : NavLiveActivity.keyline(state, glance: glance)
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                Image(systemName: look.symbol)
                    .font(.system(size: 64, weight: .bold))
                    .foregroundStyle(look.tint)
                VStack(alignment: .leading, spacing: 4) {
                    TrailingFigure(state: state, isStale: isStale)
                        .font(.system(size: 56, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(glance.word)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(glance.tint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                OpenCaneMark().stroke(band, lineWidth: 2).frame(width: 44, height: 44)
            }
            .padding(20)
            Rectangle().fill(band).frame(height: 8)
        }
    }
}

/// Watch Smart Stack / CarPlay (`.small`): mark + glyph + figure over the sensing word.
private struct SmallCard: View {
    let state: NavActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let look = PhaseLook(state: state)
        let glance = Glance(state: state, isStale: isStale)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                OpenCaneMark().stroke(NavLiveActivity.keyline(state, glance: glance), lineWidth: 1.2)
                    .frame(width: 16, height: 16)
                Image(systemName: look.symbol).font(.system(size: 18, weight: .bold)).foregroundStyle(look.tint)
                TrailingFigure(state: state, isStale: isStale)
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Text(glance.word)
                .font(.caption2.weight(.bold))
                .foregroundStyle(glance.tint)
                .lineLimit(1)
        }
        .padding(10)
    }
}
