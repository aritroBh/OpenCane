//
//  PeopleDetectionTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins the people-ahead validation gate. A fresh install must leave this optional,
//  unvalidated feature off, and enabling it must retain an explicit experimental metadata state.
//  Caller: `AppModel.namePeopleEnabled` / `HazardsCard`.
//

import Testing
@testable import CaneKitLogic

/// A fresh install cannot silently enable an unvalidated detector.
@Test func peopleDetectionDefaultsOff() {
    #expect(PeopleDetection.defaultEnabled == false)
    #expect(PeopleDetection.state(enabled: PeopleDetection.defaultEnabled) == .off)
    #expect(!PeopleDetection.State.off.isEnabled)
}

/// Turning the switch on is an experiment, not a validation claim, and its metadata is stable.
@Test func enabledPeopleDetectionRemainsExperimental() {
    let state = PeopleDetection.state(enabled: true)
    #expect(state == .experimentalUnverified)
    #expect(state.isEnabled)
    #expect(state.rawValue == "experimental_unverified")
    #expect(state.userFacingDescription.contains("not validated"))
}

