//
//  MultiCamDepthTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins MultiCamDepth.swift — the verdict the sensor probe writes into the trip log about
//  whether a future CaneKit could show both cameras *and* keep a depth stream (AVFoundation),
//  instead of pausing ARKit as the shipped "Both cameras" mode does.
//
//  Key invariants under test:
//    · A depth-capable multi-cam format is not enough on its own: it has to be pairable with the
//      front camera, or the answer to *this* question is still no.
//    · "Higher than ARKit" is a measured pixel comparison against 256×192, not a recollection.
//    · `keepsDepth` is only ever true for the two verdicts that really keep depth — a future
//      design would read that flag and nothing else.
//
//  Also pins `MultiCamCost.needsFrameRateReduction` / `reducedFramesPerSecond` (the shipped mode's
//  hardware-cost rule). Callers: `MultiCamDepthProbe` (app; writes the verdict and `sentence` to the
//  trip log as `multicam_depth`) and `DualCameraSession` (cost check before running the session).
//  Breaks these catch: a log that claims depth-in-multi-cam works when it cannot pair with the
//  front camera, a "higher than ARKit" claim at exactly 256×192, a sentence implying something was
//  run, and a NaN or ≤ 1.0 hardware cost triggering a needless reconfiguration.
//

import Testing
@testable import CaneKitLogic

/// A phone without multi-cam answers the question before any format is looked at.
@Test func multiCamDepthIsMootWithoutMultiCam() {
    let f = MultiCamDepthFindings(multiCamSupported: false, frontPlusDepthDeviceSets: 3,
                                  depthCapableMultiCamFormats: 9, bestDepthWidth: 320,
                                  bestDepthHeight: 240)
    #expect(MultiCamDepth.verdict(f) == .multiCamUnsupported)
    #expect(MultiCamDepth.verdict(f).keepsDepth == false)
}

/// Two cameras but no depth-carrying multi-cam format: the shipped design (pause ARKit) stays the
/// only way to show both pictures.
@Test func multiCamWithoutDepthFormatsStillNeedsARKitPaused() {
    let f = MultiCamDepthFindings(multiCamSupported: true, frontPlusDepthDeviceSets: 2,
                                  depthCapableMultiCamFormats: 0, bestDepthWidth: 0,
                                  bestDepthHeight: 0)
    #expect(MultiCamDepth.verdict(f) == .noDepthInMultiCam)
    #expect(MultiCamDepth.verdict(f).keepsDepth == false)
}

/// Depth formats that exist but can never be paired with the front camera answer a different
/// question. ⚠ Do not simplify this away: it is the difference between "depth works in multi-cam"
/// and "depth works in the multi-cam configuration this feature needs".
@Test func depthFormatsThatCannotPairWithTheFrontCameraAreNotAnAnswer() {
    let f = MultiCamDepthFindings(multiCamSupported: true, frontPlusDepthDeviceSets: 0,
                                  depthCapableMultiCamFormats: 7, bestDepthWidth: 320,
                                  bestDepthHeight: 240)
    #expect(MultiCamDepth.verdict(f) == .depthButNotWithTheFrontCamera)
    #expect(MultiCamDepth.verdict(f).keepsDepth == false)
}

/// The WWDC22 claim (AVFoundation streams LiDAR depth up to 320×240, above ARKit's 256×192),
/// expressed as a pixel comparison so the log says which side of it this phone landed on.
@Test func depthAbove256x192CountsAsHigherThanARKit() {
    let f = MultiCamDepthFindings(multiCamSupported: true, frontPlusDepthDeviceSets: 1,
                                  depthCapableMultiCamFormats: 4, bestDepthWidth: 320,
                                  bestDepthHeight: 240)
    #expect(MultiCamDepth.verdict(f) == .depthAboveARKitResolution)
    #expect(MultiCamDepth.verdict(f).keepsDepth)
    #expect(MultiCamDepth.sentence(f).contains("320x240"))
    #expect(MultiCamDepth.sentence(f).contains("higher"))
}

/// Exactly ARKit's own resolution is *not* an improvement, so it reads as "at or below".
@Test func depthEqualToARKitResolutionIsNotHigher() {
    let f = MultiCamDepthFindings(multiCamSupported: true, frontPlusDepthDeviceSets: 1,
                                  depthCapableMultiCamFormats: 4,
                                  bestDepthWidth: MultiCamDepth.arkitSceneDepthWidth,
                                  bestDepthHeight: MultiCamDepth.arkitSceneDepthHeight)
    #expect(MultiCamDepth.verdict(f) == .depthAtOrBelowARKitResolution)
    #expect(MultiCamDepth.verdict(f).keepsDepth)
}

/// Every verdict has a sentence, and no sentence promises that anything was actually run.
@Test func everyVerdictHasASentenceThatOnlyClaimsPossibility() {
    let samples = [
        MultiCamDepthFindings(multiCamSupported: false, frontPlusDepthDeviceSets: 0,
                              depthCapableMultiCamFormats: 0, bestDepthWidth: 0, bestDepthHeight: 0),
        MultiCamDepthFindings(multiCamSupported: true, frontPlusDepthDeviceSets: 0,
                              depthCapableMultiCamFormats: 0, bestDepthWidth: 0, bestDepthHeight: 0),
        MultiCamDepthFindings(multiCamSupported: true, frontPlusDepthDeviceSets: 0,
                              depthCapableMultiCamFormats: 2, bestDepthWidth: 320, bestDepthHeight: 240),
        MultiCamDepthFindings(multiCamSupported: true, frontPlusDepthDeviceSets: 1,
                              depthCapableMultiCamFormats: 2, bestDepthWidth: 160, bestDepthHeight: 120),
        MultiCamDepthFindings(multiCamSupported: true, frontPlusDepthDeviceSets: 1,
                              depthCapableMultiCamFormats: 2, bestDepthWidth: 320, bestDepthHeight: 240),
    ]
    var seen = Set<MultiCamDepthVerdict>()
    for f in samples {
        let sentence = MultiCamDepth.sentence(f)
        #expect(!sentence.isEmpty)
        #expect(!sentence.contains("does"))       // no claim that it was run
        seen.insert(MultiCamDepth.verdict(f))
    }
    #expect(seen.count == MultiCamDepthVerdict.allCases.count)
}

// MARK: - Hardware cost

/// Apple's rule: above 1.0 the multi-cam session will not run. At exactly the budget it may.
@Test func hardwareCostOverOneNeedsTheFrameRateCut() {
    #expect(MultiCamCost.needsFrameRateReduction(hardwareCost: 0.26) == false)
    #expect(MultiCamCost.needsFrameRateReduction(hardwareCost: 1.0) == false)
    #expect(MultiCamCost.needsFrameRateReduction(hardwareCost: 1.01))
}

/// A NaN cost (an unreadable session) must not trigger a reconfiguration.
@Test func unreadableHardwareCostChangesNothing() {
    #expect(MultiCamCost.needsFrameRateReduction(hardwareCost: .nan) == false)
    #expect(MultiCamCost.reducedFramesPerSecond < 30)
}
