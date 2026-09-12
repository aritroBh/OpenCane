//
//  MultiCamDepth.swift
//  CaneKitLogic
//
//  Could a future CaneKit show the front and the back camera at once **and keep LiDAR depth**?
//
//  Why this question has its own file. Today "Both cameras" pauses ARKit, because ARKit can never
//  hand the app two camera images (Apple DTS, developer forums thread 677731: "There can only be
//  one running capture session at a time, ARKit requires a running capture session, and there is
//  no ARConfiguration that will enable you to receive both the front and rear camera image, so the
//  functionality that you are looking for is not possible" — and `ARFrame` structurally has exactly
//  one `capturedImage`). Losing obstacle detection to see a selfie feed is a bad trade, so the
//  obvious follow-up is whether **AVFoundation** could deliver both pictures *plus* depth, leaving
//  the safety channel alive. Two pieces of published evidence say it might:
//    · Apple DTS, forums thread 702875, blesses `builtInLiDARDepthCamera` inside an
//      `AVCaptureMultiCamSession`.
//    · WWDC22 session 110429 ("Discover advancements in iOS camera capture") states AVFoundation
//      streams LiDAR depth at up to 320×240 — higher than ARKit's 256×192 `sceneDepth`.
//  Both are claims about *other people's* devices. AGENTS.md ("How we engineer", rule 1) does not
//  allow shipping a plan on a claim, so `MultiCamDepthProbe` (app target) measures this phone's
//  `AVCaptureDevice.DiscoverySession.supportedMultiCamDeviceSets` and format lists, and this file
//  turns the measurement into the *answer*, with tests, instead of leaving a pile of numbers in a
//  log for someone to interpret later.
//
//  This decides nothing at run time: no feature reads the verdict. It exists so the trip log from a
//  real walk contains a defensible yes/no for the next person who asks.
//
//  Key invariants:
//    · "Supported" needs a *pairing*: a multi-cam device set containing a front camera and a
//      depth-capable back camera. A depth-capable format that can never be paired with the front
//      camera answers nothing.
//    · Depth resolution is compared against ARKit's own `sceneDepth` (256×192) by pixel count, so
//      "higher than ARKit" is a measured comparison and not a recollection of a slide.
//    · `MultiCamCost` (bottom of the file) is the one part that *does* run: `DualCameraSession`
//      asks it whether the two-camera session is over its hardware budget.
//
//  Owners / callers: `MultiCamDepthProbe.measure()` (app, `ios/CaneKit/Depth/`, nonisolated) fills
//  `MultiCamDepthFindings`; `AppModel.logMultiCamDepthProbe()` runs it detached once per launch and
//  writes one `multicam_depth` trip-log record (`verdict`, `keeps_depth`, `answer`, …).
//  `DualCameraSession.reduceFrameRateIfOverBudget(_:)` reads `MultiCamCost`.
//  Isolation: the package has no default actor isolation, so every type here is nonisolated and
//  `Sendable`; the probe calls it off the main actor.
//  Tests: MultiCamDepthTests.swift (8: one per verdict branch, the 256×192 boundary, the
//  "could" wording of every sentence, and the two `MultiCamCost` cases).
//

import Foundation

/// What `MultiCamDepthProbe` measured on this phone. Plain numbers so the verdict can be tested
/// without AVFoundation.
public struct MultiCamDepthFindings: Sendable, Equatable {

    /// `AVCaptureMultiCamSession.isMultiCamSupported`.
    public let multiCamSupported: Bool
    /// How many entries of `AVCaptureDevice.DiscoverySession.supportedMultiCamDeviceSets` contain
    /// both a front-facing camera and a back-facing camera that can produce depth.
    public let frontPlusDepthDeviceSets: Int
    /// Formats on the back depth camera (LiDAR where present) that are **both** multi-cam capable
    /// (`isMultiCamSupported`) and depth capable (`supportedDepthDataFormats` non-empty).
    public let depthCapableMultiCamFormats: Int
    /// Widest depth format found among those, in pixels (0 when there are none).
    public let bestDepthWidth: Int
    /// …and its height (0 when there are none).
    public let bestDepthHeight: Int

    /// Memberwise init (the probe fills these in from AVFoundation; tests build them by hand).
    /// No validation: a negative or zero size simply reads as "no depth" in `verdict(_:)`.
    public init(multiCamSupported: Bool, frontPlusDepthDeviceSets: Int,
                depthCapableMultiCamFormats: Int, bestDepthWidth: Int, bestDepthHeight: Int) {
        self.multiCamSupported = multiCamSupported
        self.frontPlusDepthDeviceSets = frontPlusDepthDeviceSets
        self.depthCapableMultiCamFormats = depthCapableMultiCamFormats
        self.bestDepthWidth = bestDepthWidth
        self.bestDepthHeight = bestDepthHeight
    }
}

/// The answer to "front + back + depth, without ARKit?" for one phone.
/// ⚠ Raw values are written verbatim to the `multicam_depth` trip-log record (`verdict`); renaming a
/// case breaks comparison with earlier logs.
public enum MultiCamDepthVerdict: String, Sendable, Equatable, CaseIterable {
    /// The phone cannot run two cameras at once at all, so the question is moot.
    case multiCamUnsupported
    /// Two cameras, but no multi-cam format on the back camera carries depth: a future version
    /// could show both pictures and would still have to pause ARKit to do it.
    case noDepthInMultiCam
    /// Depth-capable multi-cam formats exist but never in a set that also has the front camera:
    /// depth survives multi-cam, just not *this* pairing.
    case depthButNotWithTheFrontCamera
    /// Both pictures and depth are possible, at ARKit's `sceneDepth` resolution or below.
    case depthAtOrBelowARKitResolution
    /// Both pictures and depth are possible at a **higher** depth resolution than ARKit's
    /// `sceneDepth` — the WWDC22 claim, confirmed on this phone.
    case depthAboveARKitResolution

    /// True when a future version could show both cameras *and* keep a depth stream.
    /// The safety path could then stay alive through the two-camera mode.
    public var keepsDepth: Bool {
        self == .depthAtOrBelowARKitResolution || self == .depthAboveARKitResolution
    }
}

/// Turns a `MultiCamDepthFindings` into a verdict and a sentence for the trip log.
public enum MultiCamDepth {

    /// Width of ARKit's `sceneDepth` map on the LiDAR iPhones (the app's current depth source).
    public static let arkitSceneDepthWidth = 256
    /// Height of the same map.
    public static let arkitSceneDepthHeight = 192

    /// The measured answer.
    ///
    /// Checks run in order of what makes the question moot: no multi-cam at all, then no depth
    /// format that is also multi-cam capable, then no device set pairing depth with the front
    /// camera. Only then is resolution compared, by pixel count (width × height) strictly greater
    /// than 256 × 192 — equal counts as "at or below" (`depthEqualToARKitResolutionIsNotHigher`).
    /// - Parameter findings: what `MultiCamDepthProbe` read off the device.
    /// - Returns: the verdict; `keepsDepth` is the bit that matters for a future design.
    public static func verdict(_ findings: MultiCamDepthFindings) -> MultiCamDepthVerdict {
        guard findings.multiCamSupported else { return .multiCamUnsupported }
        guard findings.depthCapableMultiCamFormats > 0 else { return .noDepthInMultiCam }
        guard findings.frontPlusDepthDeviceSets > 0 else { return .depthButNotWithTheFrontCamera }
        let pixels = findings.bestDepthWidth * findings.bestDepthHeight
        return pixels > arkitSceneDepthWidth * arkitSceneDepthHeight
            ? .depthAboveARKitResolution
            : .depthAtOrBelowARKitResolution
    }

    /// One readable line for the trip log, so the record answers the question in words as well as
    /// in flags. Deliberately says "could" — nothing has been *run* in that configuration.
    /// Pinned by `everyVerdictHasASentenceThatOnlyClaimsPossibility`.
    /// - Parameter findings: the same measurement passed to `verdict(_:)`.
    /// - Returns: one sentence, logged as the record's `answer` field.
    public static func sentence(_ findings: MultiCamDepthFindings) -> String {
        let depth = "\(findings.bestDepthWidth)x\(findings.bestDepthHeight)"
        switch verdict(findings) {
        case .multiCamUnsupported:
            return "This phone cannot run two cameras at once, so both cameras with depth is impossible."
        case .noDepthInMultiCam:
            return "Two cameras are possible but no multi-cam format carries depth, so ARKit must still be paused."
        case .depthButNotWithTheFrontCamera:
            return "Depth survives multi-cam but never paired with the front camera, so ARKit must still be paused."
        case .depthAtOrBelowARKitResolution:
            return "Both cameras could keep AVFoundation depth at \(depth), at or below ARKit's \(arkitSceneDepthWidth)x\(arkitSceneDepthHeight)."
        case .depthAboveARKitResolution:
            return "Both cameras could keep AVFoundation depth at \(depth), higher than ARKit's \(arkitSceneDepthWidth)x\(arkitSceneDepthHeight)."
        }
    }
}

// MARK: - Hardware cost

/// `AVCaptureMultiCamSession.hardwareCost` rules.
///
/// Apple: `hardwareCost` is "the percentage of the session's available hardware budget currently
/// in use"; above **1.0** the session cannot run and posts an `AVCaptureSessionRuntimeError`. The
/// documented remedy is to lower the frame rate through
/// `AVCaptureDeviceInput.videoMinFrameDurationOverride`, so the numbers for that live here with a
/// test rather than inline in `DualCameraSession`.
///
/// Measured on the iPhone 17 Pro Max the cost was 0.26 with both feeds, so the cut has never fired
/// there; it exists so a hotter or older phone degrades to a slower picture instead of a black one.
/// Caller: `DualCameraSession.reduceFrameRateIfOverBudget(_:)` (sets `frameRateReduced`, logged).
/// Pinned by `hardwareCostOverOneNeedsTheFrameRateCut`, `unreadableHardwareCostChangesNothing`.
public enum MultiCamCost {

    /// The budget. At or below this the session may run; above it, it will not.
    public static let maximumHardwareCost: Double = 1.0

    /// Frames per second each camera is held to when the cost is over budget. 24 is well under the
    /// 30 the spotter view asks for and is still smooth enough for a sighted helper to use — and
    /// nothing safety-related reads these frames (ARKit is paused while the mode is on).
    public static let reducedFramesPerSecond: Int = 24

    /// Whether the two-camera session needs its frame rate cut before it can run.
    /// Strictly above `maximumHardwareCost` (exactly 1.0 may run); a NaN or infinite reading
    /// changes nothing rather than degrading a session on garbage.
    /// - Parameter hardwareCost: `AVCaptureMultiCamSession.hardwareCost` after configuration.
    public static func needsFrameRateReduction(hardwareCost: Double) -> Bool {
        guard hardwareCost.isFinite else { return false }
        return hardwareCost > maximumHardwareCost
    }
}
