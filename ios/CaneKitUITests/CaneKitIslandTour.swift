//
//  CaneKitIslandTour.swift
//  CaneKitUITests
//
//  A camera for the Live Activity: starts the demo route, sends the app to the background and
//  photographs the Dynamic Island in its compact presentation, long-presses it for the expanded
//  presentation, then stops the route and photographs the island again so a lingering activity is
//  visible. Saves PNGs like `CaneKitVisualTour` (`make island` → ios/build/shots/island-*).
//
//  Why it exists (Step 47): the Live Activity had no automated eye on it at all — CHANGELOG
//  Steps 8–9, 14, 20, 40, 42 and 44 all changed it and every one was verified by a person looking
//  at a phone. The owner reported the island "weird" three times while the trip log said
//  `live_activity {action: start, active: true}`; nobody could see what the widget actually drew.
//  The simulator renders Live Activities in the island of an iPhone 17 Pro Max, so a screenshot
//  from Springboard is evidence a reviewer can look at.
//
//  Not a pass/fail gate for the island's contents: it asserts only that the route starts and stops
//  (the same contract the other tests hold). Everything about the island is a picture; look at it.
//  `make uitest` runs it too (same target) — it must stay robust: `continueAfterFailure = true`,
//  every island interaction is best-effort.
//
//  ⚠ test contract (AGENTS.md rule 9): "Start route to CIF", "Stop route", "Simulate walk" (the
//  navigating variant, tapped only if present).
//  Prerequisites: simulator location set (`xcrun simctl location <udid> set 40.1140,-88.2249`),
//  `make sim-grant`. The simulator shows no system location indicator, so the blue background-
//  location pill the phone adds during a route is NOT in these pictures — see docs/design.md §6.7.
//

import XCTest

/// Screenshots of the navigation Live Activity in the Dynamic Island.
final class CaneKitIslandTour: XCTestCase {

    /// The app under test, launched fresh in `setUp`.
    private var app: XCUIApplication!
    /// Springboard, which owns the island once the app is in the background. Created in `setUp`
    /// (an inline default would be a main-actor value in a nonisolated context under Swift 6).
    private var springboard: XCUIApplication!
    /// Running shot counter, so the files sort in the order they were taken.
    private var shotIndex = 0

    /// Same launch as `CaneKitUITests` (`CANEKIT_UITEST=1` skips the location prompt and mutes).
    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchEnvironment["CANEKIT_UITEST"] = "1"
        app.launch()
        springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    }

    /// Route start → background → compact island → long-press → expanded island → foreground →
    /// simulated walk for a few seconds (distance changes, obstacle glance stays clear in the
    /// simulator) → background → compact again → foreground → Stop → background → after-stop.
    ///
    /// Shot names: island-compact, island-expanded, island-walking, island-after-stop.
    func testDynamicIsland() {
        XCTAssertTrue(app.buttons["Start route to CIF"].waitForExistence(timeout: 10))
        app.buttons["Start route to CIF"].tap()
        XCTAssertTrue(app.buttons["Stop route"].waitForExistence(timeout: 10))
        pause(2.0)

        // Compact presentation: the leading and trailing bubbles around the sensor cut-out.
        XCUIDevice.shared.press(.home)
        pause(2.5)
        snap("island-compact")

        // Expanded presentation: a long press on the island. Best-effort — if the island is not
        // there (Live Activities off, or no widget), the picture shows that too.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.035)).press(forDuration: 1.2)
        pause(1.2)
        snap("island-expanded")
        // Tap away to collapse it before going back to the app.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
        pause(0.8)

        // Walk a little so the distance and glyph change, then look again.
        app.activate()
        XCTAssertTrue(app.buttons["Stop route"].waitForExistence(timeout: 5))
        let simulate = app.buttons["Simulate walk"]
        if simulate.waitForExistence(timeout: 3) { simulate.tap() }
        pause(6.0)
        XCUIDevice.shared.press(.home)
        pause(2.5)
        snap("island-walking")

        // Stop the route and check the island afterwards: Stop ends the activity immediately
        // (`AppModel.stopRoute` → `end(immediate: true)`; only *arrival* keeps a card on the lock
        // screen for 60 s), so this picture should show no OpenCane activity at all.
        app.activate()
        XCTAssertTrue(app.buttons["Stop route"].waitForExistence(timeout: 5))
        app.buttons["Stop route"].tap()
        app.buttons["Stop route"].tap()
        XCTAssertTrue(app.buttons["Start route to CIF"].waitForExistence(timeout: 5))
        pause(1.0)
        XCUIDevice.shared.press(.home)
        pause(2.5)
        snap("island-after-stop")
        app.activate()
    }

    // MARK: Helpers (same shape as CaneKitVisualTour; kept local so the two tours stay independent)

    /// Captures the whole screen as "island-NN-<name>" and hands it to `save`.
    private func snap(_ name: String) {
        shotIndex += 1
        let png = XCUIScreen.main.screenshot().pngRepresentation
        save(png, name: String(format: "%02d-%@", shotIndex, name))
    }

    /// Writes `<name>.png` into `$CANEKIT_SHOTS` when set and always attaches it to the .xcresult.
    private func save(_ png: Data, name: String) {
        if let dir = ProcessInfo.processInfo.environment["CANEKIT_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        let a = XCTAttachment(uniformTypeIdentifier: "public.png", name: name, payload: png)
        a.lifetime = .keepAlways
        add(a)
    }

    /// Spins the run loop for `s` seconds so the island animation and ActivityKit settle.
    private func pause(_ s: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(s))
    }
}
