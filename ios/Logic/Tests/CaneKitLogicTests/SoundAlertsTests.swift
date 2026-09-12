//
//  SoundAlertsTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins SoundAlerts.swift — which microphone sounds are announced to a blind walker, how
//  sure the classifier has to be, and how often the same thing may be said again.
//
//  Key invariants under test:
//    · An emergency siren is `.emergency` urgency (spoken in the `.nav` band) and nothing else is;
//      nothing in this file may ever reach `.safety`, which would delay "Head height."
//    · The siren line is an *instruction* and governs starting to cross, never stopping — a walker
//      already in the crosswalk must clear it, not freeze.
//    · A siren is gated higher and needs more agreeing windows than it used to: its line now tells
//      a blind person to hold at a kerb, so a false positive is a safety defect.
//    · An emergency candidate is never shadowed by the ambient traffic class inside one window.
//    · The same kind is not repeated inside its own interval, so standing at a busy corner does
//      not become a running commentary over the route instructions.
//    · The spoken lines match `AppModel.commonLines` byte for byte (the natural-voice prefetch).
//

import Testing
@testable import CaneKitLogic

// MARK: - Gates and labels

/// The gate order is the safety argument, and it was **inverted** for the siren when its line
/// became an instruction: missing a siren leaves the walker with their own hearing, which is
/// better than this microphone; a false one holds a blind person at a kerb in the route band and
/// spends the trust the app runs on. A generic vehicle sound is still gated highest — it is the
/// commonest false positive on a sidewalk.
/// ⚠ Do not lower the siren gate or the vehicle gate without a street test that counts false alarms.
@Test func sirenIsGatedForFalsePositivesAndVehicleHighest() {
    #expect(DangerSound.siren.minimumConfidence == 0.60)
    #expect(DangerSound.horn.minimumConfidence == 0.60)
    #expect(DangerSound.vehicle.minimumConfidence == 0.75)
    #expect(DangerSound.siren.minimumConfidence < DangerSound.vehicle.minimumConfidence)
}

/// A siren approaches, so it may be repeated sooner; a vehicle sound is ambient and waits longest.
@Test func repeatIntervalsRiseWithHowAmbientTheSoundIs() {
    #expect(DangerSound.siren.repeatInterval < DangerSound.vehicle.repeatInterval)
    #expect(DangerSound.horn.repeatInterval == 12)
}

/// Only an emergency-vehicle siren is `.emergency`; horns and engines stay ambient. The app maps
/// `.emergency` → `.nav` and `.ambient` → `.obstacle` (`AppModel.wireSounds`).
/// ⚠ There is no mapping to `.safety` and there must never be one: equal priorities queue FIFO in
/// `SpeechQueue`, so a sound alert in that band would delay "Head height." by its own length.
@Test func onlyTheSirenIsAnEmergency() {
    #expect(DangerSound.siren.urgency == .emergency)
    #expect(DangerSound.horn.urgency == .ambient)
    #expect(DangerSound.vehicle.urgency == .ambient)
    #expect(SoundUrgency.emergency > SoundUrgency.ambient)
    #expect(DangerSound.allCases.filter { $0.urgency == .emergency } == [.siren])
}

/// A sound alert must never sit in the queue long enough to be spoken about a vehicle that has
/// gone — a stale instruction is a false positive with a delay on it.
///
/// 5 s for the siren: at `.nav` it queues behind at most the route line already playing, and 5 s
/// covers that with margin while guaranteeing nobody is told to hold at a kerb about an ambulance
/// that passed ten seconds ago. 4 s for the horn, which is the most momentary of the three. Every
/// TTL is shorter than its own repeat interval, so a line that expired can never be overtaken by
/// the next announcement of the same kind.
@Test func speechTTLsAreShortEnoughThatNoLineIsSpokenLate() {
    #expect(DangerSound.siren.speechTTL == 5)
    #expect(DangerSound.horn.speechTTL == 4)
    for sound in DangerSound.allCases {
        #expect(sound.speechTTL <= 6)
        #expect(sound.speechTTL < sound.repeatInterval)
    }
}

/// Every spoken line is short, ends in a full stop, and is one of the three strings
/// `AppModel.commonLines` prefetches. ⚠ Changing a line here means changing that list.
@Test func spokenLinesAreThePrefetchedOnes() {
    #expect(DangerSound.siren.spokenLine == "Siren. Do not start crossing.")
    #expect(DangerSound.horn.spokenLine == "Horn nearby.")
    #expect(DangerSound.vehicle.spokenLine == "Vehicle sound nearby.")
    for sound in DangerSound.allCases {
        #expect(sound.spokenLine.hasSuffix("."))
        #expect(sound.spokenLine.count <= 30)
    }
}

/// The wording rule that keeps a false alarm from being lethal: pedestrian guidance for an
/// approaching emergency vehicle is asymmetric — do not step into the crosswalk, but if you are
/// already in the intersection, clear it rather than stopping in it. The microphone cannot tell
/// which the walker is doing, so the line must be a no-op for one and an instruction for the
/// other. "Do not start crossing." is; "Stop." and "Do not cross." are not.
/// ⚠ If this test is ever in the way, the line is wrong, not the test.
@Test func theSirenLineGovernsStartingToCrossAndNeverSaysStop() {
    let line = DangerSound.siren.spokenLine.lowercased()
    #expect(line.contains("do not start crossing"))
    #expect(!line.contains("stop"))
    #expect(!line.contains("do not cross."))
    #expect(!line.contains("wait"))          // ambiguous mid-crossing; "start" is the whole point
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
    #expect(SoundAlerts.kind(for: "fire_engine_siren") == .siren)
    #expect(SoundAlerts.kind(for: "civil_defense_siren") == .siren)
}

/// A parked car's alarm is not an emergency vehicle, and the siren line now tells a blind person
/// to hold at a kerb. It is absent from `knownClassifications` on the demo phone, so this costs
/// nothing today — it stops a future iOS that adds the label from quietly wiring a car park to
/// "Siren. Do not start crossing."
@Test func carAlarmIsNotASiren() {
    #expect(SoundAlerts.kind(for: "car_alarm") == nil)
}

/// A bicycle bell is one of the most frequent sounds on a university campus and it *does* exist in
/// this classifier. Announcing it as "Horn nearby." was both wrong and constant, and constant
/// wrong warnings are a safety defect, not an annoyance. A campus bell may deserve its own cue one
/// day; it does not deserve the horn's words.
@Test func bicycleBellIsNotAHorn() {
    #expect(SoundAlerts.kind(for: "bicycle_bell") == nil)
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

// MARK: - Window selection (an emergency must not be shadowed)

/// **The regression this file exists for.** Next to a road `traffic_noise` and `engine` are high in
/// every classification window. Picking the window's highest-confidence *danger* label therefore
/// reports `vehicle` while an approaching siren sits second — and because the policy needs
/// consecutive *agreeing* windows, the ambient class breaks the siren's run every time and the
/// alert never fires at all. `best(of:)` prefers the more urgent kind whenever it clears its own
/// gate, so the siren survives the window even at lower confidence than the traffic around it.
@Test func anEmergencySirenIsNotShadowedByTheAmbientTrafficClass() {
    let window = [(label: "traffic_noise", confidence: 0.91),
                  (label: "engine", confidence: 0.88),
                  (label: "siren", confidence: 0.64)]
    let best = SoundAlerts.best(of: window)
    #expect(best?.label == "siren")
    #expect(best?.confidence == 0.64)
}

/// Urgency only wins once the kind clears its own gate. A siren the classifier is not sure about
/// must not displace a vehicle sound it is sure about — that would be urgency laundering a guess.
@Test func aSubGateSirenDoesNotDisplaceAConfidentVehicle() {
    let window = [(label: "traffic_noise", confidence: 0.91), (label: "siren", confidence: 0.31)]
    #expect(SoundAlerts.best(of: window)?.label == "traffic_noise")
}

/// When nothing clears a gate the highest-confidence danger label is still returned, unchanged
/// from the old behaviour: the policy needs to see a sub-gate window so it can break the run.
@Test func aWindowWithNothingAboveAGateStillReportsItsBest() {
    let window = [(label: "siren", confidence: 0.31), (label: "traffic_noise", confidence: 0.44)]
    #expect(SoundAlerts.best(of: window)?.label == "traffic_noise")
}

/// Labels that are not danger sounds are ignored, so the whole window can be passed in; a window
/// of nothing but speech and music reports nil, which the relay turns into a broken run.
@Test func aWindowWithNoDangerLabelsSelectsNothing() {
    #expect(SoundAlerts.best(of: [(label: "speech", confidence: 0.99),
                                  (label: "music", confidence: 0.80)]) == nil)
    #expect(SoundAlerts.best(of: []) == nil)
}

/// Within one kind the most confident label wins, so the trip log names the label the classifier
/// was actually surest of ("police_siren", not whichever came first in the result array).
@Test func withinOneKindTheMostConfidentLabelWins() {
    let window = [(label: "siren", confidence: 0.62), (label: "police_siren", confidence: 0.83)]
    #expect(SoundAlerts.best(of: window)?.label == "police_siren")
}

/// A non-finite confidence is dropped rather than ranked. NaN compares false against everything,
/// so a NaN arriving first would sit in the fallback slot and never be displaced by a real
/// candidate — it would win by being unrankable, and a window of garbage would announce a siren.
@Test func aNonFiniteConfidenceIsIgnoredNotRanked() {
    let window = [(label: "siren", confidence: Double.nan),
                  (label: "traffic_noise", confidence: 0.44)]
    #expect(SoundAlerts.best(of: window)?.label == "traffic_noise")
    #expect(SoundAlerts.best(of: [(label: "siren", confidence: .nan)]) == nil)
    #expect(SoundAlerts.best(of: [(label: "siren", confidence: .infinity)]) == nil)
}

// MARK: - Policy

/// One window is never enough. A single frame of "siren" on a street is usually a bus braking.
@Test func oneWindowNeverAnnounces() {
    var policy = SoundAlertPolicy()
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 0) == nil)
}

/// A siren needs **three** agreeing windows (≈ 1.5 s of continuous siren at the app's 0.5 s hop)
/// and a horn still needs two. The shapes are different: a siren runs for tens of seconds, so the
/// third window costs the walker nothing real and is the cheapest defence against a one-off
/// confusable (a bell, an alarm test, a held brass note); a honk is often under a second, so a
/// third window would not make it surer, it would mean horns are never announced at all.
/// ⚠ Pins `DangerSound.requiredWindows`, used by `SoundAlertPolicy.update`.
@Test func sirenNeedsThreeWindowsAndHornStillNeedsTwo() {
    #expect(DangerSound.siren.requiredWindows == 3)
    #expect(DangerSound.horn.requiredWindows == 2)
    #expect(DangerSound.vehicle.requiredWindows == 2)

    var siren = SoundAlertPolicy()
    #expect(siren.update(kind: .siren, confidence: 0.9, now: 0) == nil)
    #expect(siren.update(kind: .siren, confidence: 0.9, now: 0.5) == nil)     // two is no longer enough
    #expect(siren.update(kind: .siren, confidence: 0.9, now: 1.0) == .siren)

    var horn = SoundAlertPolicy()
    #expect(horn.update(kind: .horn, confidence: 0.9, now: 0) == nil)
    #expect(horn.update(kind: .horn, confidence: 0.9, now: 0.5) == .horn)
}

/// Two agreeing windows announce for the ambient kinds — ≤ 1 s of latency at the 0.5 s window hop.
@Test func twoAgreeingWindowsAnnounceAnAmbientSound() {
    var policy = SoundAlertPolicy()
    #expect(policy.update(kind: .vehicle, confidence: 0.9, now: 0) == nil)
    #expect(policy.update(kind: .vehicle, confidence: 0.9, now: 0.5) == .vehicle)
}

/// Confidence under the kind's own gate breaks the run: a half-heard siren is not a siren.
@Test func lowConfidenceBreaksTheRun() {
    var policy = SoundAlertPolicy()
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 0) == nil)
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 0.5) == nil)
    #expect(policy.update(kind: .siren, confidence: 0.2, now: 1.0) == nil)
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 1.5) == nil)   // run restarted
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 2.0) == nil)
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 2.5) == .siren)
}

/// 0.55 used to be a siren and is not any more: the gate moved from 0.50 to 0.60 when the line
/// became an instruction spoken in the route band (SoundAlerts.swift R5).
@Test func aSirenJustUnderTheNewGateIsSilent() {
    var policy = SoundAlertPolicy()
    for t in stride(from: 0.0, through: 2.0, by: 0.5) {
        #expect(policy.update(kind: .siren, confidence: 0.55, now: t) == nil)
    }
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
/// nothing until one of them holds its own run for its own number of windows.
@Test func alternatingKindsDoNotAccumulate() {
    var policy = SoundAlertPolicy()
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 0) == nil)
    #expect(policy.update(kind: .horn, confidence: 0.9, now: 0.5) == nil)
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 1.0) == nil)
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 1.5) == nil)
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 2.0) == .siren)
}

/// A sound that stays audible is announced once and then held for its interval: standing at a
/// corner while an ambulance goes past must not talk over the route guidance. The repeat one
/// interval later is information, not nagging — at 50 km/h the vehicle is ≈ 200 m closer.
@Test func theSameSoundIsNotRepeatedInsideItsInterval() {
    var policy = SoundAlertPolicy()
    _ = policy.update(kind: .siren, confidence: 0.9, now: 0)
    _ = policy.update(kind: .siren, confidence: 0.9, now: 0.5)
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 1.0) == .siren)
    for t in stride(from: 1.5, through: 15.5, by: 0.5) {
        #expect(policy.update(kind: .siren, confidence: 0.9, now: t) == nil)
    }
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 16.5) == .siren)
}

/// The interval is per kind: a horn during a siren's silence window is still announced, because
/// it means something different.
@Test func intervalsAreIndependentPerKind() {
    var policy = SoundAlertPolicy()
    _ = policy.update(kind: .siren, confidence: 0.9, now: 0)
    _ = policy.update(kind: .siren, confidence: 0.9, now: 0.5)
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 1.0) == .siren)
    #expect(policy.update(kind: .horn, confidence: 0.9, now: 1.5) == nil)
    #expect(policy.update(kind: .horn, confidence: 0.9, now: 2.0) == .horn)
}

/// `reset()` clears both the run and every repeat timer, so a new walk is not silenced by the
/// last walk's siren.
@Test func resetClearsTheRunAndTheTimers() {
    var policy = SoundAlertPolicy()
    _ = policy.update(kind: .siren, confidence: 0.9, now: 0)
    _ = policy.update(kind: .siren, confidence: 0.9, now: 0.5)
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 1.0) == .siren)
    policy.reset()
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 1.5) == nil)
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 2.0) == nil)
    #expect(policy.update(kind: .siren, confidence: 0.9, now: 2.5) == .siren)
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
