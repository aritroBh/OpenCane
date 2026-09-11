//
//  HazardsCard.swift
//  CaneKit
//
//  "Hazards" card: the camera's second job made visible. Toggles for the three hazard sources
//  (LiDAR drop-offs / potholes / curbs, sign reading, hazard watch), the last thing each one said,
//  which backend the hazard watch uses, the hazard-map count with a share button, and an optional
//  live camera view for the sighted spotter and the demo video: `LiveCameraView`, ARKit's own
//  frames on the GPU at the camera's frame rate (it replaced a ~3 Hz JPEG refresh loop).
//
//  Implements docs/design.md (cards, pills, toggles, big buttons). Accessibility: every toggle is
//  a labelled switch ("Detect drop-offs", "Read signs", "Hazard watch", "Live camera view");
//  the live view is hidden from VoiceOver (it carries no information a blind user needs).
//

import CaneKitLogic
import SwiftUI

struct HazardsCard: View {
    @Environment(AppModel.self) private var model
    /// Backgrounded or locked: ARKit is paused, so the preview must not show a frozen frame.
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        CKCard(title: "Hazards") {
            Toggle("Detect drop-offs", isOn: $model.groundHazardsEnabled)
                .font(CKFont.body).foregroundStyle(CKColor.textPrimary)
                .accessibilityHint("LiDAR warns about curbs, holes and drop-offs 1.5 to 3.5 meters ahead")
            Toggle("Read signs", isOn: $model.signsEnabled)
                .font(CKFont.body).foregroundStyle(CKColor.textPrimary)
                .accessibilityHint("Reads signs like sidewalk closed or detour, on the phone, offline")
            Toggle("Hazard watch", isOn: $model.hazardWatchEnabled)
                .font(CKFont.body).foregroundStyle(CKColor.textPrimary)
                .accessibilityHint("While walking a route, checks the path for cones, barriers and scooters every 8 seconds")

            HStack(spacing: CKSpacing.sm) {
                CKStatusPill(text: model.hazards.watchProvider, tone: .neutral, systemImage: "eye",
                             spoken: "Hazard watch uses \(model.hazards.watchProvider)")
                CKStatusPill(text: "\(model.hazardLog.records.count) mapped", tone: .neutral,
                             systemImage: "mappin.and.ellipse",
                             spoken: "\(model.hazardLog.records.count) hazards on the map")
                Spacer(minLength: 0)
            }
            if let g = model.lastGroundHazard { detection("LiDAR", g) }
            if let s = model.hazards.lastSign { detection("Sign", s) }
            if let c = model.hazards.lastCaution { detection("Watch", c) }
            if let err = model.hazards.lastError ?? model.hazardLog.lastError {
                Text(err).font(CKFont.secondary).foregroundStyle(CKColor.laneUrgent)
            }
            if model.hazardLog.fileWritten {
                ShareLink(item: model.hazardLog.fileURL) {
                    Label("Share hazard map", systemImage: "square.and.arrow.up")
                        .font(CKFont.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: CKMetrics.touchTarget)
                }
                .buttonStyle(CKBigButtonStyle(role: .secondary))
                .accessibilityHint("Shares a GeoJSON map of every hazard found on this walk")
            }

            Toggle("Live camera view", isOn: $model.liveViewEnabled)
                .font(CKFont.body).foregroundStyle(CKColor.textPrimary)
                .accessibilityHint("Shows what the camera sees, for a sighted helper")
            liveView
        }
    }

    /// Under the "Live camera view" switch: nothing when off; a caption while the phone is hot
    /// (the view is optional, the lanes are not) or while ARKit is not running; else the GPU
    /// `LiveCameraView` of the app's own ARSession at the camera's frame rate (30, or 60 with the
    /// Mount card switch), in the camera's 3:4 portrait shape so the whole frame shows. The
    /// decision is `LiveView.state` (CaneKitLogic, pinned by LiveViewTests); the whole block is
    /// hidden from VoiceOver (it carries nothing a blind user needs).
    @ViewBuilder private var liveView: some View {
        switch LiveView.state(enabled: model.liveViewEnabled, hot: model.hazards.paused,
                              cameraRunning: model.depth.isRunning,
                              highFrameRate: model.highFrameRateCamera,
                              foreground: scenePhase == .active) {
        case .off:
            EmptyView()
        case .hot:
            liveCaption("Live view paused: phone is hot")
        case .cameraOff:
            liveCaption("Camera off")
        case .live(let fps):
            LiveCameraView(session: model.depth.arSession, framesPerSecond: fps)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)     // 4:3 sensor, portrait UI
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: CKRadius.button, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    /// Small grey line standing in for the live view (hot / camera off); hidden from VoiceOver
    /// like the view itself. Called only by `liveView`.
    private func liveCaption(_ text: String) -> some View {
        Text(text).font(CKFont.secondary).foregroundStyle(CKColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(text)   // a paused view or a dead camera must be spoken (Muse review)
    }

    /// One detection row: a small caption and the spoken line.
    private func detection(_ source: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CKSpacing.sm) {
            Text(source.uppercased()).font(CKFont.pill).foregroundStyle(CKColor.textSecondary)
            Text(text).font(CKFont.body).foregroundStyle(CKColor.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}
