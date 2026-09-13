//
//  SceneDescribePolicyTests.swift
//  CaneKitLogicTests
//
//  Pins the lock fence for "Where am I" (Step 63).
//
//  Why these tests exist: a cloud description started before a lock could still speak the
//  pre-lock scene after the unlock — the conversation path already cancelled, the describer
//  did not. The generation compare is the whole rule.
//
//  Source pinned: `SceneDescribePolicy.swift`. Owner: `SceneDescriber` (app).
//

import Foundation
import Testing

@testable import CaneKitLogic

/// A lock bumps the generation; the run that started before it must not speak.
@Test func aLockGenerationDropsThePreLockScene() {
    #expect(SceneDescribePolicy.maySpeak(started: 3, current: 3))
    #expect(!SceneDescribePolicy.maySpeak(started: 3, current: 4))
    #expect(!SceneDescribePolicy.maySpeak(started: 0, current: 1))
}
