//
//  GuideCard.swift
//  CaneKit
//
//  The Guide: what the blind user (via VoiceOver) and the sighted teammate both need first —
//  the current instruction, the distance, and the big buttons. Route picker underneath:
//  the recorded demo route or a typed MapKit destination.
//
//  Implements docs/design.md §6.1 (Guide: instruction, hero distance, bearing word, big
//  buttons), §6.3 (route picker, reduced to "Start demo route", "Navigate to CIF from here" and
//  a destination field — the field, its live suggestion list and "Go" live in
//  `DestinationField.swift`) and the
//  "Off-bearing > 25°" row of §5. Button titles differ from the §6.1 VoiceOver table on purpose
//  (short words that fit two-up on a 17 Pro Max); the XCUITests pin the shipped words.
//
//  Accessibility contract — everything the XCUITests drive lives here (AGENTS.md rule 9):
//    ⚠ test contract buttons: "Start demo route", "Navigate to CIF from here", "Stop route",
//      "Repeat", "Next", "Recenter", "Where am I" (queried as `app.buttons[label]`); "Go" is in
//      `DestinationField`.
//    ⚠ test contract texts: the instruction `Text` must stay a plain static text whose label is
//      its content (tests match "Townsend" / "Illinois Street" from route_isr_cif.json); the
//      error line must stay a plain `Text` (tests match "Type a destination first" exactly and
//      a describer error containing "key").
//  Focus order is the visual order: instruction → distance → pills → Where am I → route buttons.
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
    /// The root scroll view's proxy, handed on to `DestinationField` so that focusing the search
    /// box scrolls the Guide card above the keyboard. nil in previews (then nothing scrolls).
    var scroller: ScrollViewProxy? = nil

    var body: some View {
        @Bindable var model = model
        CKCard(title: "Guide") {
            // ⚠ test contract: plain Text whose accessibility label is the instruction itself.
            Text(model.nav.instruction)
                .font(CKFont.instruction)
                .foregroundStyle(CKColor.textPrimary)
                // Never truncate: the spotter reads this line over the walker's shoulder.
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits([.isHeader, .updatesFrequently])

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
            }

            // ⚠ test contract: "Where am I". While describing, the label becomes "Describing…"
            // and the button is disabled; testWhereAmIWithoutKeyReportsGracefully relies on it
            // returning to "Where am I" (enabled) or an error line containing "key".
            CKBigButton(title: model.describer.isDescribing ? "Describing…" : "Where am I",
                        systemImage: "eye", role: .secondary,
                        hint: "Takes a photo and reads out hazards and landmarks ahead",
                        value: model.describer.isDescribing ? "in progress" : nil) { model.describeScene() }
                .disabled(model.describer.isDescribing)
            if !model.describer.lastDescription.isEmpty {
                Text(model.describer.lastDescription)
                    .font(CKFont.body)
                    .foregroundStyle(CKColor.textPrimary)
                    .accessibilityLabel("Scene: \(model.describer.lastDescription)")
            }
            // Describer error, e.g. "Camera warming up" (the no-key UI test accepts "camera" or "Scene:").
            if let err = model.describer.lastError {
                Text(err).font(CKFont.secondary).foregroundStyle(CKColor.laneUrgent)
            }

            if model.nav.isNavigating {
                // Two per row: three-up hyphenates "Recenter" on a 17 Pro Max at default type size.
                // ⚠ test contract: "Repeat", "Next", "Recenter", "Stop route".
                HStack(spacing: CKSpacing.lg) {
                    CKBigButton(title: "Repeat", systemImage: "arrow.counterclockwise",
                                hint: "Says the current instruction again") { model.repeatInstruction() }
                    // `nextWaypoint()`, not `nav.next()`: one code path with the watch Next, the
                    // crown and Siri "Next waypoint in OpenCane".
                    CKBigButton(title: "Next", systemImage: "forward.fill", role: .secondary,
                                hint: "Skips to the next instruction") { model.nextWaypoint() }
                }
                CKBigButton(title: "Recenter", systemImage: "location.north.line", role: .secondary,
                            hint: "Sets straight ahead as the beacon's forward direction") { model.recenter() }
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
                CKBigButton(title: "Stop route", systemImage: "stop.fill", role: .destructive,
                            hint: "Ends guidance") { model.stopRoute() }
            } else {
                if model.nav.arrived {
                    // The arrival line + trip summary are the longest of the walk: keep Repeat.
                    // ⚠ test contract: after a mid-route Stop `arrived` is false, so no Repeat
                    // (testGuideStartsAndStopsDemoRoute asserts it is gone).
                    CKBigButton(title: "Repeat", systemImage: "arrow.counterclockwise",
                                hint: "Says the arrival line again") { model.repeatInstruction() }
                }
                // ⚠ test contract: "Start demo route" is the first thing every UI test waits for.
                CKBigButton(title: "Start demo route", systemImage: "figure.walk",
                            hint: "Starts the recorded ISR Townsend Hall to CIF route") { model.startDemoRoute() }
                // Apple Maps walking directions from the live GPS fix to the CIF east entrance,
                // for when the walker is not at ISR. Label = its text (CKBigButton).
                CKBigButton(title: "Navigate to CIF from here", systemImage: "location.north.circle",
                            role: .secondary,
                            hint: "Builds a walking route with Apple Maps from where you are to the CIF east entrance",
                            value: model.isBuildingRoute ? "finding a route" : nil) { model.navigateToCIFFromHere() }
                    .disabled(model.isBuildingRoute)
                // Search box + live suggestions + "Go" (⚠ test contract: the "Go" button and the
                // "Destination" field live in DestinationField now).
                DestinationField(scroller: scroller)
            }
            // ⚠ test contract: the error text itself stays a plain `Text` whose accessibility
            // label is its content ("Type a destination first"); the warning glyph beside it is
            // hidden from VoiceOver. Only shown after something actually failed — every keystroke
            // in the destination field clears `routeError`.
            if let err = model.routeError ?? model.location.lastError {
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
            }
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
