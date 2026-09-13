//
//  StopRouteConfirmationTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins the two-tap Stop route safety gate, including its timeout boundary.
//  Caller: `GuideCard`.
//

import Testing
@testable import CaneKitLogic

/// The first tap only arms the destructive action.
@Test func stopRouteFirstTapDoesNotConfirm() {
    var confirmation = StopRouteConfirmation()
    let result = confirmation.press(at: 100)
    #expect(result == .armed)
    #expect(confirmation.isArmed)
}

/// A second tap at the exact window boundary confirms and disarms the state.
@Test func stopRouteSecondTapWithinWindowConfirms() {
    var confirmation = StopRouteConfirmation()
    _ = confirmation.press(at: 100)
    let result = confirmation.press(at: 100 + StopRouteConfirmation.window)
    #expect(result == .confirmed)
    #expect(!confirmation.isArmed)
}

/// A stale or backwards timestamp cannot confirm an old accidental tap; it starts a fresh arm.
@Test func stopRouteExpiredConfirmationMustBeRearmed() {
    var confirmation = StopRouteConfirmation()
    _ = confirmation.press(at: 100)
    let result = confirmation.press(at: 100 + StopRouteConfirmation.window + 0.001)
    #expect(result == .armed)
    #expect(confirmation.isArmed)
}

