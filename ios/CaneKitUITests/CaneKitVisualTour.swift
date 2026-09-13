//
//  CaneKitVisualTour.swift
//  CaneKitUITests
//
//  Not a pass/fail test so much as a camera: walks every screen state a person can reach in the
//  simulator (idle Guide, navigating, after Repeat / Next / Recenter, "Where am I" with no camera,
//  the Sense page, the Settings page with the haptic tests and "Silence haptics", stopped, and Go
//  with an empty destination) and saves a PNG of each so the screens can be reviewed without a
//  human tapping. Run with `make tour`, which is
//    TEST_RUNNER_CANEKIT_SHOTS=<dir> xcodebuild … -only-testing:CaneKitUITests/CaneKitVisualTour test
//  Screenshots land in <dir> (and as attachments in the .xcresult either way). `make uitest` also
//  runs it (it is in the same target), without writing PNGs.
//
//  Why it exists: a layout bug no assertion can see is caught only by looking (Step 27: the new
//  tab bar filled most of the screen and still passed every label check). Look at the PNGs.
//  Prerequisites are the same as CaneKitUITests (simulator location set, `make sim-grant`).
//  States the simulator cannot reach — arrival, live LiDAR tiles, a real camera frame — are not
//  in the tour.
//
//  Covers the screens of docs/design.md §6 for visual review (`make tour` → ios/build/shots).
//  It reaches every control through the same VoiceOver labels as CaneKitUITests, so the ⚠ test
//  contract strings there apply here too: "Guide" / "Sense" / "Settings" / "Profile" tabs, "Start route to CIF",
//  "Stop route", "Repeat", "Next", "Recenter", "Test left/center/right/head haptic",
//  "Silence haptics", "Where am I", "Go".
//

import XCTest

/// Screenshot tour of the phone app. `continueAfterFailure = true` so one missing control does
/// not cost the rest of the shots; optional controls are tapped only if they exist.
final class CaneKitVisualTour: XCTestCase {

    /// The app under test, launched fresh in `setUp`.
    private var app: XCUIApplication!
    /// Running shot counter; prefixes file names ("01-idle-top", "02-…") so they sort in order.
    private var shotIndex = 0

    /// Same launch as CaneKitUITests (`CANEKIT_UITEST=1` skips the location prompt), but keeps
    /// going after a failure.
    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchEnvironment["CANEKIT_UITEST"] = "1"
        app.launch()
    }

    /// The whole tour, in order: idle Guide, navigating, after Repeat / Next / Recenter,
    /// "Where am I" without a key, Sense page, Settings (haptic tests + silence), stopped,
    /// and Go with an empty destination.
    ///
    /// Shot names, in order: idle-top, idle-middle, idle-bottom, navigating, after-repeat,
    /// after-next, after-recenter, navigating-middle, navigating-bottom, where-am-i-no-key (only if
    /// the button exists), sense-top, sense-bottom, settings-top, haptics-silenced (only if the
    /// switch exists), settings-bottom, stopped, go-empty — each prefixed "NN-" by `snap`. The
    /// route is still running while Sense and Settings are shot; the tour returns to Guide to Stop.
    ///
    /// ⚠ test contract: every `app.buttons[...]` / `app.switches[...]` label used below.
    func testTour() {
        XCTAssertTrue(app.buttons["Start route to CIF"].waitForExistence(timeout: 10))
        snap("idle-top")
        scrollDown(); snap("idle-middle")
        scrollDown(); snap("idle-bottom")
        scrollToTop()

        app.buttons["Start route to CIF"].tap()
        XCTAssertTrue(app.buttons["Stop route"].waitForExistence(timeout: 10))
        pause(1.5); snap("navigating")

        app.buttons["Repeat"].tap(); pause(0.5); snap("after-repeat")
        app.buttons["Next"].tap(); pause(1.0); snap("after-next")
        scrollTo(app.buttons["Recenter"]).tap(); pause(0.5); snap("after-recenter")

        scrollDown(); snap("navigating-middle")
        scrollDown(); snap("navigating-bottom")
        scrollToTop()

        let whereAmI = app.buttons["Where am I"]
        if whereAmI.exists { whereAmI.tap(); pause(1.5); snapElement(whereAmI, "where-am-i-no-key") }

        // Sense page: depth status + obstacle grid + hazards.
        openTab("Sense")
        pause(0.4); snap("sense-top")
        scrollDown(); snap("sense-bottom")

        // Settings page: haptics, watch, mount. Haptic test buttons live here now.
        openTab("Settings")
        pause(0.4); snap("settings-top")
        for name in ["Test left haptic", "Test center haptic", "Test right haptic", "Test head haptic"] {
            let b = app.buttons[name]
            if b.exists { b.tap(); pause(0.3) }
        }
        let silence = app.switches["Silence haptics"]
        if silence.exists {
            flip(silence); pause(0.5); snapElement(silence, "haptics-silenced")
            flip(silence); pause(0.3)
        }
        scrollDown(); snap("settings-bottom")

        openTab("Guide")
        XCTAssertTrue(app.buttons["Stop route"].waitForExistence(timeout: 5))
        scrollTo(app.buttons["Stop route"]).tap()
        app.buttons["Stop route"].tap()
        XCTAssertTrue(app.buttons["Start route to CIF"].waitForExistence(timeout: 5))
        pause(0.5); snap("stopped")

        // Destination field: empty → error line; typed → route build attempt (no network in CI).
        scrollTo(app.buttons["Go"]).tap(); pause(0.5); snap("go-empty")
    }

    /// Selects a root tab by its VoiceOver label (icon-only on screen). Unlike the
    /// `CaneKitUITests` copy it does not assert: a missing tab skips the tap and the tour goes on.
    ///
    /// ⚠ test contract: `name` is one of "Guide", "Sense", "Settings", "Profile" (`RootTab.title`).
    private func openTab(_ name: String) {
        let tab = app.buttons[name]
        if tab.waitForExistence(timeout: 5) { tab.tap() }
    }

    // MARK: Helpers

    /// Captures the full screen as "<NN>-<name>" (two-digit running `shotIndex`) and hands it to
    /// `save`.
    private func snap(_ name: String) {
        shotIndex += 1
        let png = XCUIScreen.main.screenshot().pngRepresentation
        save(png, name: String(format: "%02d-%@", shotIndex, name))
    }

    /// Swipes up once if the element is not hittable (a rough scroll-into-view, not a loop), then
    /// captures the whole screen.
    private func snapElement(_ element: XCUIElement, _ name: String) {
        if !element.isHittable { app.swipeUp() }
        snap(name)
    }

    /// Writes `<name>.png` into `$CANEKIT_SHOTS` when set (xcodebuild strips the `TEST_RUNNER_`
    /// prefix), and always attaches the PNG to the .xcresult with `keepAlways` lifetime. A write
    /// failure (missing folder) is ignored: `make tour` creates the folder first.
    private func save(_ png: Data, name: String) {
        if let dir = ProcessInfo.processInfo.environment["CANEKIT_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        let a = XCTAttachment(uniformTypeIdentifier: "public.png", name: name, payload: png)
        a.lifetime = .keepAlways
        add(a)
    }

    /// Swipes until `element` is hittable: up to four swipes up, then up to eight down. Step 58's
    /// voice tile fills the top of the Guide, so route controls start below the fold (and one
    /// swipe too many can push the compact row above it). Returns the element for chaining.
    @discardableResult
    private func scrollTo(_ element: XCUIElement) -> XCUIElement {
        var ups = 0
        while ups < 4, !(element.exists && element.isHittable) { app.swipeUp(); ups += 1 }
        var downs = 0
        while downs < 8, !(element.exists && element.isHittable) { app.swipeDown(); downs += 1 }
        return element
    }

    /// One swipe up plus a short settle.
    private func scrollDown() { app.swipeUp(); pause(0.4) }

    /// Four swipes down to get back to the top of the scroll view, plus a short settle. No check
    /// that the top was reached: a page that grows much longer may need more swipes.
    private func scrollToTop() {
        for _ in 0..<4 { app.swipeDown() }
        pause(0.4)
    }

    /// Spins the run loop for `s` seconds so animations and speech-driven UI settle.
    private func pause(_ s: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(s))
    }

    /// Toggle tap helper; keep identical to `CaneKitUITests.flip(_:)` (tap the nested switch,
    /// else the knob at the trailing edge — the toggle's centre is its label).
    private func flip(_ toggle: XCUIElement) {
        let knob = toggle.switches.firstMatch
        if knob.exists, knob != toggle { knob.tap() }
        else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap() }
    }
}
