//
//  NavLiveActivity.swift
//  CaneKitWidget
//
//  Lock screen + Dynamic Island for the current route: turn glyph, countdown distance,
//  and real-time obstacle clearance radar for both the blind walker (VoiceOver) and the
//  sighted spotter glancing down at the phone clamped to the cane.
//
//  No interactive buttons on purpose (docs/design.md §6.7): "Next" from the lock screen is
//  too easy to hit accidentally while walking with the phone on the cane shaft.
//  Colours are hard-coded ivory-on-ink so the widget target has no dependency on Theme.swift.
//
//  Key invariants:
//    · Compact leading = turn glyph + distance.
//    · Compact trailing = real-time obstacle glance badge (CLEAR / CAUTION / HEAD / CURB).
//    · Minimal = turn glyph (or hazard alert if non-clear).
//    · Expanded = turn glyph + instruction + countdown distance + 3-lane obstacle radar pill.
//    · Lock screen = turn glyph · instruction over route name · obstacle clearance pill · distance.
//    · VoiceOver accessibility reads natural sentence combining navigation and obstacle status.
//

import ActivityKit
import SwiftUI
import WidgetKit

/// The navigation Live Activity, driven by `Activity<NavActivityAttributes>` from the app.
struct NavLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NavActivityAttributes.self) { context in
            // Lock screen / banner presentation
            HStack(spacing: 12) {
                glyph(context.state.kind)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(glyphTint(context.state.kind))

                VStack(alignment: .leading, spacing: 3) {
                    Text(context.state.instruction)
                        .font(.headline)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        Text(context.attributes.routeName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        obstaclePill(
                            status: context.state.obstacleStatus,
                            distanceM: context.state.obstacleDistanceM,
                            headM: context.state.headClearanceM
                        )
                        .layoutPriority(1)
                    }
                }

                Spacer(minLength: 8)

                distance(context.state.distanceM)
                    .font(.system(.title, design: .rounded).weight(.heavy))
                    .monospacedDigit()
            }
            .padding(14)
            .activityBackgroundTint(Color(red: 0.09, green: 0.08, blue: 0.06))
            .foregroundStyle(Color(red: 0.96, green: 0.95, blue: 0.92))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySummary(context.state, routeName: context.attributes.routeName))

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        glyph(context.state.kind)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(glyphTint(context.state.kind))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.attributes.routeName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(context.state.instruction)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                        }
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        distance(context.state.distanceM)
                            .font(.system(.title3, design: .rounded).weight(.heavy))
                            .monospacedDigit()
                        if !context.state.statusDetail.isEmpty {
                            Text(context.state.statusDetail)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        obstaclePill(
                            status: context.state.obstacleStatus,
                            distanceM: context.state.obstacleDistanceM,
                            headM: context.state.headClearanceM
                        )
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    glyph(context.state.kind)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(glyphTint(context.state.kind))
                    distance(context.state.distanceM)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
            } compactTrailing: {
                compactObstacleGlance(
                    status: context.state.obstacleStatus,
                    distanceM: context.state.obstacleDistanceM
                )
            } minimal: {
                if context.state.obstacleStatus != .clear {
                    Image(systemName: context.state.obstacleStatus == .head ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(context.state.obstacleStatus == .head ? Color.red : Color.orange)
                } else {
                    glyph(context.state.kind)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(glyphTint(context.state.kind))
                }
            }
        }
    }

    // MARK: Helpers

    /// SF Symbol for upcoming manoeuvre: turn arrows, crossing pedestrian, chequered flag, or straight arrow.
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

    /// Tint color for turn glyphs to ensure immediate visual recognition.
    private func glyphTint(_ kind: String) -> Color {
        switch kind {
        case "arrived": return Color.green
        case "crossing": return Color.yellow
        default: return Color(red: 0.96, green: 0.95, blue: 0.92)
        }
    }

    /// Distance text: "N m" below 1000m, "%.1f km" from 1000m up.
    private func distance(_ m: Int) -> Text {
        m >= 1000 ? Text(String(format: "%.1f km", Double(m) / 1000)) : Text("\(m) m")
    }

    /// Compact obstacle clearance glance for the trailing bubble of the Dynamic Island.
    @ViewBuilder
    private func compactObstacleGlance(status: LiveActivityObstacleGlance, distanceM: Double) -> some View {
        switch status {
        case .head:
            HStack(spacing: 2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.red)
                Text("HEAD")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.red)
            }
        case .warning:
            HStack(spacing: 2) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color.orange)
                if distanceM > 0 {
                    Text(String(format: "%.1fm", distanceM))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.orange)
                } else {
                    Text("ALERT")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.orange)
                }
            }
        case .dropOff:
            HStack(spacing: 2) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .foregroundStyle(Color.purple)
                Text("CURB")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.purple)
            }
        case .clear:
            HStack(spacing: 2) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                Text("CLEAR")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.green)
            }
        }
    }

    /// High-contrast obstacle clearance badge pill for expanded and lock-screen presentations.
    @ViewBuilder
    private func obstaclePill(status: LiveActivityObstacleGlance, distanceM: Double, headM: Double) -> some View {
        let (icon, text, tint): (String, String, Color) = {
            switch status {
            case .head:
                let hStr = headM > 0 ? String(format: " %.1fm", headM) : ""
                return ("exclamationmark.triangle.fill", "Head hazard\(hStr)", Color.red)
            case .warning:
                let dStr = distanceM > 0 ? String(format: " %.1fm", distanceM) : ""
                return ("exclamationmark.circle.fill", "Obstacle ahead\(dStr)", Color.orange)
            case .dropOff:
                return ("arrow.down.right.and.arrow.up.left", "Drop-off / Curb", Color.purple)
            case .clear:
                return ("checkmark.circle.fill", "Path clear", Color.green)
            }
        }()

        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
            Text(text)
                .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.2))
        .foregroundStyle(tint)
        .clipShape(Capsule())
    }

    /// Descriptive VoiceOver sentence announced when a blind user touches the Dynamic Island or Lock Screen banner.
    private func accessibilitySummary(_ state: NavActivityAttributes.ContentState, routeName: String) -> String {
        let dist = state.distanceM > 0 ? "In \(state.distanceM) meters, " : ""
        let turnPhrase: String = {
            switch state.kind {
            case "turnLeft": return "turn left"
            case "turnRight": return "turn right"
            case "crossing": return "cross street"
            case "arrived": return "destination reached"
            default: return "continue straight"
            }
        }()
        let obs: String
        switch state.obstacleStatus {
        case .head: obs = "Warning: head-height obstacle ahead."
        case .warning: obs = "Caution: obstacle detected ahead."
        case .dropOff: obs = "Caution: drop-off or curb ahead."
        case .clear: obs = "Path is clear."
        }
        let routeClause = routeName.isEmpty ? "" : " on route \(routeName)"
        return "OpenCane\(routeClause): \(dist)\(turnPhrase), \(state.instruction). \(obs)"
    }
}
