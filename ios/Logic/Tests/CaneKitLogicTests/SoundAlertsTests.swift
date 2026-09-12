//
//  SoundAlertsTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins SoundAlerts.swift — which microphone sounds are announced to a blind walker, how
//  sure the classifier has to be, and how often the same thing may be said again.
//
//  Key invariants under test:
//    · A siren has the lowest confidence gate (cheapest to get wrong, most expensive to miss) and
//      a generic vehicle sound the highest (the commonest false positive on a sidewalk).
//    · Nothing is announced from a single analysis window: two consecutive windows must agree.
//    · The same kind is not repeated inside its own interval, so standing at a busy corner does
//      not become a running commentary over the route instructions.
//    · The spoken lines match `AppModel.commonLines` byte for byte (the natural-voice prefetch).
//

import Testing
@testable import CaneKitLogic

// MARK: - Gates and labels

/// The gate order is the safety argument: miss a siren and the walker steps into an ambulance's
/// path; cry "vehicle" on an empty sidewalk and they stop trusting the app.
/// ⚠ Do not raise the siren gate or lower the vehicle gate without a street test.
@Test func sirenIsGatedLowestAndVehicleHighest() {
    #expect(DangerSound.siren.minimumConfidence < DangerSound.horn.minimumConfidence)
    #expect(DangerSound.horn.minimumConfidence < DangerSound.vehicle.minimumConfidence)
    #expect(DangerSound.siren.minimumConfidence == 0.50)
    #expect(DangerSound.vehicle.minimumConfidence == 0.75)
}

/// A siren approaches, so it may be repeated sooner; a vehicle sound is ambient and waits longest.
@Test func repeatIntervalsRiseWithHowAmbientTheSoundIs() {
    #expect(DangerSound.siren.repeatInterval < DangerSound.vehicle.repeatInterval)
    #expect(DangerSound.horn.repeatInterval == 12)
}

/// Every spoken line is short, ends in a full stop, and is one of the three strings
/// `AppModel.commonLines` prefetches. ⚠ Changing a line here means changing that list.
@Test func spokenLinesAreThePrefetchedOnes() {
    #expect(DangerSound.siren.spokenLine == "Siren nearby.")
    #expect(DangerSound.horn.spokenLine == "Horn nearby.")
    #expect(DangerSound.vehicle.spokenLine == "Vehicle sound nearby.")
    for sound in DangerSound.allCases {
        #expect(sound.spokenLine.hasSuffix("."))
        #expect(sound.spokenLine.count < 30)
    }
}

/// The label table maps each identifier to exactly one kind, and the identifiers measured on the
/// iPhone 17 Pro Max / iOS 27 (trip-log `probe_f_sound_labels`) are all present.
@Test func measuredLabelsMapToTheRightKind() {
    #expect(SoundAlerts.kind(for: "siren") == .siren)
    #expect(SoundAlerts.kind(for: "police_siren") == .siren)
    #expect(SoundAlerts.kind(for: "emergency_vehicle") == .siren)
    #expect(SoundAlerts.kind(for: "car_horn") == .horn)
    #expect(SoundAlerts.kind(for: "air_horn") == .horn)
    #expect(SoundAlerts.kind(for: "car_passing_by") == .vehicle)
    #expect(SoundAlerts.kind(for: "traffic_noise") == .vehicle)
    #expect(SoundAlerts.kind(for: "engine_idling") == .vehicle)
}

/// Anything the classifier hears that is not traffic is not a danger sound: speech, music, a dog
/// and a door must never produce a warning.
@Test func everydaySoundsAreNotDangerSounds() {
    for label in ["speech", "music", "dog", "door", "typing", "laughter", "silence"] {
        #expect(SoundAlerts.kind(for: label) == nil)
    }
}

/// `candidateLabels` is what `SoundWatcher` and `SensorProbe` check against the phone; it must be
/// the flattened table with no duplicates, or one label would be matched to two kinds.
@Test func candidateLabelsAreTheWholeTableWithoutDuplicates() {
    let all = SoundAlerts.candidateLabels
    #expect(all.count == Set(all).count)
    #expect(all.contains("siren"))
    #expect(all.count == SoundAlerts.labels.values.reduce(0) { $0 + $1.count })
}

// MARK: - Policy

/// One window is never enough. A single frame of "siren" on a street is usually a bus braking.
@Test func oneWindowNeverAnnounces() {
    var policy = SoundAlertPolicy()
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 0) == nil)
}

/// Two consecutive windows above the gate do announce — that is ≤ 1 s of latency at the app's
/// 0.5 s window hop.
@Test func twoAgreeingWindowsAnnounce() {
    var policy = SoundAlertPolicy()
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 0) == nil)
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 0.5) == .siren)
}

/// Confidence under the kind's own gate breaks the run: a half-heard siren is not a siren.
@Test func lowConfidenceBreaksTheRun() {
    var policy = SoundAlertPolicy()
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 0) == nil)
    #expect(policy.update(kind: .siren, confidence: 0.2, now: 0.5) == nil)
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 1.0) == nil)   // run restarted
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 1.5) == .siren)
}

/// A quiet window (no danger sound at all) also breaks the run.
@Test func aWindowWithNoDangerSoundBreaksTheRun() {
    var policy = SoundAlertPolicy()
    #expect(policy.update(kind: .horn, confidence: 0.9, now: 0) == nil)
    #expect(policy.update(kind: nil, confidence: 0, now: 0.5) == nil)
    #expect(policy.update(kind: .horn, confidence: 0.9, now: 1.0) == nil)
    #expect(policy.update(kind: .horn, confidence: 0.9, now: 1.5) == .horn)
}

/// Two *different* sounds in a row do not add up: alternating siren / horn windows announce
/// nothing until one of them wins two windows.
@Test func alternatingKindsDoNotAccumulate() {
    var policy = SoundAlertPolicy()
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 0) == nil)
    #expect(policy.update(kind: .horn, confidence: 0.9, now: 0.5) == nil)
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 1.0) == nil)
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 1.5) == .siren)
}

/// A sound that stays audible is announced once and then held for its interval: standing at a
/// corner while an ambulance goes past must not talk over the route guidance.
@Test func theSameSoundIsNotRepeatedInsideItsInterval() {
    var policy = SoundAlertPolicy()
    _ = policy.update(kind: .siren, confidence: 0.9, now: 0)
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 0.5) == .siren)
    for t in stride(from: 1.0, through: 14.5, by: 0.5) {
        #expect(policy.update(kind: .siren, confidence: 0.9, now: t) == nil)
    }
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 15.5) == .siren)
}

/// The interval is per kind: a horn during a siren's silence window is still announced, because
/// it means something different.
@Test func intervalsAreIndependentPerKind() {
    var policy = SoundAlertPolicy()
    _ = policy.update(kind: .siren, confidence: 0.9, now: 0)
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 0.5) == .siren)
    #expect(policy.update(kind: .horn, confidence: 0.9, now: 1.0) == nil)
    #expect(policy.update(kind: .horn, confidence: 0.9, now: 1.5) == .horn)
}

/// `reset()` clears both the run and every repeat timer, so a new walk is not silenced by the
/// last walk's siren.
@Test func resetClearsTheRunAndTheTimers() {
    var policy = SoundAlertPolicy()
    _ = policy.update(kind: .siren, confidence: 0.9, now: 0)
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 0.5) == .siren)
    policy.reset()
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 1.0) == nil)
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 1.5) == .siren)
}

/// A vehicle sound needs its higher gate: 0.7 is not enough, 0.8 is.
@Test func vehicleNeedsItsHigherGate() {
    var policy = SoundAlertPolicy()
    #expect(policy.update(kind: .vehicle, confidence: 0.7, now: 0) == nil)
    #expect(policy.update(kind: .vehicle, confidence: 0.7, now: 0.5) == nil)
    #expect(policy.update(kind: .vehicle, confidence: 0.8, now: 1.0) == nil)
    #expect(policy.update(kind: .vehicle, confidence: 0.8, now: 1.5) == .vehicle)
}

// MARK: - Microphone start (input-format settling)

/// The format check is what stands between the app and an `AVAudioEngine` trap, so it must reject
/// exactly the two shapes a not-yet-settled input node reports and nothing else.
/// ⚠ Pins `MicrophoneStart.isUsableInputFormat`, called by `SoundWatcher.startEngine`.
@Test func onlyAFullySettledInputFormatIsUsable() {
    #expect(MicrophoneStart.isUsableInputFormat(sampleRate: 48_000, channels: 1))
    #expect(MicrophoneStart.isUsableInputFormat(sampleRate: 16_000, channels: 2))
    // A stale read right after the session went `.playAndRecord`: no rate yet.
    #expect(!MicrophoneStart.isUsableInputFormat(sampleRate: 0, channels: 1))
    // A route with an input port but no channels negotiated yet (seen on the first AirPods enable).
    #expect(!MicrophoneStart.isUsableInputFormat(sampleRate: 48_000, channels: 0))
    #expect(!MicrophoneStart.isUsableInputFormat(sampleRate: 0, channels: 0))
}

/// One retry, then the walker is told the truth. Retrying forever would leave the switch on and
/// the session in `.playAndRecord` with nothing listening.
/// ⚠ Pins the retry budget used by `SoundWatcher.startEngine(attempt:)`.
@Test func theInputFormatIsRetriedExactlyOnce() {
    #expect(MicrophoneStart.formatAttempts == 2)
    #expect(MicrophoneStart.retryDelay(afterAttempt: 0) == MicrophoneStart.formatRetryDelay)
    #expect(MicrophoneStart.retryDelay(afterAttempt: 1) == nil)
    #expect(MicrophoneStart.retryDelay(afterAttempt: 5) == nil)
}

/// The whole retry budget has to stay inside the time a switch may take to answer. A blind user
/// gets no visual "working…" state, so anything past about half a second reads as a dead control.
@Test func theWholeRetryBudgetStaysUnderHalfASecond() {
    let total = Double(MicrophoneStart.formatAttempts - 1) * MicrophoneStart.formatRetryDelay
    #expect(total > 0)
    #expect(total <= 0.5)
}
