//
//  NavLiveActivity.swift
//  CaneKitWidget
//
//  Lock screen + Dynamic Island for the current route: a turn glyph, the instruction, and the
//  distance. No buttons on purpose (docs/design.md): the phone on the cane is glanced at, not
//  touched. Colours are hard-coded ivory-on-ink so the widget has no dependency on Theme.swift.
//

import ActivityKit
import SwiftUI
import WidgetKit

struct NavLiveActivity: Widget {
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
                glyph(context.state.kind)
            }
        }
    }

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

    private func distance(_ m: Int) -> Text {
        m >= 1000 ? Text(String(format: "%.1f km", Double(m) / 1000)) : Text("\(m) m")
    }
}
