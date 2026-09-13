//
//  VoiceInputGuardTests.swift
//  CaneKitLogicTests
//
//  Fake-route lifecycle coverage for the push-to-talk voice-input safety gate.
//

import CaneKitLogic
import Testing

/// Pins the push-to-talk interlock to fake, Sendable audio routes instead of a device microphone.
@Suite("Voice input lifecycle guard")
struct VoiceInputGuardTests {
    private let healthy = SoundRecognitionRoute(output: "Speaker[uid-speaker|iPhone]",
                                                input: "BuiltInMic[uid-mic|iPhone]",
                                                inputQuality: .usable)

    @Test("permission health is polled at the bounded half-second cadence")
    func permissionPollCadenceIsBounded() {
        #expect(VoiceInputGuard.permissionPollInterval == 0.5)
    }

    /// A missing input during activation may settle once, but recognition cannot become live until
    /// a usable route is observed.
    @Test("cold start requires a usable route before listening")
    func coldStartNeedsUsableInput() {
        var guardState = VoiceInputGuard()
        let started = guardState.beginStart()
        #expect(started)

        let pendingRoute = SoundRecognitionRoute(output: healthy.output, input: "none",
                                                 inputQuality: .unavailable)
        let pendingDecision = guardState.sessionStarted(route: pendingRoute)
        #expect(pendingDecision == .continueRunning)

        let settledDecision = guardState.routeChanged(healthy)
        #expect(settledDecision == .continueRunning)
        let listeningDecision = guardState.recognitionStarted(route: healthy)
        #expect(listeningDecision == .continueRunning)
        #expect(guardState.state == .listening(route: healthy))
    }

    /// HFP and input loss stop an active capture and leave the guard idle.
    @Test("HFP or missing input stops an active voice capture")
    func degradedRoutesStopCapture() {
        var hfpGuard = VoiceInputGuard()
        let hfpStarted = hfpGuard.beginStart()
        #expect(hfpStarted)
        let hfpRoute = SoundRecognitionRoute(output: "BluetoothHFP[AirPods]",
                                             input: "BluetoothHFP[AirPods]",
                                             inputQuality: .hfp)
        let hfpSessionDecision = hfpGuard.sessionStarted(route: hfpRoute)
        #expect(hfpSessionDecision == .stop(.inputRouteDegraded))

        var missingGuard = VoiceInputGuard()
        let missingStarted = missingGuard.beginStart()
        #expect(missingStarted)
        let sessionDecision = missingGuard.sessionStarted(route: healthy)
        #expect(sessionDecision == .continueRunning)
        let listeningDecision = missingGuard.recognitionStarted(route: healthy)
        #expect(listeningDecision == .continueRunning)
        let missingRoute = SoundRecognitionRoute(output: healthy.output, input: "none",
                                                 inputQuality: .unavailable)
        let missingDecision = missingGuard.routeChanged(missingRoute)
        #expect(missingDecision == .stop(.inputUnavailable))
        #expect(missingGuard.state == .idle)
    }

    /// Replacing the output route stops capture; a late callback cannot adopt the new device.
    @Test("output route replacement stops without accepting a new device")
    func outputRouteChangeStopsCapture() {
        var guardState = VoiceInputGuard()
        let started = guardState.beginStart()
        #expect(started)
        let sessionDecision = guardState.sessionStarted(route: healthy)
        #expect(sessionDecision == .continueRunning)
        let listeningDecision = guardState.recognitionStarted(route: healthy)
        #expect(listeningDecision == .continueRunning)

        let replacement = SoundRecognitionRoute(output: "BluetoothA2DP[AirPods]",
                                                input: healthy.input,
                                                inputQuality: .usable)
        let routeDecision = guardState.routeChanged(replacement)
        #expect(routeDecision == .stop(.outputRouteChanged))
        let lateDecision = guardState.routeChanged(healthy)
        #expect(lateDecision == .ignored)
    }

    /// Recognition and interruption failures stop once and ignore subsequent events.
    @Test("recognizer errors and interruptions drop partial capture")
    func recognitionFailureAndInterruptionStopOnce() {
        var recognitionGuard = VoiceInputGuard()
        let recognitionStarted = recognitionGuard.beginStart()
        #expect(recognitionStarted)
        let recognitionSession = recognitionGuard.sessionStarted(route: healthy)
        #expect(recognitionSession == .continueRunning)
        let recognitionLive = recognitionGuard.recognitionStarted(route: healthy)
        #expect(recognitionLive == .continueRunning)
        let errorDecision = recognitionGuard.recognitionFailed()
        #expect(errorDecision == .stop(.recognitionFailed))
        let lateError = recognitionGuard.recognitionFailed()
        #expect(lateError == .ignored)

        var interruptionGuard = VoiceInputGuard()
        let interruptionStarted = interruptionGuard.beginStart()
        #expect(interruptionStarted)
        let interruptionSession = interruptionGuard.sessionStarted(route: healthy)
        #expect(interruptionSession == .continueRunning)
        let interruptionLive = interruptionGuard.recognitionStarted(route: healthy)
        #expect(interruptionLive == .continueRunning)
        let interruptionDecision = interruptionGuard.interruptionBegan()
        #expect(interruptionDecision == .stop(.interrupted))
        let lateEnded = interruptionGuard.routeChanged(healthy)
        #expect(lateEnded == .ignored)
    }

    /// Permission loss stops live capture, while canceling authorization invalidates a late grant.
    @Test("permission revocation stops and a cancelled authorization cannot restart")
    func permissionRevocationAndCancellation() {
        var activeGuard = VoiceInputGuard()
        let activeStarted = activeGuard.beginStart()
        #expect(activeStarted)
        let activeSession = activeGuard.sessionStarted(route: healthy)
        #expect(activeSession == .continueRunning)
        let activeLive = activeGuard.recognitionStarted(route: healthy)
        #expect(activeLive == .continueRunning)
        let revokedDecision = activeGuard.permissionRevoked()
        #expect(revokedDecision == .stop(.permissionRevoked))

        var pendingGuard = VoiceInputGuard()
        let pendingGeneration = pendingGuard.beginPermissionRequest()
        #expect(pendingGeneration != nil)
        let cancelled = pendingGuard.cancel()
        #expect(cancelled == .cancelPendingStart)
        let staleGrant = pendingGuard.permissionResolved(granted: true,
                                                         generation: pendingGeneration ?? 0)
        #expect(staleGrant == .ignored)
        let staleSession = pendingGuard.sessionStarted(route: healthy)
        #expect(staleSession == .ignored)
        #expect(pendingGuard.state == .idle)
    }
}
