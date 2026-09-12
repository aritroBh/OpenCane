//
//  FamilyAlertPolicyTests.swift
//  CaneKitLogicTests
//
//  Pins when a detection becomes a family alert. The stakes are asymmetric and run both ways:
//  a missed fall is the point of the product, and a chatty `warn` buzzes a family member's phone
//  every time (the bot texts for warn/critical), which is how people learn to ignore it.
//
//  ⚠ Style note: `FamilyAlertPolicy` is a struct with mutating methods, and `#expect` / `#require`
//  take autoclosures — calling a mutating method inside one does not compile under Swift 6
//  ("cannot use mutating member on immutable value"). Every call below is made into a local first.
//

import Foundation
import Testing
@testable import CaneKitLogic

/// Breadcrumbs are throttled to `locationInterval`, and the clock is the caller's seconds.
@Test func locationBreadcrumbsAreThrottled() {
    var policy = FamilyAlertPolicy()
    let interval = policy.limits.locationInterval

    let first = policy.location(lat: 40.1, lng: -88.2, accuracyM: 5, headingDegrees: nil,
                                speedMps: 1.2, now: 0)
    let tooSoon = policy.location(lat: 40.1, lng: -88.2, accuracyM: 5, headingDegrees: nil,
                                  speedMps: 1.2, now: interval - 1)
    let due = policy.location(lat: 40.1, lng: -88.2, accuracyM: 5, headingDegrees: nil,
                              speedMps: 1.2, now: interval)

    #expect(first != nil)
    #expect(tooSoon == nil)
    #expect(due != nil)
}

/// A breadcrumb is `info` so the bot keeps it chat-only, and CoreLocation's −1 sentinels for
/// unknown accuracy / speed are dropped rather than sent as real numbers.
@Test func locationIsInfoAndDropsInvalidSentinels() throws {
    var policy = FamilyAlertPolicy()
    let made = policy.location(lat: 40.1, lng: -88.2, accuracyM: -1,
                               headingDegrees: nil, speedMps: -1, now: 0)

    let event = try #require(made)
    #expect(event.severity == .info)
    #expect(event.accuracyM == nil)
    #expect(event.speedMps == nil)
    #expect(event.lat == 40.1)
}

/// Only a measured, close obstacle is worth texting family about.
@Test func onlyCloseObstaclesAlert() {
    var policy = FamilyAlertPolicy()
    let maxDistance = policy.limits.obstacleMaxDistanceM

    let tooFar = policy.obstacle(kind: "pole", distanceM: maxDistance + 0.1, direction: "center",
                                 lat: nil, lng: nil, note: nil, now: 0)
    let atLimit = policy.obstacle(kind: "pole", distanceM: maxDistance, direction: "center",
                                  lat: nil, lng: nil, note: nil, now: 0)

    #expect(tooFar == nil)
    #expect(atLimit != nil)
}

/// An unknown distance is never assumed dangerous — the haptics already fired, and a `warn`
/// reaches a family member's phone.
@Test func obstacleWithUnknownDistanceIsNotAnAlert() {
    var policy = FamilyAlertPolicy()
    let unknown = policy.obstacle(kind: "wall", distanceM: nil, direction: "head",
                                  lat: nil, lng: nil, note: nil, now: 0)
    let infinite = policy.obstacle(kind: "wall", distanceM: .infinity, direction: "head",
                                   lat: nil, lng: nil, note: nil, now: 0)

    #expect(unknown == nil)
    #expect(infinite == nil)
}

/// Walking a corridor of obstacles sends one event per `obstacleInterval`, not one per frame.
@Test func obstaclesAreRateLimited() throws {
    var policy = FamilyAlertPolicy()
    let interval = policy.limits.obstacleInterval

    let made = policy.obstacle(kind: "door", distanceM: 0.8, direction: "center",
                               lat: 40.1, lng: -88.2, note: "Door ahead.", now: 0)
    let tooSoon = policy.obstacle(kind: "door", distanceM: 0.8, direction: "center",
                                  lat: nil, lng: nil, note: nil, now: interval - 1)
    let due = policy.obstacle(kind: "door", distanceM: 0.8, direction: "center",
                              lat: nil, lng: nil, note: nil, now: interval)

    let first = try #require(made)
    #expect(first.severity == .warn)
    #expect(first.obstacle?.distanceM == 0.8)
    #expect(first.obstacle?.direction == "center")
    #expect(tooSoon == nil)
    #expect(due != nil)
}

/// Low battery fires once per discharge and only re-arms after a real recharge, so a phone
/// sitting at the threshold cannot text family over and over.
@Test func lowBatteryFiresOncePerDischarge() throws {
    var policy = FamilyAlertPolicy()
    let low = policy.limits.lowBatteryPct
    let rearm = policy.limits.lowBatteryRearmPct

    let made = policy.lowBattery(pct: low)
    let stillDischarging = policy.lowBattery(pct: low - 1)
    let notChargedEnough = policy.lowBattery(pct: rearm - 1)
    let rearmed = policy.lowBattery(pct: rearm)
    let nextDischarge = policy.lowBattery(pct: low)

    let event = try #require(made)
    #expect(event.severity == .warn)
    #expect(event.batteryPct == low)
    #expect(stillDischarging == nil)
    #expect(notChargedEnough == nil)
    #expect(rearmed == nil)                 // re-arms, but `rearm` is not itself low
    #expect(nextDischarge != nil)
}

/// The simulator reports −1 for an unknown battery level; that is not an alert.
@Test func unknownBatteryNeverAlerts() {
    var policy = FamilyAlertPolicy()
    let unknown = policy.lowBattery(pct: -1)
    #expect(unknown == nil)
}

/// fall and sos are critical and carry the position; they are static because they must never be
/// rate-limited by policy state.
@Test func fallAndSOSAreAlwaysCritical() {
    let fall = FamilyAlertPolicy.fall(lat: 40.1106, lng: -88.2284, note: nil)
    #expect(fall.type == .fall)
    #expect(fall.severity == .critical)
    #expect(fall.lat == 40.1106)
    #expect(fall.note == "Possible fall detected")

    let sos = FamilyAlertPolicy.sos(lat: nil, lng: nil, note: "Help")
    #expect(sos.type == .sos)
    #expect(sos.severity == .critical)
    #expect(sos.note == "Help")
}

/// A status line stays `info` so arriving somewhere never texts family.
@Test func statusIsQuiet() {
    #expect(FamilyAlertPolicy.status("Arrived at CIF").severity == .info)
}

/// `reset()` clears the rate limits (new route) but must NOT re-arm the battery: the battery did
/// not recharge because a route started.
@Test func resetClearsRateLimitsButNotBatteryArming() {
    var policy = FamilyAlertPolicy()
    let firstFix = policy.location(lat: 1, lng: 2, accuracyM: nil, headingDegrees: nil,
                                   speedMps: nil, now: 0)
    let firstBattery = policy.lowBattery(pct: 10)

    policy.reset()

    let afterReset = policy.location(lat: 1, lng: 2, accuracyM: nil, headingDegrees: nil,
                                     speedMps: nil, now: 1)
    let batteryAfterReset = policy.lowBattery(pct: 10)

    #expect(firstFix != nil)
    #expect(firstBattery != nil)
    #expect(afterReset != nil)              // rate limit forgotten
    #expect(batteryAfterReset == nil)       // arming deliberately survives
}
