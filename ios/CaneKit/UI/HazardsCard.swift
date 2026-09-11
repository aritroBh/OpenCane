//
//  HazardsCard.swift
//  CaneKit
//
//  "Hazards" card: the camera's second job made visible. Toggles for the three hazard sources
//  (LiDAR drop-offs / potholes / curbs, sign reading, hazard watch), the last thing each one said,
//  which backend the hazard watch uses, the hazard-map count with a share button, and an optional
//  live camera view for the sighted spotter and the demo video.
//
//  Implements docs/design.md (cards, pills, toggles, big buttons). Accessibility: every toggle is
//  a labelled switch ("Detect drop-offs", "Read signs", "Hazard watch", "Live camera view");
//  the live view image is hidden from VoiceOver (it carries no information a blind user needs).
//

import CaneKitLogic
import SwiftUI
import UIKit

struct HazardsCard: View {
    @Environment(AppModel.self) private var model
    /// Latest camera frame for the live view (refreshed ~3 Hz only while the toggle is on).
    @State private var frame: UIImage?

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
            if model.liveViewEnabled {
                Group {
                    if let frame {
                        Image(uiImage: frame).resizable().scaledToFit()
                    } else {
                        Text("Camera warming up").font(CKFont.secondary).foregroundStyle(CKColor.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: CKRadius.button, style: .continuous))
                .accessibilityHidden(true)
                .task(id: model.liveViewEnabled) { await refreshLoop() }
            }
        }
    }

    /// One detection row: a small caption and the spoken line.
    private func detection(_ source: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CKSpacing.sm) {
            Text(source.uppercased()).font(CKFont.pill).foregroundStyle(CKColor.textSecondary)
            Text(text).font(CKFont.body).foregroundStyle(CKColor.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    /// ~3 Hz while the toggle is on and the app is in the foreground (SwiftUI keeps the task
    /// alive while the card is scrolled off-screen inside the List/ScrollView; the encode is a
    /// 480 px JPEG, cheap next to ARKit, and it pauses when hot — `liveFrameJPEG` returns nil).
    /// Starts blank so a re-enable never flashes an old frame.
    private func refreshLoop() async {
        frame = nil
        while !Task.isCancelled, model.liveViewEnabled {
            if let data = await model.liveFrameJPEG(), let img = UIImage(data: data) { frame = img }
            try? await Task.sleep(for: .milliseconds(330))
        }
    }
}
