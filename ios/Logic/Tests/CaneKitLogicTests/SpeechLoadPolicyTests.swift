//
//  SpeechLoadPolicyTests.swift
//  CaneKitLogicTests
//
//  Tests for the optional-speech governor. The test names state the break they catch: a policy
//  change must never silence explicit or safety speech, and repeated optional obstacle names must
//  not fill the spoken channel while the walker is moving.
//

import CaneKitLogic
import Testing

@Suite("Speech load policy")
struct SpeechLoadPolicyTests {

    @Test("normal speech bypasses the governor even when the queue is busy")
    func normalSpeechIsNeverSuppressed() {
        var policy = SpeechLoadPolicy()

        #expect(policy.admit(.normal, now: 0, isBusy: true) == .speak)
        #expect(policy.admit(.normal, now: 0.1, isBusy: false) == .speak)
    }

    @Test("the first optional obstacle name is admitted")
    func firstObstacleNameIsAdmitted() {
        var policy = SpeechLoadPolicy()

        #expect(policy.admit(.ambientObstacleName, now: 0, isBusy: false) == .speak)
    }

    @Test("optional obstacle names inside the calm window are dropped")
    func obstacleNamesInsideCalmWindowAreDropped() {
        var policy = SpeechLoadPolicy()
        _ = policy.admit(.ambientObstacleName, now: 10, isBusy: false)

        #expect(policy.admit(.ambientObstacleName, now: 16.99, isBusy: false)
                == .suppress(reason: .calmWindow))
    }

    @Test("the seven-second boundary admits the next optional name")
    func calmWindowBoundaryIsInclusive() {
        var policy = SpeechLoadPolicy()
        _ = policy.admit(.ambientObstacleName, now: 10, isBusy: false)

        #expect(policy.admit(.ambientObstacleName, now: 17, isBusy: false) == .speak)
    }

    @Test("a busy queue drops an optional name without consuming the next slot")
    func busyDropDoesNotConsumeTheClock() {
        var policy = SpeechLoadPolicy()

        #expect(policy.admit(.ambientObstacleName, now: 0, isBusy: true)
                == .suppress(reason: .busy))
        #expect(policy.admit(.ambientObstacleName, now: 0.1, isBusy: false) == .speak)
    }

    @Test("non-finite time fails closed")
    func nonFiniteTimeIsRejected() {
        var policy = SpeechLoadPolicy()

        #expect(policy.admit(.ambientObstacleName, now: .nan, isBusy: false)
                == .suppress(reason: .invalidTime))
    }

    @Test("reset forgets the previous optional-name clock")
    func resetClearsTheClock() {
        var policy = SpeechLoadPolicy()
        _ = policy.admit(.ambientObstacleName, now: 100, isBusy: false)
        policy.reset()

        #expect(policy.admit(.ambientObstacleName, now: 100.1, isBusy: false) == .speak)
    }
}
