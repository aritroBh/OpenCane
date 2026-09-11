//
//  ContentView.swift
//  CaneKit
//
//  Root screen. Step 2: status header, the 3×2 depth grid, mount toggles, capability list and
//  the developer footer, styled with Theme.swift (docs/design.md). The Guide screen with the
//  big Start / Describe / Recenter / Next buttons arrives in step 6 when there is a route to run.
//

import CaneKitLogic
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CKSpacing.xl) {
                    statusCard
                    LaneGridView(report: model.depth.report)
                    HapticsCard()
                    mountSettings($model)
                    capabilityCard
                    DebugFooter()
                }
                .padding(CKSpacing.gutter)
            }
            .background(CKColor.background)
            .navigationTitle("CaneKit")
        }
        // Camera Control / volume-button spike: counts presses in the footer.
        .background(CameraControlInteraction { model.cameraControlPressed() })
    }

    // MARK: Pieces

    /// Big, high-contrast status line — readable at arm's length on a cane.
    private var statusCard: some View {
        CKCard {
            HStack(spacing: CKSpacing.md) {
                Image(systemName: model.lidarSupported ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(model.lidarSupported ? CKColor.laneClear : CKColor.laneUrgent)
                    .accessibilityHidden(true)
                Text(model.status)
                    .font(CKFont.instruction)
                    .foregroundStyle(CKColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(model.status)")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func mountSettings(_ model: Bindable<AppModel>) -> some View {
        CKCard(title: "Mount") {
            Toggle("Phone held upright (portrait)", isOn: model.portraitMode)
                .accessibilityHint("Turn off if the phone is clamped sideways")
            Toggle("Mirror left / right", isOn: model.mirrorLeftRight)
                .accessibilityHint("Turn on if left and right warnings feel swapped")
            Toggle("Write trip log", isOn: model.loggingEnabled)
                .accessibilityHint("Saves a JSONL log of lanes, cues and location to the Files app")
        }
        .font(CKFont.body)
        .foregroundStyle(CKColor.textPrimary)
    }

    private var capabilityCard: some View {
        CKCard(title: "This phone") {
            capabilityRow("LiDAR depth", model.lidarSupported)
            capabilityRow("Mesh classification (door / wall / seat)", model.meshClassificationSupported)
            capabilityRow("Logic package linked", Self.logicPackageOK)
        }
    }

    private func capabilityRow(_ title: String, _ ok: Bool) -> some View {
        Label {
            Text(title).foregroundStyle(CKColor.textPrimary)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(ok ? CKColor.laneClear : CKColor.laneUrgent)
        }
        .font(CKFont.body)
        .accessibilityLabel("\(title): \(ok ? "available" : "not available")")
    }

    /// Proves the SwiftPM link at runtime: a trivial call into CaneKitLogic.
    private static var logicPackageOK: Bool {
        GeigerRate.hertz(distance: 1.0) == 4
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
}
