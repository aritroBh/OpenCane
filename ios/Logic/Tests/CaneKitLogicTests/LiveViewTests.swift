//
//  LiveViewTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins LiveView.swift — the camera's frame rate (30, or 60 with the Mount card's
//  "60 fps camera" switch) and what the Hazards card's "Live camera view" shows: nothing when the
//  switch is off, a paused line while the phone is hot (the view is optional, the lanes are not),
//  a "camera off" line while ARKit is not running, else the GPU view at the camera's rate.
//
//  Key invariants: the view never renders faster than the camera delivers frames (a 60 Hz
//  render of a 30 fps camera only adds heat), and hot always wins over running.
//

import Testing
@testable import CaneKitLogic

/// The camera runs 30 fps by default and 60 only with the Mount card switch; `DepthEngine`
/// picks its video format from this number and the live view renders at it.
@Test func cameraFrameRateFollowsTheSwitch() {
    #expect(CameraRate.framesPerSecond(highFrameRate: false) == 30)
    #expect(CameraRate.framesPerSecond(highFrameRate: true) == 60)
}

/// Switch off → nothing is built (no GPU view exists, so it costs nothing).
@Test func liveViewOffBuildsNothing() {
    for hot in [false, true] {
        for running in [false, true] {
            #expect(LiveView.state(enabled: false, hot: hot, cameraRunning: running, highFrameRate: true) == .off)
        }
    }
}

/// Hot (thermal `.serious` / `.critical`): the view is paused even with the camera running, as
/// the old ~3 Hz JPEG view stopped updating while hot (docs/design.md thermal row).
@Test func liveViewPausesWhileHot() {
    #expect(LiveView.state(enabled: true, hot: true, cameraRunning: true, highFrameRate: false) == .hot)
    #expect(LiveView.state(enabled: true, hot: true, cameraRunning: false, highFrameRate: true) == .hot)
}

/// ARKit not running (never started on a phone without LiDAR, paused in the background, or failed):
/// a text line instead of a black box.
@Test func liveViewCameraOffWhenSessionNotRunning() {
    #expect(LiveView.state(enabled: true, hot: false, cameraRunning: false, highFrameRate: false) == .cameraOff)
}

/// Running and cool: the GPU view, capped at 30 fps even when the camera runs at 60 — a helper's
/// preview must never add the heat that pauses the walker's obstacle warnings (Muse review).
@Test func liveViewRendersAtMostThirtyFramesPerSecond() {
    #expect(LiveView.state(enabled: true, hot: false, cameraRunning: true, highFrameRate: false) == .live(fps: 30))
    #expect(LiveView.state(enabled: true, hot: false, cameraRunning: true, highFrameRate: true) == .live(fps: 30))
    #expect(CameraRate.framesPerSecond(highFrameRate: true) == 60)      // the camera still runs at 60
}

/// Backgrounded or locked: ARKit is paused, so show "Camera off", never a frozen frame.
@Test func liveViewIsOffInTheBackground() {
    #expect(LiveView.state(enabled: true, hot: false, cameraRunning: true, highFrameRate: false,
                           foreground: false) == .cameraOff)
}

// MARK: - Both cameras (front + back at once)

/// Off by default in every combination: the mode that pauses obstacle detection must never be
/// reachable without the switch. (During a route the switch-off state is `.blockedByRoute`, a
/// caption only — see `bothCamerasExplainTheRefusalForTheWholeRoute`; it never goes `.live`.)
@Test func bothCamerasOffWithTheSwitchOff() {
    for supported in [false, true] {
        #expect(BothCameras.state(enabled: false, supported: supported, navigating: false) == .off)
        #expect(BothCameras.state(enabled: false, supported: supported, navigating: true) != .live)
    }
}

/// ⚠ Measured break (trip log 2026-09-12T20-57-17Z, t = 84–87 s): a voice command had started a
/// route, the owner pressed "Both cameras" four times, and each press was refused — correctly —
/// but `AppModel.setBothCameras` snaps the switch back to off at once, and this state used to
/// return `.off` for (switch off, navigating), so the "cannot run while a route is guiding you"
/// caption was never on screen. The switch just bounced. The reason must stay visible for as long
/// as it is true: the whole route, whatever the switch shows.
@Test func bothCamerasExplainTheRefusalForTheWholeRoute() {
    #expect(BothCameras.state(enabled: false, supported: true, navigating: true) == .blockedByRoute)
    #expect(BothCameras.state(enabled: false, supported: false, navigating: true) == .blockedByRoute)
}

/// A route beats the picture. A walking blind user does not lose obstacle warnings so a spotter
/// can see a selfie feed. ⚠ Do not relax this without the owner's explicit decision.
@Test func bothCamerasAreRefusedWhileARouteIsGuiding() {
    #expect(BothCameras.state(enabled: true, supported: true, navigating: true) == .blockedByRoute)
}

/// Backgrounded or locked beats everything: the capture session is stopped then, so showing a
/// frozen pair of frames would be a lie (the same rule `LiveView` follows).
@Test func bothCamerasAreOffInTheBackground() {
    #expect(BothCameras.state(enabled: true, supported: true, navigating: false,
                              foreground: false) == .off)
    #expect(BothCameras.state(enabled: true, supported: true, navigating: true,
                              foreground: false) == .off)
}

/// A phone without `AVCaptureMultiCamSession` gets an honest refusal and no picture — it never
/// shows one feed as though it were two, and it never promises a back-camera fallback that the
/// app does not implement (`DualCameraSession.start()` opens no camera on this path).
@Test func bothCamerasRefuseWithoutMultiCamSupport() {
    #expect(BothCameras.state(enabled: true, supported: false, navigating: false) == .unsupported)
}

/// The normal case: switch on, multi-cam available, no route → both pictures.
@Test func bothCamerasGoLiveWhenNothingIsWalking() {
    #expect(BothCameras.state(enabled: true, supported: true, navigating: false) == .live)
}

/// The inset is a third of the width, in the camera's portrait shape, tucked into the
/// bottom-trailing corner with a 10 pt margin.
@Test func bothCamerasInsetSitsInTheBottomTrailingCorner() {
    let r = BothCamerasLayout.insetRect(width: 300, height: 400)
    #expect(abs(r.width - 99) < 0.001)                       // 300 × 0.33
    #expect(abs(r.height - 132) < 0.001)                     // 99 ÷ (3/4)
    #expect(abs(r.x - (300 - 99 - 10)) < 0.001)
    #expect(abs(r.y - (400 - 132 - 10)) < 0.001)
}

/// A short preview box clamps the inset instead of pushing it off the top edge.
@Test func bothCamerasInsetIsClampedInAShortBox() {
    let r = BothCamerasLayout.insetRect(width: 300, height: 60)
    #expect(r.height <= 60 - 2 * BothCamerasLayout.insetMargin + 0.001)
    #expect(r.y >= BothCamerasLayout.insetMargin - 0.001)
    #expect(abs(r.width / r.height - BothCamerasLayout.insetAspectWidthOverHeight) < 0.001)
}

// MARK: - Face tracking change (front-camera head tracking re-runs the AR session)

/// No route: the change applies (on or off).
@Test func faceTrackingChangeAppliesWhenNoRouteIsActive() {
    #expect(FaceTrackingChange.decide(navigating: false, routeStartWaiting: false) == .apply)
}

/// ⚠ Measured (trip log 2026-09-12T20-57-17Z, t = 80.7 s): "Head tracking without AirPods" was
/// switched on mid-route. `DepthEngine.setFaceTracking` pauses and re-runs the AR session, which
/// is ~1–2 s with no obstacle frames while a blind walker is being guided. Either direction
/// re-runs the session, so both are refused, exactly like the two-camera mode.
@Test func faceTrackingChangeIsRefusedWhileARouteIsGuiding() {
    #expect(FaceTrackingChange.decide(navigating: true, routeStartWaiting: false) == .refusedRoute)
}

/// While a route waits for obstacle detection, a re-run would reset `DepthReadiness` and push the
/// start back; refuse with the route-start reason.
@Test func faceTrackingChangeIsRefusedWhileARouteIsStarting() {
    #expect(FaceTrackingChange.decide(navigating: false, routeStartWaiting: true) == .refusedRouteStart)
}

/// Guiding wins over starting when both are somehow true (the guiding reason is the one to fix).
@Test func faceTrackingRouteRefusalTakesPrecedence() {
    #expect(FaceTrackingChange.decide(navigating: true, routeStartWaiting: true) == .refusedRoute)
}
