//
//  ContentView.swift
//  CaneKit
//
//  Root screen. One scroll view of cards, top to bottom: Guide (instruction, buttons, route
//  picker), the trip card while a route runs or after arrival, the depth status line, the 3×2
//  obstacle grid, Hazards (drop-offs, signs, hazard watch, hazard map, live view), Haptics, Watch,
//  Mount (camera tilt + fps line, then toggles) and "This phone" capabilities. No debug footer
//  (removed in Step 11). Styled only with Theme.swift tokens (docs/design.md).
//
//  Implements docs/design.md §6 (screens) as a single scrolling page rather than the four-tab
//  bar the spec describes: Guide = §6.1 / §6.3 (GuideCard), Depth = §6.2 (statusCard +
//  LaneGridView), Arrival = §6.4 (ArrivalCardView, inline instead of a sheet), Settings = §6.5
//  (Mount card here, cue toggles in HapticsCard / WatchCard / HazardsCard).
//
//  Accessibility contract: the card order *is* the VoiceOver focus order (no sort priorities,
//  design.md §7). The Mount toggle labels are XCUITest `app.switches[...]` keys:
//  "Mirror left / right" and "Write trip log" are ⚠ test contract (AGENTS.md rule 9).
//

import CaneKitLogic
import SwiftUI
import UIKit

/// The app's only screen: a `NavigationStack` titled "CaneKit" around a vertical stack of cards.
///
/// Reads everything from the shared `AppModel` (injected by the app entry); owns no state of its
/// own. Also hosts the invisible `CameraControlInteraction`: a Camera Control / volume press is
/// treated as "Where am I" and logged (`describe {source: cameraControl}`).
struct ContentView: View {
    /// The app-wide owner of every engine; `@Bindable` inside `body` for the toggle bindings.
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            // The proxy goes to the Guide card so focusing the destination field can scroll it
            // above the keyboard (DestinationField.anchorID).
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: CKSpacing.xl) {
                        GuideCard(scroller: proxy)
                        if model.nav.isNavigating || model.nav.arrived {
                            ArrivalCardView()
                        }
                        statusCard
                        LaneGridView(report: model.depth.report)
                        HapticsCard()
                        HazardsCard()
                        WatchCard()
                        mountSettings($model)
                        capabilityCard
                    }
                    .padding(CKSpacing.gutter)
                    // Tapping anywhere that is not a control gives the keyboard back. Buttons,
                    // toggles and the field itself consume their own taps first.
                    .contentShape(Rectangle())
                    .onTapGesture { dismissKeyboard() }
                }
                // Dragging the page down also dismisses it, the way Maps and Mail do.
                .scrollDismissesKeyboard(.interactively)
                .background(CKColor.background)
                .navigationTitle("CaneKit")
            }
        }
        // Camera Control / volume-button spike: counts presses in the footer.
        .background(CameraControlInteraction { model.cameraControlPressed() })
    }

    // MARK: Pieces

    /// Resigns the keyboard from wherever it is. The destination field's `@FocusState` follows
    /// the first responder, so this keeps that view's state right without threading a focus
    /// binding through two views.
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    /// Big, high-contrast status line — readable at arm's length on a cane.
    ///
    /// Shows the depth engine's status sentence with a LiDAR-supported check / octagon glyph
    /// (glyph hidden from VoiceOver). Accessibility: one combined element labelled
    /// "Status: <status>", trait `.updatesFrequently` so a touch re-reads the live value.
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

    /// "Mount" card: four persisted system `Toggle`s (the settings rows of design.md §6.5).
    ///
    /// Each toggle's visible label is its VoiceOver label and its XCUITest `switches[...]` key;
    /// the hint says when to flip it. ⚠ test contract: "Mirror left / right" (testMountTogglesPersist)
    /// and "Write trip log" (testAccessibilityLabelsExist) must not be renamed without the tests.
    /// - Parameter model: the `@Bindable` model from `body`, so each toggle gets a binding.
    private func mountSettings(_ model: Bindable<AppModel>) -> some View {
        CKCard(title: "Mount") {
            mountAimRow
            Toggle("Phone held upright (portrait)", isOn: model.portraitMode)
                .accessibilityHint("Turn off if the phone is clamped sideways")
            // ⚠ test contract: switches["Mirror left / right"].
            Toggle("Mirror left / right", isOn: model.mirrorLeftRight)
                .accessibilityHint("Turn on if left and right warnings feel swapped")
            Toggle("60 fps camera (warmer)", isOn: model.highFrameRateCamera)
                .accessibilityHint("Smoother live view; uses more battery and heat. Obstacle cues are the same either way.")
            Toggle("Audio beacon while navigating", isOn: model.beaconEnabled)
                .accessibilityHint("A soft click from the direction to walk, through the AirPods")
            // ⚠ test contract: switches["Write trip log"].
            Toggle("Write trip log", isOn: model.loggingEnabled)
                .accessibilityHint("Saves a JSONL log of lanes, cues and location to the Files app")
        }
        .font(CKFont.body)
        .foregroundStyle(CKColor.textPrimary)
    }

    /// Live camera aim + depth rate, so the mount's hinge can be set by reading the phone
    /// (aim 3–8° below the horizon, `MountTilt`; hardware/mount/DESIGN.md). Spoken as one line.
    @ViewBuilder private var mountAimRow: some View {
        if let tilt = model.depth.report.cameraTiltDownDeg {
            let s = MountTilt.status(downDeg: tilt)
            let fps = Int(model.depth.fps.rounded())
            Label {
                Text("\(s.text) · \(fps) fps").foregroundStyle(CKColor.textPrimary)
            } icon: {
                Image(systemName: s.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(s.ok ? CKColor.laneClear : CKColor.laneUrgent)
            }
            .font(CKFont.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(s.text). Depth \(fps) frames per second")
        } else if model.lidarSupported {
            // No trusted frame yet (warming up, or the cane is moving): say how to get a reading.
            Text("Camera tilt: hold the cane still for a reading")
                .font(CKFont.secondary).foregroundStyle(CKColor.textSecondary)
        }
    }

    /// "This phone" card: which hardware / package features this device actually has, so a
    /// teammate can tell at a glance why depth or mesh cues are missing.
    private var capabilityCard: some View {
        CKCard(title: "This phone") {
            capabilityRow("LiDAR depth", model.lidarSupported)
            capabilityRow("Mesh classification (door / wall / seat)", model.meshClassificationSupported)
            capabilityRow("Logic package linked", Self.logicPackageOK)
        }
    }

    /// One capability line: a check or octagon glyph plus the feature name.
    ///
    /// Accessibility: labelled "<title>: available" / "<title>: not available" so the state is in
    /// words, never colour or glyph alone (design.md §7).
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
    ///
    /// The literal 4 Hz at 1.0 m is the Geiger curve's contract (unit-tested in ios/Logic);
    /// change it only together with those tests.
    private static var logicPackageOK: Bool {
        GeigerRate.hertz(distance: 1.0) == 4
    }
}

/// Canvas preview with a fresh `AppModel` (no engines started, so most cards show idle state).
#Preview {
    ContentView()
        .environment(AppModel())
}
