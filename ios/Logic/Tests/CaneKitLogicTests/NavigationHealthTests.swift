//
//  NavigationHealthTests.swift
//  CaneKitLogicTests
//
//  Pins the GPS retained-fix fail-safe without CoreLocation or a device.
//

import Testing
@testable import CaneKitLogic

@Test func freshFixMayDriveNavigation() {
    #expect(NavigationHealth.isFresh(timestamp: 100, now: 100))
    #expect(NavigationHealth.isFresh(timestamp: 100, now: 104.999))
}

@Test func staleFixAtTheSafetyBoundIsRejected() {
    #expect(!NavigationHealth.isFresh(timestamp: 100, now: 105))
    #expect(!NavigationHealth.isFresh(timestamp: 100, now: 106))
}

@Test func invalidOrFutureClockCannotKeepGuidanceAlive() {
    #expect(!NavigationHealth.isFresh(timestamp: .nan, now: 100))
    #expect(!NavigationHealth.isFresh(timestamp: 100, now: .infinity))
    #expect(!NavigationHealth.isFresh(timestamp: 101, now: 100))
}
