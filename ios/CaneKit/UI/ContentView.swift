//
//  ContentView.swift
//  CaneKit
//
//  Root screen. Three icon-only pages under a sliding tab bar (docs/design.md §6):
//    Guide    — instruction, buttons, route picker, trip / arrival
//    Sense    — depth status, 3×2 obstacle grid, Hazards
//    Settings — Haptics, Watch, Mount (tilt + fps + toggles), This phone
//  Styled only with Theme.swift tokens. No debug footer (removed in Step 11).
//
//  Pages fade in; they never slide sideways (a horizontal slide read as "going forward" even
//  when moving left, and direction carries no meaning here). See docs/design.md §4.
//
//  Accessibility contract: VoiceOver order is the selected page's cards, then the tab bar.
//  Mount toggle labels are XCUITest `app.switches[...]` keys: "Mirror left / right" and
//  "Write trip log" are ⚠ test contract (AGENTS.md rule 9). Tab buttons are ⚠ "Guide",
//  "Sense", "Settings" (`RootTab.title`).
//

import CaneKitLogic
import SwiftUI
import UIKit

/// The app's root: a `NavigationStack` titled "OpenCane" around the selected page and `CKTabBar`.
///
/// Reads everything from the shared `AppModel` (injected by the app entry). Owns the selected
/// `RootTab`. Also hosts the invisible `CameraControlInteraction`: a Camera Control / volume
/// press is treated as "Where am I" and logged (`describe {source: cameraControl}`).
struct ContentView: View {
    /// Incoming-page fade length. Matches the tab pill's travel (TabBar `pillTravel`) so pill
    /// and page land together; longer than this the switch feels laggy, shorter it flashes.
    static let pageFade: TimeInterval = 0.16
    /// The app-wide owner of every engine; `@Bindable` inside settings for the toggle bindings.
    @Environment(AppModel.self) private var model
    /// Which of the three pages is showing. Starts on Guide so the idle walk controls are first.
    @State private var tab: RootTab = .guide
    /// Instant page swap when the user asked for less motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(tab)
                    // Fade the incoming page in; the outgoing page is removed instantly, never
                    // cross-faded. A symmetric cross-fade kept two full ScrollViews (and Sense's
                    // SceneKit preview teardown/setup) alive inside the animation and dropped
                    // frames on device. Pages still never slide: a horizontal slide read as
                    // "going forward" even when moving left, and direction is not information.
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
                CKTabBar(selection: $tab)
            }
            .background(CKColor.background)
            .navigationTitle("OpenCane")
            .animation(reduceMotion ? nil : .easeOut(duration: Self.pageFade), value: tab)
        }
        // Camera Control / volume-button spike: counts presses in the footer.
        .background(CameraControlInteraction { model.cameraControlPressed() })
    }

    /// The selected page. Only the visible page is in the tree, so 30 Hz depth updates stay on Sense.
    @ViewBuilder
    private var page: some View {
        switch tab {
        case .guide: GuidePage()
        case .sense: SensePage()
        case .settings: SettingsPage()
        }
    }

}

// MARK: - Pages

/// Guide page: walk controls, destination field, trip / arrival.
///
/// The `ScrollViewReader` proxy goes to the Guide card so focusing the destination field
/// can scroll it above the keyboard (`DestinationField.anchorID`).
private struct GuidePage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            pageScroll {
                GuideCard(scroller: proxy)
                if model.nav.isNavigating || model.nav.arrived {
                    ArrivalCardView()
                }
            }
        }
    }
}

/// Sense page: depth status, obstacle grid, hazards. Isolated so 30 Hz frames stay here.
private struct SensePage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        pageScroll {
            statusCard
            ObstaclesCard()
            HazardsCard()
        }
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
}

/// Settings page: haptics, watch, mount, this phone.
private struct SettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        pageScroll {
            cueSettings($model)
            HapticsCard()
            WatchCard()
            mountSettings($model)
            capabilityCard
        }
    }

    /// "Cues" card (Step 36, cue design v2): how much OpenCane volunteers, and where the walker is.
    ///
    /// Two segmented pickers, first on the page because they are the settings a walker changes most:
    /// "Cue detail" (Quiet / Standard / Detailed, default Detailed = today) and "Place" (Outdoors /
    /// Indoors). Each change is spoken once by the model ("Quiet cues.", "Indoor mode."), so a
    /// VoiceOver user hears the effect, not just the selection. The caption under the pickers says
    /// what the current level means in one sentence (`cueLevelCaption`).
    /// ⚠ test contract: `testCuePickersChangeAndRestore` taps the segment titles `CueLevel.title` /
    /// `CuePlace.title` ("Standard", "Detailed", "Indoors", "Outdoors").
    /// - Parameter model: the `@Bindable` model from `body`.
    private func cueSettings(_ model: Bindable<AppModel>) -> some View {
        CKCard(title: "Cues") {
            // A segmented picker does not show or speak its own title on iOS, so each gets a visible
            // label and a VoiceOver container named after it; otherwise a swipe hears "Quiet, button"
            // with no context, next to the speech pill that also says "Quiet" (Step 36 review).
            Text("Cue detail").font(CKFont.secondary).foregroundStyle(CKColor.textSecondary)
                .accessibilityHidden(true)
            Picker("Cue detail", selection: model.cueLevel) {
                ForEach(CueLevel.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Cue detail")
            .accessibilityHint("How much OpenCane says on its own. Quiet names nothing and reads only safety signs. Obstacle haptics are the same at every level for now.")
            Text("Place").font(CKFont.secondary).foregroundStyle(CKColor.textSecondary)
                .accessibilityHidden(true)
            Picker("Place", selection: model.cuePlace) {
                ForEach(CuePlace.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Place")
            .accessibilityHint("Indoors warns about head height from 1.2 meters instead of 1.5, names nothing and reads only safety signs.")
            Text(cueLevelCaption)
                .font(CKFont.secondary).foregroundStyle(CKColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(CKFont.body)
        .foregroundStyle(CKColor.textPrimary)
    }

    /// What the selected level × place changes **today** (Step 36 changes speech only; haptics are
    /// the same at every level until Step 40 — the Step 36 review caught a caption promising more),
    /// plus a reminder when names are switched off, which Standard and Detailed depend on.
    private var cueLevelCaption: String {
        var parts: [String]
        switch model.cueLevel {
        case .quiet: parts = ["Quiet: no obstacle names; safety signs only."]
        case .standard: parts = ["Standard: door names on a route; every sign."]
        case .detailed: parts = ["Detailed: every obstacle name except walls; every sign."]
        }
        if model.cuePlace == .indoors {
            parts.append("Indoors: head height from 1.2 meters, no names, safety signs only.")
        }
        if !model.obstacleNamesEnabled, model.cueLevel != .quiet, model.cuePlace == .outdoors {
            parts.append("Names are off: turn on Speak obstacle names below to hear them.")
        }
        parts.append("Haptics are the same at every level for now.")
        return parts.joined(separator: " ")
    }

    /// "Mount" card: persisted system `Toggle`s (the settings rows of design.md §6.5).
    ///
    /// Each toggle's visible label is its VoiceOver label and its XCUITest `switches[...]` key;
    /// the hint says when to flip it. ⚠ test contract: "Mirror left / right" (testMountTogglesPersist)
    /// and "Write trip log" (testAccessibilityLabelsExist) must not be renamed without the tests.
    /// - Parameter model: the `@Bindable` model from `body`, so each toggle gets a binding.
    private func mountSettings(_ model: Bindable<AppModel>) -> some View {
        CKCard(title: "Mount") {
            MountAimRow()
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

// MARK: - Shared page chrome

/// Shared scroll chrome for every root page: gutter, card spacing, tap-to-dismiss keyboard.
///
/// - Parameter content: the page's cards, top to bottom.
@ViewBuilder
private func pageScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    ScrollView {
        VStack(alignment: .leading, spacing: CKSpacing.xl) {
            content()
        }
        .padding(CKSpacing.gutter)
        // Tapping anywhere that is not a control gives the keyboard back. Buttons,
        // toggles and the field itself consume their own taps first.
        .contentShape(Rectangle())
        .onTapGesture { dismissKeyboard() }
    }
    // Dragging the page down also dismisses it, the way Maps and Mail do.
    .scrollDismissesKeyboard(.interactively)
}

/// Resigns the keyboard from wherever it is. The destination field's `@FocusState` follows
/// the first responder, so this keeps that view's state right without threading a focus
/// binding through two views.
private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                    to: nil, from: nil, for: nil)
}

/// Obstacles card wrapper, isolated into a leaf subview so 30 Hz depth frame updates
/// only re-evaluate this card rather than the Sense page scroll view.
private struct ObstaclesCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LaneGridView(report: model.depth.report)
    }
}

/// Live camera aim + depth rate, isolated into a leaf subview so 30 Hz updates do not
/// re-evaluate the surrounding Mount card toggles.
private struct MountAimRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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
}

/// Canvas preview with a fresh `AppModel` (no engines started, so most cards show idle state).
#Preview {
    ContentView()
        .environment(AppModel())
}
