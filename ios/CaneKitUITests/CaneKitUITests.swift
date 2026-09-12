//
//  CaneKitUITests.swift
//  CaneKitUITests
//
//  Drives the real app in the simulator the way a person would: reads the guide, starts the
//  demo route, checks the instruction and distance appear, exercises Next / Recenter / Stop,
//  the haptic test buttons, the settings toggles, and VoiceOver labels. LiDAR, haptics and
//  the watch need a phone; everything else here runs on `make uitest`.
//
//  Verifies docs/design.md §6.1 (Guide controls) and the accessibility labels that AGENTS.md
//  rule 9 freezes. Every string literal passed to `app.buttons[...]`, `app.switches[...]`,
//  `app.otherElements[...]` or `app.staticTexts[...]` below is a ⚠ test contract: it is the
//  VoiceOver label in ios/CaneKit/UI (or AppModel / the route file) and must change in the
//  same commit as the UI string.
//
//  Target builds with SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated (XCTest is not
//  MainActor-friendly); see project.yml.
//

import XCTest

/// Functional XCUITests for the phone app (iPhone 17 Pro Max / iOS 27 simulator).
final class CaneKitUITests: XCTestCase {

    /// The app under test, relaunched fresh for every test.
    private var app: XCUIApplication!

    /// Launches the app with `CANEKIT_UITEST=1`, which makes `AppModel.start()` skip the location
    /// permission prompt so the system alert cannot race the first tap. Stops at the first failure.
    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["CANEKIT_UITEST"] = "1"
        app.launch()
    }

    /// Start → instruction shows waypoint 1 → Next → waypoint 2 → Repeat does not advance →
    /// Recenter → Stop → idle again with no Repeat.
    ///
    /// ⚠ test contract: buttons "Start route to CIF", "Stop route", "Next", "Repeat", "Recenter"
    /// (GuideCard); instruction texts containing "Townsend" / "Illinois Street" come from the
    /// `say` lines of CaneKit/Resources/route_isr_cif.json waypoints 1 and 2. Note waypoint 1's
    /// line already mentions "Illinois Street", so that wait alone does not prove Next advanced.
    func testGuideStartsAndStopsDemoRoute() {
        let start = app.buttons["Start route to CIF"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "Start button should be on the guide card")
        start.tap()

        // Route intro line becomes the instruction; the Stop button appears.
        let stop = app.buttons["Stop route"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'Townsend'")).firstMatch
            .waitForExistence(timeout: 5), "First waypoint line should show Townsend Hall")

        // Next skips to the second waypoint's line.
        app.buttons["Next"].tap()
        let illinois = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'Illinois Street'")).firstMatch
        XCTAssertTrue(illinois.waitForExistence(timeout: 5))

        // Repeat re-speaks; it must not advance the route.
        let repeatButton = app.buttons["Repeat"]
        XCTAssertTrue(repeatButton.exists, "Repeat is the recovery path for a cut-off crossing line")
        repeatButton.tap()
        XCTAssertTrue(illinois.exists, "Repeat must not change the instruction")

        app.buttons["Recenter"].tap()
        stop.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5), "Stop returns to the idle guide")
        XCTAssertFalse(app.buttons["Repeat"].exists, "No Repeat without a route")
    }

    /// "Where am I" with no VLM key must still answer gracefully: with no key the on-device
    /// describer is used, and in the simulator (no camera) it reports "camera …" or answers
    /// "Scene: …"; the button must come back.
    ///
    /// ⚠ test contract: button "Where am I" (GuideCard); the describer's no-key error text.
    /// Rule 4 of AGENTS.md: a missing key must never crash.
    func testWhereAmIWithoutKeyReportsGracefully() {
        let button = app.buttons["Where am I"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        // No key is needed any more (cloud → on-device fallback). In the simulator there is no
        // camera, so the describer must report that gracefully ("No camera frame") or answer, and
        // the button must come back — never hang, never crash.
        let msg = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'camera' OR label BEGINSWITH 'Scene:'")).firstMatch
        XCTAssertTrue(msg.waitForExistence(timeout: 8), "Where am I must answer or explain")
        XCTAssertTrue(app.buttons["Where am I"].waitForExistence(timeout: 5))
    }

    /// "Where am I" end to end with a real street scene: the app's camera is replaced by a Google
    /// Street View capture of the route (FrameReplay, simulator only) and the on-device describer
    /// (Apple Vision + Apple's on-device model or its template) must produce a sentence.
    /// Run with `make uitest-streetview` (passes TEST_RUNNER_CANEKIT_FRAME_DIR); skipped otherwise.
    /// The frames are local-only (git-ignored): capture them per ios/scripts/streetview/README.md.
    func testWhereAmIDescribesAStreetViewFrame() throws {
        guard let dir = ProcessInfo.processInfo.environment["CANEKIT_FRAME_DIR"], !dir.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_CANEKIT_FRAME_DIR to a folder with frames.json (make uitest-streetview)")
        }
        app.terminate()
        app.launchEnvironment["CANEKIT_FRAME_DIR"] = dir
        app.launch()
        let button = app.buttons["Where am I"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        let scene = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Scene:'")).firstMatch
        XCTAssertTrue(scene.waitForExistence(timeout: 45), "the on-device describer should answer from the Street View frame")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "where-am-i-streetview: \(scene.label)"
        shot.lifetime = .keepAlways
        add(shot)
        print("WHERE-AM-I: \(scene.label)")
    }

    /// Taps each haptic pattern test button, then toggles "Silence haptics" on and off.
    /// No haptic is asserted (the simulator has no Taptic Engine); this proves the controls exist
    /// and do not crash.
    ///
    /// ⚠ test contract: tab "Settings"; buttons "Test left haptic", "Test center haptic",
    /// "Test right haptic", "Test head haptic" and switch "Silence haptics" (HapticsCard).
    func testHapticTestButtonsAndSilenceToggle() {
        openTab("Settings")
        for name in ["Test left haptic", "Test center haptic", "Test right haptic", "Test head haptic"] {
            let b = app.buttons[name]
            XCTAssertTrue(b.waitForExistence(timeout: 10), name)
            b.tap()
        }
        let silence = app.switches["Silence haptics"]
        XCTAssertTrue(silence.waitForExistence(timeout: 5))
        silence.tap()
        silence.tap()
    }

    /// Flipping "Mirror left / right" changes the switch value; flips it back afterwards so the
    /// persisted setting is left as found.
    ///
    /// ⚠ test contract: tab "Settings"; switch "Mirror left / right" (Settings Mount card).
    func testMountTogglesPersist() {
        openTab("Settings")
        let mirror = app.switches["Mirror left / right"]
        XCTAssertTrue(mirror.waitForExistence(timeout: 10))
        let before = mirror.value as? String
        flip(mirror)
        XCTAssertTrue(waitUntil(timeout: 3) { (mirror.value as? String) != before },
                      "Toggle value should change after a tap")
        flip(mirror)   // restore
    }

    /// A SwiftUI `Toggle` is exposed as a switch whose centre is the *label*; tapping there does
    /// nothing. Tap the nested switch when there is one, else the knob at the trailing edge.
    /// Keep identical to `CaneKitVisualTour.flip(_:)`.
    private func flip(_ toggle: XCUIElement) {
        let knob = toggle.switches.firstMatch
        if knob.exists, knob != toggle {
            knob.tap()
        } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        }
    }

    /// Polls `condition` every 0.2 s (spinning the run loop) until it is true or `timeout` passes.
    /// - Returns: the condition's final value.
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    /// Spot-checks the VoiceOver tree across the three root tabs.
    ///
    /// ⚠ test contract: tabs "Guide", "Sense", "Settings"; button "Start route to CIF",
    /// element "Head row" (LaneGridView row label), button "Where am I",
    /// switch "Write trip log" (Settings Mount card).
    func testAccessibilityLabelsExist() {
        XCTAssertTrue(app.buttons["Guide"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Sense"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
        XCTAssertTrue(app.buttons["Start route to CIF"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Where am I"].exists)
        openTab("Sense")
        // Rows expose a combined spoken value ("left clear, center clear, right clear" or "no depth data").
        XCTAssertTrue(app.otherElements["Head row"].waitForExistence(timeout: 5))
        openTab("Settings")
        XCTAssertTrue(app.switches["Write trip log"].waitForExistence(timeout: 5))
    }

    /// Selects a root tab by its VoiceOver label (icon-only on screen).
    ///
    /// ⚠ test contract: `name` is one of "Guide", "Sense", "Settings" (`RootTab.title`).
    private func openTab(_ name: String) {
        let tab = app.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "tab \(name)")
        tab.tap()
    }

    /// "Navigate to CIF from here" is on the idle guide, enabled, and gives way to the route
    /// controls while a route runs. Not tapped: it would start GPS and an Apple Maps request.
    ///
    /// ⚠ test contract: button "Navigate to CIF from here" (GuideCard; its label is its text),
    /// "Start route to CIF", "Stop route".
    func testNavigateToCIFButtonIsOnTheIdleGuide() {
        let cif = app.buttons["Navigate to CIF from here"]
        XCTAssertTrue(cif.waitForExistence(timeout: 10), "CIF-from-here button should be on the idle guide")
        XCTAssertTrue(cif.isEnabled)
        app.buttons["Start route to CIF"].tap()
        XCTAssertTrue(app.buttons["Stop route"].waitForExistence(timeout: 10))
        XCTAssertFalse(cif.exists, "route controls replace the picker while navigating")
        app.buttons["Stop route"].tap()
        XCTAssertTrue(cif.waitForExistence(timeout: 10))
    }

    /// Tapping Go with an empty destination shows the error line instead of building a route.
    ///
    /// ⚠ test contract: button "Go" (GuideCard) and the exact static text
    /// "Type a destination first" (set by `AppModel.startMapKitRoute()`, shown by GuideCard).
    func testDestinationFieldRejectsEmptyQuery() {
        let go = app.buttons["Go"]
        XCTAssertTrue(go.waitForExistence(timeout: 10))
        go.tap()
        XCTAssertTrue(app.staticTexts["Type a destination first"].waitForExistence(timeout: 5))
    }

    /// Typing offers campus places straight away and clears a stale error line.
    ///
    /// The gazetteer half of the suggestion list needs no network and no GPS fix, so it is the
    /// half a simulator can prove: "Grainger" must offer the campus library as a VoiceOver button
    /// (MKLocalSearch's own answer for that word is an industrial supply store in another town).
    /// The row is not tapped: that would start a real Apple Maps route.
    ///
    /// ⚠ test contract: text field "Destination" and the suggestion row's VoiceOver label
    /// "<place>, campus place" (`DestinationSuggestion.voiceOverLabel`, CaneKitLogic).
    func testTypingOffersCampusSuggestionsAndClearsTheError() {
        let go = app.buttons["Go"]
        XCTAssertTrue(go.waitForExistence(timeout: 10))
        go.tap()                                     // empty → error line
        let error = app.staticTexts["Type a destination first"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))

        let field = app.textFields["Destination"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Grainger")

        // Match on the name and the kind, not on the whole sentence: the row legitimately gains a
        // detail line (and, with a GPS fix, a distance) a moment after it first appears, and
        // asserting the exact final string made this test a race. What the feature promises is
        // that the campus library is offered and is marked as a campus place — MKLocalSearch's own
        // answer for "Grainger" is an industrial supply store in another town.
        let campus = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@",
                        "Grainger Engineering Library", "campus place")).firstMatch
        XCTAssertTrue(campus.waitForExistence(timeout: 5), "campus places must be offered first")

        // …and offered FIRST: no other suggestion row may sit above it. Map rows carry a street
        // address, which is how they are told apart from the field and the buttons above.
        let mapRows = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Urbana, IL")).allElementsBoundByIndex
        for row in mapRows {
            XCTAssertGreaterThan(row.frame.origin.y, campus.frame.origin.y,
                                 "a map row must never rank above the campus place")
        }
        XCTAssertFalse(error.exists, "typing clears the previous attempt's error line")
    }

}
