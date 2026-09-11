//
//  CaneKitVisualTour.swift
//  CaneKitUITests
//
//  Not a pass/fail test so much as a camera: walks every screen state a person can reach in the
//  simulator (idle guide, navigating, after Next / Repeat / Recenter, haptics card, watch card,
//  scene card, stopped) and saves a PNG of each so the screens can be reviewed without a human
//  tapping. Run with
//    xcodebuild … -only-testing:CaneKitUITests/CaneKitVisualTour test TEST_RUNNER_CANEKIT_SHOTS=<dir>
//  Screenshots land in <dir> (and as attachments in the .xcresult either way).
//

import XCTest

final class CaneKitVisualTour: XCTestCase {

    private var app: XCUIApplication!
    private var shotIndex = 0

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchEnvironment["CANEKIT_UITEST"] = "1"
        app.launch()
    }

    func testTour() {
        XCTAssertTrue(app.buttons["Start demo route"].waitForExistence(timeout: 10))
        snap("idle-top")
        scrollDown(); snap("idle-middle")
        scrollDown(); snap("idle-bottom")
        scrollToTop()

        app.buttons["Start demo route"].tap()
        XCTAssertTrue(app.buttons["Stop route"].waitForExistence(timeout: 10))
        pause(1.5); snap("navigating")

        app.buttons["Repeat"].tap(); pause(0.5); snap("after-repeat")
        app.buttons["Next"].tap(); pause(1.0); snap("after-next")
        app.buttons["Recenter"].tap(); pause(0.5); snap("after-recenter")

        scrollDown(); snap("navigating-middle")
        scrollDown(); snap("navigating-bottom")
        scrollToTop()

        // Haptics card: every test button, then the silence toggle on and off.
        for name in ["Test left haptic", "Test center haptic", "Test right haptic", "Test head haptic"] {
            let b = app.buttons[name]
            if b.exists { b.tap(); pause(0.3) }
        }
        let silence = app.switches["Silence haptics"]
        if silence.exists {
            flip(silence); pause(0.5); snapElement(silence, "haptics-silenced")
            flip(silence); pause(0.3)
        }

        let whereAmI = app.buttons["Where am I"]
        if whereAmI.exists { whereAmI.tap(); pause(1.5); snapElement(whereAmI, "where-am-i-no-key") }

        scrollToTop()
        app.buttons["Stop route"].tap()
        XCTAssertTrue(app.buttons["Start demo route"].waitForExistence(timeout: 5))
        pause(0.5); snap("stopped")

        // Destination field: empty → error line; typed → route build attempt (no network in CI).
        app.buttons["Go"].tap(); pause(0.5); snap("go-empty")
    }

    // MARK: Helpers

    private func snap(_ name: String) {
        shotIndex += 1
        let png = XCUIScreen.main.screenshot().pngRepresentation
        save(png, name: String(format: "%02d-%@", shotIndex, name))
    }

    /// Scrolls the element into view first, then captures the whole screen.
    private func snapElement(_ element: XCUIElement, _ name: String) {
        if !element.isHittable { app.swipeUp() }
        snap(name)
    }

    private func save(_ png: Data, name: String) {
        if let dir = ProcessInfo.processInfo.environment["CANEKIT_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        let a = XCTAttachment(uniformTypeIdentifier: "public.png", name: name, payload: png)
        a.lifetime = .keepAlways
        add(a)
    }

    private func scrollDown() { app.swipeUp(); pause(0.4) }

    private func scrollToTop() {
        for _ in 0..<4 { app.swipeDown() }
        pause(0.4)
    }

    private func pause(_ s: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(s))
    }

    private func flip(_ toggle: XCUIElement) {
        let knob = toggle.switches.firstMatch
        if knob.exists, knob != toggle { knob.tap() }
        else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap() }
    }
}
