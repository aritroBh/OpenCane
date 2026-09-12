//
//  SensorModeInterlockTests.swift
//  CaneKitLogicTests
//
//  Pins the route-time AR configuration safety policy without ARKit or a device.
//

import Testing
@testable import CaneKitLogic

@Test func idleAllowsSensorModeRestarts() {
    var policy = SensorModeInterlock()
    #expect(policy.request(.faceTracking, source: .user) == .allowRestart)
    #expect(policy.request(.highFrameRate, source: .user) == .allowRestart)
    #expect(policy.request(.meshClassification, source: .thermal) == .allowRestart)
}

@Test func queuedRouteRefusesUserChanges() {
    var policy = SensorModeInterlock()
    policy.routeStartQueued()

    #expect(policy.phase == .starting)
    #expect(policy.request(.faceTracking, source: .user) == .refuseWhileStarting)
    #expect(policy.request(.highFrameRate, source: .user) == .refuseWhileStarting)
}

@Test func activeRouteRefusesEveryUserRestart() {
    var policy = SensorModeInterlock()
    policy.routeStarted()

    #expect(policy.phase == .navigating)
    #expect(policy.request(.faceTracking, source: .user) == .refuseWhileNavigating)
    #expect(policy.request(.highFrameRate, source: .user) == .refuseWhileNavigating)
    #expect(policy.request(.meshClassification, source: .user) == .refuseWhileNavigating)
}

@Test func thermalMeshRestartDefersAndDrainsAtRouteEnd() {
    var policy = SensorModeInterlock()
    policy.routeStarted()

    #expect(policy.request(.meshClassification, source: .thermal) == .deferUntilRouteEnds)
    #expect(policy.hasDeferredRestart)
    #expect(policy.request(.meshClassification, source: .thermal) == .deferUntilRouteEnds)

    policy.routeFinishing()
    #expect(policy.phase == .finishing)
    #expect(policy.request(.faceTracking, source: .user) == .refuseWhileFinishing)
    #expect(policy.routeEnded() == [.meshClassification])
    #expect(policy.phase == .idle)
    #expect(!policy.hasDeferredRestart)
}

@Test func cancelingQueuedRouteAlsoReleasesThermalRestart() {
    var policy = SensorModeInterlock()
    policy.routeStartQueued()
    _ = policy.request(.meshClassification, source: .thermal)

    #expect(policy.routeStartCanceled() == [.meshClassification])
    #expect(policy.phase == .idle)
    #expect(policy.request(.faceTracking, source: .user) == .allowRestart)
}

@Test func deferredModesDrainInStableOrder() {
    var policy = SensorModeInterlock()
    policy.routeStarted()
    _ = policy.request(.highFrameRate, source: .thermal)
    _ = policy.request(.faceTracking, source: .thermal)

    #expect(policy.routeEnded() == [.faceTracking, .highFrameRate])
}
