//
//  LiveView.swift
//  CaneKitLogic
//
//  The camera's frame rate and what the Hazards card's "Live camera view" shows.
//
//  Purpose: the live view is a GPU view of ARKit's own camera frames (`LiveCameraView` in the
//  app). Two rules with numbers decide it, so they live here with tests instead of inline in
//  SwiftUI: the camera runs 30 fps (60 with the Mount card's "60 fps camera" switch), and the view
//  renders at exactly that rate; and the view is paused while the phone is hot, because it is
//  optional and the obstacle lanes are not.
//  Owners: `DepthEngine.makeConfiguration` (video format fps) and `HazardsCard` (view state).
//
//  Key invariants:
//    · The view never renders faster than the camera delivers frames (a 60 Hz render of a
//      30 fps camera is heat for nothing).
//    · Hot beats running: the thermal pause hides the view even when ARKit is running.
//  Tests: LiveViewTests.swift.
//

import Foundation

/// The camera's video-format frame rate. `DepthEngine.makeConfiguration` picks the ARKit video
/// format with this rate; `LiveView.state` renders at it. Measured on the iPhone 17 Pro Max
/// (2026-09-11): world tracking with LiDAR offers the wide camera at up to 60 fps.
/// Pinned by `cameraFrameRateFollowsTheSwitch`.
public enum CameraRate {
    /// 60 with the Mount card's "60 fps camera (warmer)" switch, else 30.
    /// - Parameter highFrameRate: `DepthEngine.highFrameRate` (mirrors `AppModel.highFrameRateCamera`).
    public static func framesPerSecond(highFrameRate: Bool) -> Int { highFrameRate ? 60 : 30 }
}

/// What the Hazards card shows under its "Live camera view" switch. Called by `HazardsCard.body`
/// on every render; the enum is `Equatable` so tests can pin each case.
public enum LiveView: Equatable, Sendable {
    /// Switch off: nothing is built (no GPU view exists).
    case off
    /// Phone hot (thermal pause, `HazardScanner.paused`): a text line, no GPU view.
    case hot
    /// ARKit is not running (no LiDAR, backgrounded, or failed): a text line, no GPU view.
    case cameraOff
    /// The GPU camera view, rendered at `fps` (the camera's own frame rate).
    case live(fps: Int)

    /// Decide the live view from the switch, the thermal pause, the session state and the camera
    /// rate. Precedence: off → hot → cameraOff → live. Pinned by the `liveView…` tests.
    /// - Parameters:
    ///   - enabled: `AppModel.liveViewEnabled` (the card's switch; not persisted).
    ///   - hot: `HazardScanner.paused` (set by `AppModel.updateThermal` at `.serious` / `.critical`).
    ///   - cameraRunning: `DepthEngine.isRunning`.
    ///   - highFrameRate: `DepthEngine.highFrameRate`.
    public static func state(enabled: Bool, hot: Bool, cameraRunning: Bool, highFrameRate: Bool) -> LiveView {
        guard enabled else { return .off }
        if hot { return .hot }
        guard cameraRunning else { return .cameraOff }
        return .live(fps: CameraRate.framesPerSecond(highFrameRate: highFrameRate))
    }
}
