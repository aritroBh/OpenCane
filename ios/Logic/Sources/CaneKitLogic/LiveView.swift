//
//  LiveView.swift
//  CaneKitLogic
//
//  The camera's frame rate and what the Hazards card's two camera views show:
//    · `CameraRate` / `LiveView` — the ARKit-backed "Live camera view" (back camera only).
//    · `BothCameras` / `BothCamerasLayout` — the "Both cameras" mode, which shows the front and
//      back cameras together through `AVCaptureMultiCamSession` and **pauses ARKit** to do it.
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

    /// What the *preview* renders at, capped at 30 even when the camera runs at 60: a helper's
    /// picture must never cost the walker their obstacle warnings, and heat pauses those
    /// (Muse review of the live-view branch).
    public static let previewCap = 30
    public static func previewFramesPerSecond(highFrameRate: Bool) -> Int {
        min(previewCap, framesPerSecond(highFrameRate: highFrameRate))
    }
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
    /// - Parameter foreground: false while backgrounded or locked; ARKit is paused then and the
    ///   last frame would be a lie to a sighted helper (Muse review).
    public static func state(enabled: Bool, hot: Bool, cameraRunning: Bool, highFrameRate: Bool,
                             foreground: Bool = true) -> LiveView {
        guard foreground else { return .cameraOff }
        guard enabled else { return .off }
        if hot { return .hot }
        guard cameraRunning else { return .cameraOff }
        return .live(fps: CameraRate.previewFramesPerSecond(highFrameRate: highFrameRate))
    }
}

// MARK: - Both cameras (front + back at once)

/// What the Hazards card's "Both cameras (pauses obstacle detection)" switch shows.
///
/// Purpose: the owner wants to *see* the front and the back camera at the same time. ARKit cannot
/// do it — it delivers one camera image per frame and it is the rear one (Apple DTS, developer
/// forums 677731: "there is no ARConfiguration that will enable you to receive both the front and
/// rear camera image, so the functionality that you are looking for is not possible"; and
/// "you still must choose one camera feed to show to the user at a time") — so the app switches to an
/// `AVCaptureMultiCamSession` and **pauses ARKit** for the duration. Measured on the iPhone 17 Pro
/// Max (trip-log `probe_c_multicam`): with both pipelines running, multi-cam delivered 246 front
/// and 244 back frames while ARKit collapsed to 8 frames in the same 4 s window. That trade is a
/// safety decision, so the rules about when the mode may be on live here with tests rather than
/// inside a SwiftUI body.
///
/// Precedence, strictest first: not in the foreground → off; a route is running → blocked; the
/// switch is off → off; the phone cannot do multi-cam → `unsupported`; else `live`.
/// Tests: LiveViewTests.swift (`bothCameras…`).
public enum BothCameras: Equatable, Sendable {
    /// Nothing built, no cameras held, ARKit owns the camera as usual.
    case off
    /// Refused because guidance is running: the walker is *walking*, and the obstacle channel is
    /// not something a spotter's picture may switch off mid-route.
    case blockedByRoute
    /// This phone cannot run two cameras at once (`AVCaptureMultiCamSession.isMultiCamSupported`
    /// is false), so the two-camera view is not available: **no picture at all**, just a line of
    /// text saying so. ARKit is never paused on this path, so the obstacle channel is untouched and
    /// the separate "Live camera view" still shows the back camera from ARKit's own frames.
    /// ⚠ This case was called `backOnly` and was documented as "only the back camera is shown".
    /// Nothing ever showed a back camera here — `DualCameraSession.start()` returns before opening
    /// one and there is no single-camera fallback — and the card's caption promised a picture that
    /// could not appear. Rename it back only together with a fallback that really exists.
    case unsupported
    /// Front and back camera previews, both live. ARKit is paused.
    case live

    /// - Parameters:
    ///   - enabled: the card's switch (never persisted, so a launch can never start here).
    ///   - supported: `DualCameraSession.isSupported` (`AVCaptureMultiCamSession.isMultiCamSupported`).
    ///   - navigating: `NavigationEngine.isNavigating`.
    ///   - foreground: false while backgrounded or locked (the capture session is stopped then).
    public static func state(enabled: Bool, supported: Bool, navigating: Bool,
                             foreground: Bool = true) -> BothCameras {
        guard foreground else { return .off }
        if navigating { return enabled ? .blockedByRoute : .off }
        guard enabled else { return .off }
        return supported ? .live : .unsupported
    }
}

/// Geometry of the picture-in-picture inset in `BothCamerasView`.
/// Numbers, so they live here with a test instead of inside `layoutSubviews`.
public enum BothCamerasLayout {

    /// The front camera's inset takes this fraction of the view's width. A third is big enough to
    /// see a face on a phone screen and small enough to leave the back camera — the one that shows
    /// where the walker is going — clearly the main picture.
    public static let insetWidthFraction: Double = 0.33
    /// Points between the inset and the view's edges.
    public static let insetMargin: Double = 10
    /// Corner radius of the inset, matching the card's button radius.
    public static let insetCornerRadius: Double = 12
    /// The inset is drawn in the camera's portrait shape (a 4:3 sensor shown upright).
    public static let insetAspectWidthOverHeight: Double = 3.0 / 4.0

    /// Frame of the front-camera inset inside a view of `width` × `height`, bottom-trailing.
    /// - Returns: `(x, y, width, height)` in points. Clamped so the inset can never be taller than
    ///   the view: a short preview box would otherwise push it off the top edge.
    public static func insetRect(width: Double, height: Double)
        -> (x: Double, y: Double, width: Double, height: Double) {
        var w = width * insetWidthFraction
        var h = w / insetAspectWidthOverHeight
        let maxHeight = max(0, height - 2 * insetMargin)
        if h > maxHeight {
            h = maxHeight
            w = h * insetAspectWidthOverHeight
        }
        return (x: width - w - insetMargin, y: height - h - insetMargin, width: w, height: h)
    }
}
