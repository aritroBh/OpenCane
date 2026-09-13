//
//  ContentView.swift
//  CaneKit
//
//  Root screen. Four icon-only pages under a sliding tab bar (docs/design.md §6):
//    Guide    — instruction, buttons, route picker, trip / arrival
//    Sense    — depth status, Scene engine (Step 47: who answered "Where am I" and why), 3×2 obstacle grid, Hazards
//    Settings — Cues (Step 36), Haptics, Watch, Mount (tilt + fps + toggles), This phone
//  Styled only with Theme.swift tokens. No debug footer (removed in Step 11).
//
//  Pages fade in; they never slide sideways (a horizontal slide read as "going forward" even
//  when moving left, and direction carries no meaning here). See docs/design.md §4.
//
//  Accessibility contract: VoiceOver order is the selected page's cards, then the tab bar.
//  Mount toggle labels are XCUITest `app.switches[...]` keys: "Mirror left / right" and
//  "Write trip log" are ⚠ test contract (AGENTS.md rule 9). Tab buttons are ⚠ "Guide",
//  "Sense", "Settings", "Profile" (`RootTab.title`; accessibility tests cover all four). Cues picker segments are ⚠ "Standard", "Detailed",
//  "Indoors", "Outdoors" (`CueLevel.title` / `CuePlace.title`).
//
//  Owner / caller: `CaneKitApp` (the app entry) shows it with `AppModel` in the environment.
//  Tests: `CaneKitUITests` (`testAccessibilityLabelsExist`, `testMountTogglesPersist`,
//  `testCuePickersChangeAndRestore`, and every test's `openTab`) and `CaneKitVisualTour`.
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
    /// The app-wide owner of every engine. Used here only for the Camera Control press; each page
    /// reads its own copy from the environment (Settings makes it `@Bindable` for the toggles).
    @Environment(AppModel.self) private var model
    /// Which of the four pages is showing. Starts on Guide so the idle walk controls are first.
    /// True between keyboardWillShow and keyboardWillHide; hides the tab bar (Step 50).
    @State private var keyboardUp = false
    @State private var tab: RootTab = .guide
    /// Instant page swap when the user asked for less motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Distinct title for each top-level tab.
    private var navigationTitleText: String {
        switch tab {
        case .guide: "OpenCane"
        case .sense: "Details"
        case .settings: "Settings"
        case .profile: "Profile"
        }
    }

    /// Page (re-identified per tab so the transition runs) above the tab bar, on the ivory ground,
    /// titled "OpenCane", with the invisible Camera Control interaction behind everything.
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
                // The tab bar collapses while the keyboard is up (Step 50): iOS 26 draws the
                // keyboard's "Done" as a floating glass capsule that sat on the Profile icon, and
                // nobody switches tabs mid-typing. It stays MOUNTED (height 0, invisible, hidden
                // from VoiceOver) rather than removed, so the accessibility tree keeps its
                // landmarks and focus does not jump when it comes back (Muse review).
                CKTabBar(selection: $tab)
                    .frame(height: keyboardUp ? 0 : nil)
                    .opacity(keyboardUp ? 0 : 1)
                    .clipped()
                    .accessibilityHidden(keyboardUp)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
            .background(CKColor.background)
            .navigationTitle(navigationTitleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(navigationTitleText)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(CKColor.textPrimary)
                        .accessibilityHidden(true)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: Self.pageFade), value: tab)
        }
        // Camera Control / volume-button spike: a press is logged (`describe {source:
        // cameraControl}`) and runs "Where am I". The on-screen press counter went with the debug
        // footer in Step 11; the trip log is the readout.
        .background(CameraControlInteraction { model.cameraControlPressed() })
    }

    /// The selected page. Only the visible page is in the tree, so 30 Hz depth updates stay on Sense.
    @ViewBuilder
    private var page: some View {
        switch tab {
        case .guide: GuidePage()
        case .sense: SensePage()
        case .settings: SettingsPage()
        case .profile: ProfilePage()
        }
    }

}

// MARK: - Pages

/// Guide page: walk controls, destination field, trip / arrival.
///
/// The `ScrollViewReader` proxy goes to the Guide card so focusing the destination field
/// can scroll it above the keyboard (`DestinationField.anchorID`).
private struct GuidePage: View {
    /// Read for `nav.isNavigating` / `nav.arrived`, which decide whether the trip card shows.
    @Environment(AppModel.self) private var model

    /// `GuideCard`, then `ArrivalCardView` while a route runs or after arrival.
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
    /// Read for `lidarSupported` and `status` (the depth engine's status sentence).
    @Environment(AppModel.self) private var model

    /// Status card, Scene engine card (Step 47), obstacle grid, Hazards card, top to bottom.
    var body: some View {
        pageScroll {
            statusCard
            SceneEngineCard()
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

/// Add / remove the family email addresses the Grok Bot routine alerts, and register the list.
///
/// Editing and registering are separate on purpose: typing half an address must not fire a
/// webhook, and the bot emails every address a confirmation on the first accepted Save.
///
/// ⚠ The app sends no email. "Save" posts the list; the bot owns delivery, so every string here
/// says what the *bot* did ("Grok Bot accepted…"), never that mail arrived.
///
/// Accessibility: the list is rows of `Text` + a Remove button labelled with the address it
/// removes ("Remove mom@example.com"), so VoiceOver never announces four identical "Remove"
/// buttons. Errors are spoken text, not a red border.
private struct FamilyContactsEditor: View {
    @Environment(AppModel.self) private var model
    /// The address being typed. Local: a half-typed entry is not worth persisting.
    @State private var draft = ""
    /// Why the last Add was refused, or nil.
    @State private var error: String?
    /// True while the registration POST is in flight, so Save cannot be double-tapped.
    @State private var saving = false
    @FocusState private var fieldFocused: Bool

    /// Whether the typed text could be added at all — drives the Add button's enabled state so the
    /// control tells the truth before it is pressed.
    private var canAdd: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // ⚠ Split into small sub-views: as one expression this body exceeded the type-checker
    // ("failed to produce diagnostic"). Keep each piece small when adding a row.
    var body: some View {
        VStack(alignment: .leading, spacing: CKSpacing.md) {
            header
            addressList
            entryRow
            errorLine
            saveRow
        }
    }

    /// "Family emails" plus how many are on the list, so the count is readable without counting
    /// rows (and is in the VoiceOver label rather than implied by the layout).
    private var header: some View {
        let count = model.familyEmails.count
        return Text("Family emails")
            .font(CKFont.body)
            .foregroundStyle(CKColor.textPrimary)
            .accessibilityLabel(count == 0
                                ? "Family emails, none yet"
                                : "Family emails, \(count) on the list")
    }

    /// One card-like row per address. Each row is a single VoiceOver element ending in its own
    /// Remove button, so a list of four does not read as four identical "Remove"s.
    @ViewBuilder private var addressList: some View {
        if model.familyEmails.isEmpty {
            Text("Nobody yet. Add an address below, then Save.")
                .font(CKFont.secondary)
                .foregroundStyle(CKColor.textSecondary)
        } else {
            VStack(spacing: CKSpacing.xs) {
                ForEach(model.familyEmails, id: \.self) { address in
                    addressRow(address)
                }
            }
        }
    }

    /// One stored address and its Remove control.
    private func addressRow(_ address: String) -> some View {
        HStack(spacing: CKSpacing.sm) {
            Image(systemName: "envelope.fill")
                .font(CKFont.secondary)
                .foregroundStyle(CKColor.textSecondary)
                .accessibilityHidden(true)
            Text(address)
                .font(CKFont.secondary)
                .foregroundStyle(CKColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: CKSpacing.sm)
            Button {
                model.removeFamilyEmail(address)
                error = nil
            } label: {
                Image(systemName: "trash")
                    .font(CKFont.secondary)
                    .foregroundStyle(CKColor.laneUrgent)
                    .frame(width: 44, height: 44)       // full hit target, small glyph
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(address)")
        }
        .padding(.leading, CKSpacing.sm)
        .background(CKColor.surfaceRaised, in: RoundedRectangle(cornerRadius: CKRadius.tile, style: .continuous))
    }

    /// The add field. ⚠ No fake address as placeholder: the owner's note was that everyone knows
    /// what an email looks like, and "family@example.com" in grey reads as a filled-in field.
    private var entryRow: some View {
        HStack(spacing: CKSpacing.sm) {
            TextField("Add an address", text: $draft)
                .textFieldStyle(.plain)
                .font(CKFont.body)
                .foregroundStyle(CKColor.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .submitLabel(.done)
                .focused($fieldFocused)
                .onSubmit(add)
                .padding(.horizontal, CKSpacing.sm)
                .padding(.vertical, CKSpacing.sm)
                .background(CKColor.surfaceRaised, in: RoundedRectangle(cornerRadius: CKRadius.tile, style: .continuous))
                .accessibilityLabel("Family email")
                .accessibilityHint("Type an address, then Add. Press Save to register the list.")
            Button(action: add) {
                Image(systemName: "plus")
                    .font(CKFont.body)
                    .foregroundStyle(canAdd ? CKColor.textPrimary : CKColor.textSecondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
            .accessibilityLabel("Add")
            .accessibilityHint("Adds the typed address to the list")
        }
    }

    /// Why the last Add was refused. Words, never a red border alone (design.md §7).
    @ViewBuilder private var errorLine: some View {
        if let error {
            Text(error)
                .font(CKFont.secondary)
                .foregroundStyle(CKColor.laneUrgent)
        }
    }

    /// Register the list, plus the reminder that an edit has not been registered yet.
    @ViewBuilder private var saveRow: some View {
        CKBigButton(title: "Save family emails",
                    systemImage: "person.crop.circle.badge.checkmark",
                    role: model.familyContactsNeedSave ? .primary : .secondary,
                    hint: "Registers the list with the OpenCane Grok Bot, which emails your family when the cane reports a fall or SOS",
                    value: saving ? "Saving" : nil) {
            save()
        }
        .disabled(saving || !model.family.isConfigured)

        if model.familyContactsNeedSave {
            Text("Not registered yet — press Save.")
                .font(CKFont.secondary)
                .foregroundStyle(CKColor.laneNear)
        }
    }

    /// Adds the typed address, or shows why it was refused. Keeps focus so a typo can be retried
    /// without hunting for the field again.
    private func add() {
        error = model.addFamilyEmail(draft)
        if error == nil {
            draft = ""
            fieldFocused = true
        }
    }

    /// Registers the list once, ignoring a second tap while the first POST is in flight. The 10 s
    /// spam guard in `AppModel` is the other half of this.
    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            await model.saveFamilyContacts()
            saving = false
        }
    }
}

/// Settings page: cues, haptics, watch, mount, this phone.
private struct SettingsPage: View {
    /// Made `@Bindable` in `body` so the pickers and toggles get two-way bindings.
    @Environment(AppModel.self) private var model

    /// Cues first (the settings a walker changes most), then Haptics, Voice (Step 53), Watch, Mount,
    /// Family alerts, This phone.
    var body: some View {
        @Bindable var model = model
        pageScroll {
            cueSettings($model)
            HapticsCard()
            voiceSettings($model)
            WatchCard()
            mountSettings($model)
            familyAlertsCard($model)
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
            .accessibilityHint("How much OpenCane says and taps on its own. Quiet names nothing, reads only safety signs and taps only for head height. Standard taps once at 1.5 meters and a strong triple at 0.6, with no side taps. Detailed taps continuously ahead and for the sides. Head height warnings are the same at every level.")
            Text("Place").font(CKFont.secondary).foregroundStyle(CKColor.textSecondary)
                .accessibilityHidden(true)
            Picker("Place", selection: model.cuePlace) {
                ForEach(CuePlace.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Place")
            .accessibilityHint("Indoors warns about head height from 1.2 meters instead of 1.5, names nothing, reads only safety signs and taps only for head height.")
            Text(cueLevelCaption)
                .font(CKFont.secondary).foregroundStyle(CKColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(CKFont.body)
        .foregroundStyle(CKColor.textPrimary)
    }

    /// "Voice" card (Step 53; owner decision 2026-09-13 "ElevenLabs is the one voice for everything").
    ///
    /// Section 1, the voice: a segmented "Voice" picker, Natural / System (`AppModel.naturalVoiceEnabled`,
    /// persisted). Natural is the one voice for every line; System is the founder's valve for a venue
    /// with bad Wi-Fi. Disabled without an ElevenLabs key, and the caption then says so (the Haptics
    /// card's voice pill shows what actually spoke). Same visible label + VoiceOver container pattern
    /// as the Cues pickers (a segmented picker does not speak its own title).
    /// Section 2, listening (Step 58, voice shell): "Listen on launch" and the follow-up window —
    /// these toggles belong to the voice shell and are added / reworded by that step; keep them below
    /// the picker. New labels only; nothing here is in the UI-test contract (hard rule 9).
    /// - Parameter model: the `@Bindable` model from `body`.
    private func voiceSettings(_ model: Bindable<AppModel>) -> some View {
        let hasKey = model.wrappedValue.speech.naturalVoice != nil
        return CKCard(title: "Voice") {
            Text("Voice").font(CKFont.secondary).foregroundStyle(CKColor.textSecondary)
                .accessibilityHidden(true)
            Picker("Voice", selection: model.naturalVoiceEnabled) {
                Text("Natural").tag(true)
                Text("System").tag(false)
            }
            .pickerStyle(.segmented)
            .disabled(!hasKey)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Voice")
            .accessibilityHint("Natural uses the ElevenLabs voice for every line. System uses the iPhone voice, which needs no network.")
            Text(hasKey
                 ? "Natural: one voice for everything. Cached lines play at once; a new line waits up to 2.5 seconds for the network, then the iPhone voice speaks it. System: the iPhone voice, instant and offline."
                 : "Add an ElevenLabs key for the natural voice.")
                .font(CKFont.secondary).foregroundStyle(CKColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // Step 58 (voice shell) listening toggles.
            Toggle("Listen on launch", isOn: model.listenOnLaunch)
                .accessibilityHint("Speaks the voice menu and listens when OpenCane starts")
            Toggle("Follow-up listening window", isOn: model.voiceFollowUp)
                .accessibilityHint("Opens a listening window after assistant answers")
        }
        .font(CKFont.body)
        .foregroundStyle(CKColor.textPrimary)
    }

    /// What the selected level × place changes: names and signs (Step 36) and, since Step 41, the
    /// cane taps for torso obstacles (`TorsoHapticPolicy`: Quiet none, Standard two onset taps,
    /// Detailed the continuous centre taps and side taps; Indoors none at any level) — every
    /// sentence here must stay true to that policy (the Step 36 review caught a caption promising
    /// more than the code did), plus a reminder when names are switched off, which Standard and
    /// Detailed depend on. Head height is never mentioned as changing: it does not.
    private var cueLevelCaption: String {
        var parts: [String]
        switch model.cueLevel {
        case .quiet: parts = ["Quiet: no obstacle names; safety signs only. No cane taps for torso obstacles; head height and ground hazards still warn."]
        case .standard: parts = ["Standard: door names on a route; every sign. One tap at 1.5 meters when closing, a strong triple at 0.6, no side taps."]
        case .detailed: parts = ["Detailed: every obstacle name except walls; every sign. Continuous centre taps and side taps."]
        }
        if model.cuePlace == .indoors {
            parts.append("Indoors: head height from 1.2 meters, no names, safety signs only, no torso taps (head height and ground hazards still warn).")
        }
        if !model.obstacleNamesEnabled, model.cueLevel != .quiet, model.cuePlace == .outdoors {
            parts.append("Names are off: turn on Speak obstacle names below to hear them.")
        }
        return parts.joined(separator: " ")
    }

    /// "Mount" card: persisted system `Toggle`s (the settings rows of design.md §6.5).
    ///
    /// Each toggle's visible label is its VoiceOver label and its XCUITest `switches[...]` key;
    /// the hint says when to flip it. ⚠ test contract: "Mirror left / right" (testMountTogglesPersist)
    /// and "Write trip log" (testAccessibilityLabelsExist) must not be renamed without the tests.
    /// Rows: live tilt / fps (`MountAimRow`), portrait (default on), mirror (off), "60 fps camera
    /// (warmer)" (`highFrameRateCamera`, off; note the live-view preview is capped at 30 fps
    /// whatever this says — `CameraRate.previewCap`), audio beacon (on), trip log (on).
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
            // Step 49. Default ON on purpose (see `AppModel.autoTorchInDark`): a blind walker cannot
            // see the dark, so the app notices it for them.
            Toggle("Flashlight on in the dark (routes)", isOn: model.autoTorchInDark)
                .accessibilityHint("When the camera sees low light while a route guides, OpenCane turns the flashlight on so the cameras can see and drivers can see you, and off again when the light returns or the route ends. Obstacle detection works in the dark either way.")
            // ⚠ test contract: switches["Write trip log"].
            Toggle("Write trip log", isOn: model.loggingEnabled)
                .accessibilityHint("Saves a JSONL log of lanes, cues and location to the Files app")
        }
        .font(CKFont.body)
        .foregroundStyle(CKColor.textPrimary)
    }

    /// "Family alerts" card: the opt-in plus the end-to-end test send.
    ///
    /// ⚠ Wording contract, not decoration: a 200 from the webhook means the Grok Bot routine
    /// **started a run**, not that anyone was texted — the bot decides that afterwards from the
    /// event's `severity` and `type`. No string here may say "family notified".
    ///
    /// The card explains itself when no webhook key is configured (Secrets.plist), because a
    /// switch that silently does nothing is worse than one that says why.
    /// - Parameter model: the `@Bindable` model from `body`.
    private func familyAlertsCard(_ model: Bindable<AppModel>) -> some View {
        CKCard(title: "Family alerts") {
            Toggle("Send cane events to family", isOn: model.familyAlertsEnabled)
                .accessibilityHint("Sends falls, close obstacles, low battery and a position every few minutes to the OpenCane Grok Bot, which decides whether to text your family")
                .disabled(!self.model.family.isConfigured)
            if !self.model.family.isConfigured {
                Text("No webhook key. Add OPENCANE_GROKBOT_WEBHOOK_URL and _KEY to Secrets.plist.")
                    .font(CKFont.secondary).foregroundStyle(CKColor.laneUrgent)
            }
            Toggle("Detect the cane falling", isOn: model.fallDetectionEnabled)
                .accessibilityHint("Reports to your family when the cane goes over and stays down. Thresholds are not tuned yet, so turn this off if it cries wolf.")
                .disabled(!self.model.fallWatcher.isSupported)
            if !self.model.fallWatcher.isSupported {
                Text("This device has no motion sensor, so falls cannot be detected.")
                    .font(CKFont.secondary).foregroundStyle(CKColor.textSecondary)
            }
            FamilyContactsEditor()
            Toggle("Add AI context", isOn: model.familyAlertsAIContext)
                .accessibilityHint("A small model writes one sentence of context for your family from what the phone knew. The facts are sent either way.")
                .disabled(!self.model.family.canSummarize)
            if let name = self.model.family.summarizerName, self.model.familyAlertsAIContext {
                Text("Context written by \(name).")
                    .font(CKFont.secondary).foregroundStyle(CKColor.textSecondary)
            } else if !self.model.family.canSummarize {
                Text("No model key, so alerts carry facts only.")
                    .font(CKFont.secondary).foregroundStyle(CKColor.textSecondary)
            }
            CKBigButton(title: "Send test event", systemImage: "antenna.radiowaves.left.and.right",
                        role: .secondary,
                        hint: "Posts one sample fall event to the Grok Bot routine and reports what it answered") {
                Task { await self.model.sendFamilyTestEvent() }
            }
            if let status = self.model.family.lastStatus {
                Text(status).font(CKFont.secondary).foregroundStyle(CKColor.textPrimary)
                    .accessibilityLabel("Last family alert: \(status)")
            }
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
func pageScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
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

/// "Scene engine" card on the Details (Sense) page, Step 47: which model actually answered the
/// last "Where am I", why the cloud was or was not used, how long it took, when and what asked
/// for it; the same for the hazard watch; and the cue profile in one line.
///
/// Why: the owner asked for the Details tab to say *when Muse is triggered* rather than only name
/// the chain ("Muse + On-device" on the Hazards card). Every sentence here is built by
/// `SceneEngineSummary` (CaneKitLogic) from `SceneEngineFacts`, so the wording is unit-tested
/// (`SceneEngineSummaryTests`) and the two numbers in it (the 8 s watch interval, the 2.5 s cloud
/// deadline) come from `HazardScanner.watchInterval` / `hazardCloudDeadlineS`, not literals here.
///
/// Rows, top to bottom: the provider-chain pill ("MUSE → ON-DEVICE" / "ON-DEVICE ONLY"); "WHERE
/// AM I" — who answered and how fast, with the age and trigger under it; "GATE" — what
/// `CloudSceneGate` did to a cloud sentence (only when the cloud answered); "WATCH" — the hazard
/// watch's plan or last answer; "CUES" — "Detailed · Outdoors · names off"; "VOICE" (Step 53) —
/// which voice spoke the last line and why ("Natural voice · cached").
///
/// Accessibility: every row is words, never colour; each row is one VoiceOver element whose label
/// is the row's full `spoken` sentence ("Muse answered the last Where am I in 1.9 seconds."); the
/// age row carries `.updatesFrequently`. A `TimelineView` re-renders every 10 s so "just now"
/// becomes "2 min ago" without a new run (the model publishes nothing while idle).
/// Owner: `SensePage` (between the status card and the obstacle grid). Reads `model.describer`,
/// `model.hazards`, `model.hazardWatchEnabled`, `model.cueLevel` / `cuePlace` / `obstacleNamesEnabled`.
private struct SceneEngineCard: View {
    /// Source of every fact on the card.
    @Environment(AppModel.self) private var model
    /// How often the relative ages are redrawn (s). 10 s matches the "just now" window in
    /// `SceneEngineSummary.age`, so the first change the reader sees is real.
    static let ageRefresh: TimeInterval = SceneEngineSummary.justNowWindow

    /// Gathers `SceneEngineFacts` at `now` from the describer, the scanner and the settings.
    /// - Parameter now: the timeline's date, so the ages tick without a model change.
    private func facts(at now: Date) -> SceneEngineFacts {
        let d = model.describer
        let h = model.hazards
        return SceneEngineFacts(
            cloudName: d.cloudName, onDeviceName: d.onDeviceName,
            lastSource: d.lastSource, lastCloudMs: d.lastCloudMs,
            lastLatencyMs: d.lastAt == nil ? nil : d.lastLatencyMs,
            lastFallbackReason: d.lastFallbackReason, lastGate: d.lastGate, lastError: d.lastError,
            secondsSinceLast: d.lastAt.map { max(0, now.timeIntervalSince($0)) },
            lastTrigger: d.lastTrigger,
            hazardWatchOn: model.hazardWatchEnabled, hazardWatchIntervalS: h.watchInterval,
            hazardCloudDeadlineS: h.hazardCloudDeadlineS,
            lastWatchSource: h.lastWatchSource, lastWatchMs: h.lastWatchMs,
            lastWatchReason: h.lastWatchReason,
            secondsSinceWatch: h.lastWatchAt.map { max(0, now.timeIntervalSince($0)) },
            lastWatchError: h.lastError,
            cueLevelTitle: model.cueLevel.title, cuePlaceTitle: model.cuePlace.title,
            namesOn: model.obstacleNamesEnabled,
            // Step 49: the light the cameras have. `ambientLux` is not observed (30 Hz), so the
            // Light row lives inside the 10 s `TimelineView` below and reads it there.
            lightState: model.lightState, ambientLux: model.ambientLux,
            torchOn: model.torchEnabled, torchByApp: model.torchLitByApp)
    }

    /// The card. Only the two age-bearing rows ("2 min ago", "· 30 s ago") sit inside the
    /// `TimelineView`, so the 10 s tick redraws those lines and nothing else — a periodic redraw of
    /// the whole card could move VoiceOver focus off the headline row a blind walker is reading
    /// (Muse review, Step 47). The other rows follow model changes as usual.
    var body: some View {
        let f = facts(at: Date())
        let chain = SceneEngineSummary.chain(f)
        CKCard(title: "Scene engine") {
            HStack(spacing: CKSpacing.sm) {
                CKStatusPill(text: chain.text, tone: .neutral, systemImage: "brain",
                             spoken: chain.spoken)
                Spacer(minLength: 0)
            }
            row("Where am I", SceneEngineSummary.lastAnswer(f))
            TimelineView(.periodic(from: .now, by: Self.ageRefresh)) { timeline in
                let live = facts(at: timeline.date)
                if let when = SceneEngineSummary.when(live) {
                    Text(when.text)
                        .font(CKFont.secondary).foregroundStyle(CKColor.textSecondary)
                        .accessibilityLabel(when.spoken)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            if let gate = SceneEngineSummary.gate(f) { row("Gate", gate) }
            TimelineView(.periodic(from: .now, by: Self.ageRefresh)) { timeline in
                let live = facts(at: timeline.date)
                row("Watch", SceneEngineSummary.hazardWatch(live))
                // Step 49: "Light: lit (640 lux)" / "Light: dark (12 lux) · flashlight on (by
                // OpenCane)" / "… flashlight off — cameras may miss things" / "Light: unknown".
                // In the timeline so the lux number refreshes every 10 s; a state change redraws
                // it at once through `model.lightState`.
                row("Light", SceneEngineSummary.light(live))
            }
            row("Cues", SceneEngineSummary.cues(f))
            voiceRow
        }
    }

    /// "VOICE" row (Step 53): the engine and reason of the last spoken line
    /// (`SpeechQueue.lastEngine`, updated again when its race resolves), in words from
    /// `VoiceEngineChoice.describe` — "Natural voice · cached", "System voice · warning not cached
    /// yet". Same shape as `row`; "No line spoken yet" before the first line.
    private var voiceRow: some View {
        let words = model.speech.lastEngine.map {
            VoiceEngineChoice.describe(engine: $0.engine, reason: $0.reason)
        } ?? "No line spoken yet"
        return HStack(alignment: .firstTextBaseline, spacing: CKSpacing.sm) {
            Text("VOICE").font(CKFont.pill).foregroundStyle(CKColor.textSecondary)
            Text(words).font(CKFont.body).foregroundStyle(CKColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last spoken line: \(words)")
    }

    /// One row: a small uppercased caption and the sentence, the same shape as the Hazards
    /// card's detection rows. One VoiceOver element labelled with `line.spoken`.
    /// - Parameters:
    ///   - caption: the row's word, drawn uppercased in `CKFont.pill`.
    ///   - line: the visible text and its VoiceOver sentence.
    private func row(_ caption: String, _ line: SceneEngineLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CKSpacing.sm) {
            Text(caption.uppercased()).font(CKFont.pill).foregroundStyle(CKColor.textSecondary)
            Text(line.text).font(CKFont.body).foregroundStyle(CKColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.spoken)
    }
}

/// Obstacles card wrapper, isolated into a leaf subview so 30 Hz depth frame updates
/// only re-evaluate this card rather than the Sense page scroll view.
private struct ObstaclesCard: View {
    /// Read only for `depth.report`.
    @Environment(AppModel.self) private var model

    /// The grid for the latest `LaneReport`.
    var body: some View {
        LaneGridView(report: model.depth.report)
    }
}

/// Live camera aim + depth rate, isolated into a leaf subview so 30 Hz updates do not
/// re-evaluate the surrounding Mount card toggles.
private struct MountAimRow: View {
    /// Read for `depth.report.cameraTiltDownDeg`, `depth.fps` and `lidarSupported`.
    @Environment(AppModel.self) private var model

    /// With a tilt reading: "<MountTilt status> · N fps" with a check (in the 3–8° window) or a
    /// warning glyph, one VoiceOver element. Without one on a LiDAR phone: how to get a reading.
    /// On a phone without LiDAR: nothing. The line itself is `MountTilt.status(downDeg:headCover:)` (`LaneMathTests.mountTiltStatus`, `LaneGeometryTests.mountTiltStatusSaysTooSteepForHeadCover`); `headCover` is the live grid's `headCoverage` (Step 51).
    var body: some View {
        if let tilt = model.depth.report.cameraTiltDownDeg {
            let headCover = model.depth.report.grid.headCoverage.contains(true)
            let s = MountTilt.status(downDeg: tilt, headCover: headCover)
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
