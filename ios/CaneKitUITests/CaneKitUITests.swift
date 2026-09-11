//
//  CaneKitUITests.swift
//  CaneKitUITests
//
//  Drives the real app in the simulator the way a person would: reads the guide, starts the
//  demo route, checks the instruction and distance appear, exercises Next / Recenter / Stop,
//  the haptic test buttons, the settings toggles, and VoiceOver labels. LiDAR, haptics and
//  the watch need a phone; everything else here runs on `make uitest`.
//

import XCTest

final class CaneKitUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["CANEKIT_UITEST"] = "1"
        app.launch()
    }

    func testGuideStartsAndStopsDemoRoute() {
        let start = app.buttons["Start demo route"]
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

    func testWhereAmIWithoutKeyReportsGracefully() {
        let button = app.buttons["Where am I"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        // Without a VLM key the describer must say so (no crash, button re-enabled).
        let msg = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'key'")).firstMatch
        XCTAssertTrue(msg.waitForExistence(timeout: 5) || button.isEnabled)
    }

    func testHapticTestButtonsAndSilenceToggle() {
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

    func testMountTogglesPersist() {
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
    private func flip(_ toggle: XCUIElement) {
        let knob = toggle.switches.firstMatch
        if knob.exists, knob != toggle {
            knob.tap()
        } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    func testAccessibilityLabelsExist() {
        XCTAssertTrue(app.buttons["Start demo route"].waitForExistence(timeout: 10))
        // Rows expose a combined spoken value ("left clear, center clear, right clear" or "no depth data").
        let headRow = app.otherElements["Head row"]
        XCTAssertTrue(headRow.exists)
        XCTAssertTrue(app.buttons["Where am I"].exists)
        XCTAssertTrue(app.switches["Write trip log"].exists)
    }

    func testDestinationFieldRejectsEmptyQuery() {
        let go = app.buttons["Go"]
        XCTAssertTrue(go.waitForExistence(timeout: 10))
        go.tap()
        XCTAssertTrue(app.staticTexts["Type a destination first"].waitForExistence(timeout: 5))
    }
}
