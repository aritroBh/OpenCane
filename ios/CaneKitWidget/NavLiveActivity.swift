//
//  NavLiveActivity.swift
//  CaneKitWidget
//
//  Lock screen + Dynamic Island for the current route: a turn glyph, the instruction, and the
//  distance. No buttons on purpose (docs/design.md §6.7): "Next" from the lock screen is too easy
//  to hit by accident with the phone on a cane, which is glanced at, not touched. Colours are
//  hard-coded ivory-on-ink so the widget has no dependency on Theme.swift (not in this target).
//
//  Why it exists: the sighted teammate walking behind reads the next instruction and distance
//  over the walker's shoulder without unlocking the phone.
//
//  Implements docs/design.md §6.7 (Live Activity / Dynamic Island): compact = glyph + distance,
//  minimal = glyph only, expanded = glyph / distance / instruction. Deviations from §6.7 (listed
//  there as "Not built"): no TRUSTED pill or ETA / steps line, and VoiceOver reads the glyph by
//  its raw kind (design.md §10). Update-rate coalescing (≥ 10 m or an instruction / kind change)
//  and the 60 s dismissal after arrival are the phone's job (`LiveActivityController`), not this
//  file's.
//
//  Owner / callers: WidgetKit, via `CaneKitWidgetBundle`. Isolation: MainActor (target default).
//  Tests: none automated; CHANGELOG "Steps 8–9" and Step 20 ("lock phone to check single Live
//  Activity on Lock Screen") device tests.
//
//  Accessibility contract: the glyph's VoiceOver label is the raw `kind` string ("turnLeft",
//  "turnRight", "crossing", "arrived", "straight"); instruction and distance are plain texts.
//  No XCUITest reaches the widget. Any new `kind` must also get a case in `glyph(_:)`.
//

import ActivityKit
import SwiftUI
import WidgetKit

/// The navigation Live Activity, driven by `Activity<NavActivityAttributes>` from the app.
///
/// Renders `NavActivityAttributes.ContentState` (instruction, distance in metres, glyph kind)
/// plus the static `routeName`. Tapping opens the app (system default); there are no buttons.
struct NavLiveActivity: Widget {
    /// The lock-screen / banner layout (glyph · instruction over route name · distance, ink tint)
    /// and the Dynamic Island regions. Distance is always `.monospacedDigit()` so "120 m" →
    /// "119 m" does not jitter (design.md §1).
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NavActivityAttributes.self) { context in
            // Lock screen / banner.
            HStack(spacing: 12) {
                glyph(context.state.kind)
                    .font(.title.weight(.bold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.instruction)
                        .font(.headline)
                        .lineLimit(2)
                    Text(context.attributes.routeName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                distance(context.state.distanceM)
                    .font(.system(.title, design: .rounded).weight(.heavy))
                    .monospacedDigit()
            }
            .padding(14)
            // Ink ground (#17140F-ish) with cane-ivory text (#F4F1EA-ish), matching the phone's dark palette.
            .activityBackgroundTint(Color(red: 0.09, green: 0.08, blue: 0.06))
            .foregroundStyle(Color(red: 0.96, green: 0.95, blue: 0.92))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    glyph(context.state.kind).font(.title2.weight(.bold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    distance(context.state.distanceM)
                        .font(.system(.title2, design: .rounded).weight(.heavy))
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.instruction).font(.subheadline).lineLimit(2)
                }
            } compactLeading: {
                glyph(context.state.kind)
            } compactTrailing: {
                distance(context.state.distanceM).monospacedDigit()
            } minimal: {
                // Glyph only: the distance is too small to read and changes too fast (§6.7).
                glyph(context.state.kind)
            }
        }
    }

    /// SF Symbol for the upcoming manoeuvre: turnLeft / turnRight arrows, a walking figure for a
    /// crossing, a chequered flag on arrival, and a straight-up arrow for anything else
    /// ("straight" or an unknown kind).
    ///
    /// The kind is the last wrist cue the phone sent (`AppModel.lastNavKind`), so a "Veer left."
    /// leaves the turn-left arrow up until the next cue; "straight" only at route start, and
    /// `LiveActivityController.end` forces "arrived" (also for a stopped route).
    ///
    /// Accessibility: labelled with the raw `kind` string (not a spoken phrase).
    /// - Parameter kind: `NavActivityAttributes.ContentState.kind`.
    private func glyph(_ kind: String) -> some View {
        let name: String
        switch kind {
        case "turnLeft": name = "arrow.turn.up.left"
        case "turnRight": name = "arrow.turn.up.right"
        case "crossing": name = "figure.walk"
        case "arrived": name = "flag.checkered"
        default: name = "arrow.up"
        }
        return Image(systemName: name).accessibilityLabel(kind)
    }

    /// Distance text: "N m" below 1000 m, "%.1f km" from 1000 m up (callers add tabular digits).
    /// Note the phone sends 0 for "unknown", so a missing fix reads "0 m" here (the watch, which
    /// gets -1, shows its title instead). `String(format:)` uses the POSIX "." decimal separator
    /// regardless of locale.
    /// - Parameter m: whole metres to the next waypoint.
    private func distance(_ m: Int) -> Text {
        m >= 1000 ? Text(String(format: "%.1f km", Double(m) / 1000)) : Text("\(m) m")
    }
}
