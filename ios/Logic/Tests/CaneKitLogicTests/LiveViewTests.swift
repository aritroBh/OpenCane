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

/// Running and cool: the GPU view, rendered at exactly the camera's frame rate.
@Test func liveViewRendersAtTheCameraRate() {
    #expect(LiveView.state(enabled: true, hot: false, cameraRunning: true, highFrameRate: false) == .live(fps: 30))
    #expect(LiveView.state(enabled: true, hot: false, cameraRunning: true, highFrameRate: true) == .live(fps: 60))
}
