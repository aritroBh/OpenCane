//
//  GuideCard.swift
//  CaneKit
//
//  The Guide: what the blind user (via VoiceOver) and the sighted teammate both need first —
//  the current instruction, the distance, and the big buttons. Route picker underneath:
//  the recorded demo route or a typed MapKit destination.
//
//  Implements docs/design.md §6.1 (Guide: instruction, hero distance, bearing word, big
//  buttons), §6.3 (route picker, reduced to "Start route to CIF", "Navigate to CIF from here" and
//  a destination field — the field, its live suggestion list and "Go" live in
//  `DestinationField.swift`) and the
//  "Off-bearing > 25°" row of §5. Button titles differ from the §6.1 VoiceOver table on purpose
//  (short words that fit two-up on a 17 Pro Max); the XCUITests pin the shipped words.
//
//  Step 58 layout (voice shell): instruction → distance → pills → `VoiceTile` (the giant microphone,
//  ≥ 60 % of the page height) → the compact row (idle: Where am I | Start route to CIF; navigating:
//  Repeat | Next | Stop route) → describer text → everything else below the fold, labels unchanged.
//
//  Step 62 indoor state (`model.indoor.isActive`): the instruction shows the indoor step's line, a
//  status line "Indoors · step 3 of 5" follows it, the compact row is the navigating one (Repeat |
//  Next | Stop route — same labels, hard rule 9, routed to the indoor step by AppModel+Indoor's
//  hooks), and below the fold only Simulate walk / Stop simulation.
//
//  Accessibility contract — everything the XCUITests drive lives here (AGENTS.md rule 9):
//    ⚠ test contract buttons: "Start route to CIF", "Navigate to CIF from here", "Stop route",
//      "Repeat", "Next", "Recenter", "Where am I" (queried as `app.buttons[label]`); "Go" is in
//      `DestinationField`.
//    ⚠ test contract texts: the instruction `Text` must stay a plain static text whose label is
//      its content (tests match "Townsend" / "Illinois Street" from route_isr_cif.json); the
//      error line must stay a plain `Text` (tests match "Type a destination first" exactly); the
//      describer line under "Where am I" must stay plain static texts too
//      (testWhereAmIWithoutKeyReportsGracefully accepts a label containing "camera" or starting
//      "Scene:" — no key is needed any more, so nothing matches "key").
//  Focus order is the visual order: instruction → distance → pills → Talk to OpenCane (the tile) →
//  compact row → describer text → the rest of the route controls → error line.
//
//  Owner / caller: `GuidePage` in ContentView.swift, which passes its `ScrollViewProxy`.
//  Tests: `CaneKitUITests` — `testGuideStartsAndStopsDemoRoute`, `testWhereAmIWithoutKeyReportsGracefully`,
//  `testNavigateToCIFButtonIsOnTheIdleGuide`, `testDestinationFieldRejectsEmptyQuery` — and
//  `CaneKitVisualTour`. The 25° on-course and 15 m GPS thresholds here are display-only.
//

import CaneKitLogic
import SwiftUI

/// The Guide card: instruction, distance + bearing, GPS pill, "Where am I", and either the
/// navigation controls (while a route runs) or the route picker (idle / arrived).
///
/// Reads `AppModel` from the environment; owns no state except the Dynamic Type–scaled hero size.
struct GuideCard: View {
    /// App-wide owner of navigation, describer, beacon, audio route and location.
    @Environment(AppModel.self) private var model
    /// Hero distance size: 64 pt at default text size, scaled with `.largeTitle`, clamped to 80
    /// at the call site so the buttons are never pushed off-screen (design.md §1, §8).
    @ScaledMetric(relativeTo: .largeTitle) private var hero = 64
    /// Two-step gate for the destructive Stop route action; reset after its short confirmation
    /// window or whenever the route stops through another path.
    @State private var stopConfirmation = StopRouteConfirmation()
    /// The root scroll view's proxy, handed on to `DestinationField` so that focusing the search
    /// box scrolls the Guide card above the keyboard. nil in previews (then nothing scrolls).
    var scroller: ScrollViewProxy? = nil

    /// One `CKCard("Guide")`: instruction; distance + bearing (navigating or arrived, with a fix);
    /// GPS pills; the `VoiceTile` microphone with the assistant's last answer; the compact row
    /// (navigating: Repeat / Next / Stop route; idle: Where am I / Start route to CIF); the
    /// describer's result / error; then either the rest of the route controls (Recenter, beacon +
    /// head pills, Simulate walk) or the rest of the idle picker (Repeat after arrival, Cancel route
    /// start, Navigate to CIF from here, Simulate walk, the route-start status, `DestinationField`);
    /// last, the route / location error line.
    ///
    /// UI audit 2026-09-13: one tall card became a stack of focused pieces — a status card
    /// (instruction, distance, pills), the microphone and the compact row on the page ground, then
    /// a "Where to" card (idle: destination field first, then Navigate to CIF from here and
    /// Simulate walk) or a "Route tools" card (navigating / indoors). Labels, actions and the focus
    /// order are unchanged; only grouping and the order inside the idle picker moved.
    var body: some View {
        VStack(alignment: .leading, spacing: CKSpacing.lg) {
            statusCard
            voiceAndActions
            if model.nav.isNavigating || model.indoor.isActive {
                routeToolsCard
                errorLine
            } else {
                // Idle: the error line sits inside "Where to", right under the field that caused it.
                whereToCard
            }
        }
        .onChange(of: model.nav.isNavigating) { _, navigating in
            if !navigating { stopConfirmation.reset() }
        }
        .onChange(of: model.indoor.isActive) { _, active in
            if !active { stopConfirmation.reset() }
        }
    }

    /// "Guide" card: the instruction, the indoor step line, the distance row and the status pills.
    private var statusCard: some View {
        CKCard(title: "Guide", systemImage: "figure.walk") {
            // ⚠ test contract: plain Text whose accessibility label is the instruction itself.
            Text(model.indoor.isActive ? model.indoor.currentSay : model.nav.instruction)
                .font(CKFont.instruction)
                .foregroundStyle(CKColor.textPrimary)
                // Never truncate: the spotter reads this line over the walker's shoulder.
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits([.isHeader, .updatesFrequently])

            // Step 62: where the walker is in the indoor script; plain text, its label is its content.
            if model.indoor.isActive {
                Text(model.indoor.guideLine)
                    .font(CKFont.button)
                    .foregroundStyle(CKColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            // Distance row: only with a GPS-derived distance (never in the simulator without a fix).
            if let d = model.nav.distanceToNext, model.nav.isNavigating || model.nav.arrived {
                HStack(alignment: .firstTextBaseline, spacing: CKSpacing.sm) {
                    Text("\(d)")
                        .font(CKFont.hero(min(hero, 80)))
                        .foregroundStyle(CKColor.textPrimary)
                    Text("m").font(CKFont.button).foregroundStyle(CKColor.textSecondary)
                    Spacer()
                    if let err = model.nav.bearingError {
                        CKStatusPill(text: bearingWord(err), tone: abs(err) <= 25 ? .trusted : .warning,
                                     systemImage: abs(err) <= 25 ? "arrow.up" : (err > 0 ? "arrow.turn.up.right" : "arrow.turn.up.left"),
                                     spoken: "Heading: \(bearingWord(err))", updatesFrequently: true)
                    }
                }
                // One combined element with the explicit label "N meters to the next point".
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(d) meters to the next point")
            }

            HStack(spacing: CKSpacing.sm) {
                CKStatusPill(text: gpsWord, tone: gpsTone, systemImage: "location",
                             spoken: "GPS: \(gpsWord)", updatesFrequently: true)
                if model.nav.gpsWeak {
                    CKStatusPill(text: "GPS weak", tone: .warning, systemImage: "exclamationmark.triangle")
                }
                // Step 49: the light the cameras have, for the sighted spotter — the walker was
                // told once by voice ("Low light. Obstacle detection still works."). Warning, not
                // danger: LiDAR, GPS and haptics are unaffected; it is the camera features that
                // may miss things. Drawn only while `LowLightPolicy` says dark.
                if model.lightState == .dark {
                    CKStatusPill(text: "Dark", tone: .warning, systemImage: "moon.fill",
                                 spoken: "Low light; obstacle detection still works")
                }
            }
        }
    }

    /// The microphone, the compact row under it and the describer's result, on the page ground.
    @ViewBuilder private var voiceAndActions: some View {
        VStack(alignment: .leading, spacing: CKSpacing.md) {
            // Step 58: the voice shell's giant microphone. Its label is "Talk to OpenCane" /
            // "Listening…" / "Starting…" / "Thinking…"; the assistant's last answer
            // ("Assistant: …") is its status line.
            VoiceTile()

            // The compact row directly under the microphone — the only place the Guide puts three
            // buttons in a row (design.md §6.1 exception): tiles, so "Stop route" wraps instead of
            // hyphenating. ⚠ test contract: "Repeat", "Next", "Stop route" while navigating;
            // "Where am I" and "Start route to CIF" while idle. While describing, "Where am I"
            // becomes "Describing…" and is disabled; testWhereAmIWithoutKeyReportsGracefully relies
            // on it returning to "Where am I" and on the "camera" / "Scene:" static text below.
            // Step 62: the indoor leg uses the same row; next / repeat / stop reach the indoor step.
            if model.nav.isNavigating || model.indoor.isActive {
                HStack(alignment: .top, spacing: CKSpacing.sm) {
                    CKBigButton(title: "Repeat", systemImage: "arrow.counterclockwise", layout: .tile,
                                hint: "Says the current instruction again") { model.repeatInstruction() }
                    // `nextWaypoint()`, not `nav.next()`: one code path with the watch Next, the
                    // crown and Siri "Next waypoint in OpenCane".
                    CKBigButton(title: "Next", systemImage: "forward.fill", role: .secondary, layout: .tile,
                                hint: "Skips to the next instruction") { model.nextWaypoint() }
                    stopRouteButton
                }
                .fixedSize(horizontal: false, vertical: true)
                if stopConfirmation.isArmed {
                    Text("Tap Stop route again within 3 seconds to end guidance.")
                        .font(CKFont.secondary)
                        .foregroundStyle(CKColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Stop route is armed. Tap Stop route again within 3 seconds to end guidance.")
                }
            } else {
                HStack(alignment: .top, spacing: CKSpacing.md) {
                    CKBigButton(title: model.describer.isDescribing ? "Describing…" : "Where am I",
                                systemImage: "eye", role: .secondary, layout: .tile,
                                hint: "Takes a photo and reads out hazards and landmarks ahead",
                                value: model.describer.isDescribing ? "in progress" : nil) { model.describeScene() }
                        .disabled(model.describer.isDescribing)
                    // ⚠ test contract: "Start route to CIF" is the first thing every UI test waits for.
                    CKBigButton(title: "Start route to CIF", systemImage: "figure.walk", layout: .tile,
                                hint: "Starts the recorded ISR Townsend Hall to CIF route") { model.startDemoRoute() }
                        .disabled(model.routeStartWaiting)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if !model.describer.lastDescription.isEmpty {
                Text(model.describer.lastDescription)
                    .font(CKFont.body)
                    .foregroundStyle(CKColor.textPrimary)
                    .accessibilityLabel("Scene: \(model.describer.lastDescription)")
            }
            // Describer error, e.g. "No camera frame" (the no-key UI test accepts "camera" or "Scene:").
            if let err = model.describer.lastError {
                Text(err).font(CKFont.secondary).foregroundStyle(CKColor.laneUrgent)
            }
        }
    }

    /// "Route tools" card while a route (or the indoor leg) runs: Recenter, the beacon / headphone
    /// pills and Simulate walk; indoors only the step simulation.
    private var routeToolsCard: some View {
        CKCard(title: "Route tools", systemImage: "slider.horizontal.3") {
            if model.nav.isNavigating {
                // Repeat / Next / Stop route live in the compact row under the microphone (Step 58).
                // ⚠ test contract: "Recenter" (below the fold now: the tests `scrollTo` it).
                CKBigButton(title: "Recenter", systemImage: "location.north.line", role: .secondary,
                            hint: "Sets straight ahead as the beacon's forward direction") { model.recenter() }
                // Beacon pill: warning without headphones (the beacon cannot play), trusted while it
                // plays, neutral when off or idle. Head pill: warning without headphones.
                HStack(spacing: CKSpacing.sm) {
                    CKStatusPill(text: beaconWord, tone: !model.audioRoute.headphonesConnected ? .warning
                                 : (model.beacon.isRunning && model.beaconEnabled ? .trusted : .neutral),
                                 systemImage: "dot.radiowaves.left.and.right",
                                 spoken: "Beacon: \(beaconWord)", updatesFrequently: true)
                    CKStatusPill(text: headWord,
                                 tone: model.audioRoute.headphonesConnected ? .neutral : .warning,
                                 systemImage: "airpodspro",
                                 spoken: headSpoken)
                }
                if model.isSimulatingWalk {
                    CKBigButton(title: "Stop simulation", systemImage: "pause.circle.fill", role: .secondary,
                                hint: "Pauses the walk simulation") { model.stopSimulatedWalk() }
                } else {
                    CKBigButton(title: "Simulate walk", systemImage: "play.circle", role: .secondary,
                                hint: "Simulates walking along the active route indoors") { model.startSimulatedWalk() }
                }
            } else {
                // Step 62: indoors there is no beacon, recenter or route picker — only the step simulation.
                if model.indoor.isSimulating {
                    CKBigButton(title: "Stop simulation", systemImage: "pause.circle.fill", role: .secondary,
                                hint: "Pauses the indoor step simulation") { model.stopSimulatedWalk() }
                } else {
                    CKBigButton(title: "Simulate walk", systemImage: "play.circle", role: .secondary,
                                hint: "Simulates walking the indoor steps without moving") { model.startSimulatedWalk() }
                }
            }
        }
    }

    /// "Where to" card on the idle Guide. Order (owner request 2026-09-13): the destination field
    /// first, then Navigate to CIF from here, then Simulate walk.
    private var whereToCard: some View {
        CKCard(title: "Where to", systemImage: "mappin.and.ellipse") {
                if model.nav.arrived {
                    // The arrival line + trip summary are the longest of the walk: keep Repeat.
                    // ⚠ test contract: after a mid-route Stop `arrived` is false, so no Repeat
                    // (testGuideStartsAndStopsDemoRoute asserts it is gone).
                    CKBigButton(title: "Repeat", systemImage: "arrow.counterclockwise",
                                hint: "Says the arrival line again") { model.repeatInstruction() }
                }
                // While a route request waits for depth evidence after a camera transition
                // (`DepthReadiness` interlock): cancel it without the "Route stopped." of Stop.
                // Start route to CIF and Navigate to CIF are disabled meanwhile.
                if model.routeStartWaiting {
                    CKBigButton(title: "Cancel route start", systemImage: "xmark.circle",
                                role: .destructive,
                                hint: "Stops waiting for obstacle detection and does not start guidance") {
                        model.cancelRouteStart()
                    }
                }
                // Search box + live suggestions + "Go" (⚠ test contract: the "Go" button and the
                // "Destination" field live in DestinationField). First in the card (owner request).
                DestinationField(scroller: scroller)
                errorLine
                // ⚠ test contract: "Navigate to CIF from here" (its label is its text).
                CKBigButton(title: "Navigate to CIF from here",
                            subtitle: "Walking directions from where you are",
                            systemImage: "location.north.circle.fill",
                            role: .secondary,
                            hint: "Builds a walking route with Apple Maps from where you are to the CIF east entrance",
                            value: model.isBuildingRoute ? "finding a route" : nil) { model.navigateToCIFFromHere() }
                    .disabled(model.isBuildingRoute || model.routeStartWaiting)

                CKBigButton(title: "Simulate walk",
                            subtitle: "Demo: plays the route without moving",
                            systemImage: "play.circle.fill",
                            role: .secondary,
                            hint: "Simulates walking the demo route indoors step by step without moving") {
                    model.startSimulatedWalk()
                }
                .disabled(model.routeStartWaiting || model.isBuildingRoute)
                // Why a route has not started yet (waiting for depth, or timed out); not an error,
                // so primary text, spoken as written.
                if let status = model.routeStartStatus {
                    Text(status)
                        .font(CKFont.secondary)
                        .foregroundStyle(CKColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(status)
                }
        }
    }

    /// The route / location error line, under everything else.
    @ViewBuilder private var errorLine: some View {
            // ⚠ test contract: the error text itself stays a plain `Text` whose accessibility
            // label is its content ("Type a destination first"); the warning glyph beside it is
            // hidden from VoiceOver. Only shown after something actually failed — every keystroke
            // in the destination field clears `routeError`.
            if let err = model.routeError ?? model.location.lastError ?? model.liveActivity.lastError {
                HStack(alignment: .firstTextBaseline, spacing: CKSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(CKColor.danger)
                        .accessibilityHidden(true)
                    // `textPrimary`, not red text: red on the white light-mode card is 2.8:1
                    // (design.md §10). The glyph carries the alarm, the words carry the meaning.
                    Text(err)
                        .font(CKFont.secondary)
                        .foregroundStyle(CKColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, CKSpacing.xs)
            }
    }

    /// Stop route is deliberately a two-tap confirmation (Step 51a). The first tap gives a spoken and
    /// visible status (the armed line under the compact row); only a second tap inside
    /// `StopRouteConfirmation.window` ends guidance. A tile, because it sits in the compact row (Step 58).
    /// The button's VoiceOver label remains exactly "Stop route" (the XCUITest contract).
    private var stopRouteButton: some View {
        CKBigButton(title: "Stop route", systemImage: "stop.fill", role: .destructive, layout: .tile,
                    hint: stopConfirmation.isArmed
                        ? "Confirms ending guidance when tapped again within 3 seconds"
                        : "Arms route stop; tap again within 3 seconds to end guidance",
                    value: stopConfirmation.isArmed ? "confirmation needed" : nil) {
            stopRoutePressed()
        }
        .task(id: stopConfirmation.isArmed) {
            guard stopConfirmation.isArmed else { return }
            try? await Task.sleep(for: .seconds(StopRouteConfirmation.window))
            guard !Task.isCancelled else { return }
            stopConfirmation.reset()
        }
    }

    /// Handles one press of the two-step Stop route gate.
    private func stopRoutePressed() {
        switch stopConfirmation.press(at: ProcessInfo.processInfo.systemUptime) {
        case .armed:
            model.logger.event("route", ["action": "stop_armed"])
            model.speech.say(AppModel.stopRouteConfirmationLine, .nav, ttl: 4)
        case .confirmed:
            stopConfirmation.reset()
            model.stopRoute()
        }
    }

    /// Beacon pill word. First match wins: "Beacon off" (disabled in Mount) → "Beacon paused"
    /// (no headphones; the beacon only plays into headphones) → the engine error or
    /// "Beacon idle" → "Beacon N%" (current rendered volume).
    private var beaconWord: String {
        guard model.beaconEnabled else { return "Beacon off" }
        guard model.audioRoute.headphonesConnected else { return "Beacon paused" }
        guard model.beacon.isRunning else { return model.beacon.lastError ?? "Beacon idle" }
        return "Beacon \(Int(model.beacon.renderedVolume * 100))%"
    }

    /// No headphones → say so; AirPods motion flowing → head tracked; else compass only.
    private var headWord: String {
        guard model.audioRoute.headphonesConnected else { return "No AirPods" }
        return model.head.isConnected ? "Head tracked" : "Compass only"
    }

    /// VoiceOver sentence for the headphone pill: names the actual output device and whether
    /// head tracking is on, or says the beacon is paused with no headphones.
    private var headSpoken: String {
        guard model.audioRoute.headphonesConnected else { return "No headphones connected; beacon paused" }
        return model.head.isConnected ? "\(model.audioRoute.outputName), head tracking on"
                                      : "\(model.audioRoute.outputName), no head tracking"
    }

    /// Bearing pill word: "On course" within ±25° (design.md §5 "Off-bearing > 25°"), else
    /// "Veer right N°" / "Veer left N°" (positive error = target is to the right).
    private func bearingWord(_ err: Double) -> String {
        if abs(err) <= 25 { return "On course" }
        return err > 0 ? "Veer right \(Int(abs(err)))°" : "Veer left \(Int(abs(err)))°"
    }

    /// GPS pill word: "Denied" / "Searching" / "Off" without a fix, "No accuracy" for a fix
    /// with negative accuracy, else "±N m".
    private var gpsWord: String {
        guard let f = model.location.fix else {
            return model.location.denied ? "Denied" : (model.location.isRunning ? "Searching" : "Off")
        }
        return f.accuracy < 0 ? "No accuracy" : "±\(Int(f.accuracy)) m"
    }

    /// GPS pill tone: neutral without a valid fix, trusted at ≤ 15 m accuracy, warning above.
    private var gpsTone: CKStatusPill.Tone {
        guard let f = model.location.fix, f.accuracy >= 0 else { return .neutral }
        return f.accuracy <= 15 ? .trusted : .warning
    }
}
