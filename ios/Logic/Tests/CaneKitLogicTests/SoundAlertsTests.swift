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
//  Sources pinned: `SoundAlerts.swift` (`DangerSound`, `SoundUrgency`, `SoundAlerts.kind` /
//  `best` / `candidateLabels`, `SoundAlertPolicy`, `MicrophoneStart`) and, in the last MARK,
//  `SoundRecognitionGuard.swift` (the microphone recognition lifetime guard, Step 28).
//  Callers: `SoundWatcher` (app; classifier windows → `best` → `SoundAlertPolicy`, the input-format
//  retry, the guard), `AppModel.wireSounds` (urgency → speech band), `VoiceInputEngine`
//  (`MicrophoneStart` retry), `SensorProbe` (`candidateLabels`), `SpeechQueue` (route snapshots).
//  ⚠ Mutating guard calls are hoisted into locals (`g1`, `g2`, …) before `#expect`, which captures
//  its argument immutably (AGENTS.md).
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

/// A sound alert's TTL is bounded on both sides: long enough to survive the queue ahead of it,
/// short enough never to be news about a gone vehicle.
///
/// The siren gets its full repeat interval (15 s). A shorter TTL expires unheard behind an
/// ordinary `.nav` line — `SpeechQueue` only pre-empts on strictly higher priority and purges
/// expired lines when a line ends, while crossing instructions run 4–8 s and warnings up to 20 s —
/// so 5 s dropped sirens arriving mid-instruction. 15 s cannot go stale past usefulness (an
/// emergency vehicle is audible for tens of seconds; the next interval re-announces anyway) and
/// can never overlap the next reminder of the same kind. Horn keeps 4 s (momentary) and vehicle
/// 6 s, each below its own repeat interval for the same no-overlap reason.
@Test func speechTTLsSurviveTheQueueButNeverOverlapARepeat() {
    #expect(DangerSound.siren.speechTTL == 15)
    #expect(DangerSound.siren.speechTTL == DangerSound.siren.repeatInterval)
    #expect(DangerSound.horn.speechTTL == 4)
    #expect(DangerSound.vehicle.speechTTL == 6)
    for sound in DangerSound.allCases {
        #expect(sound.speechTTL <= sound.repeatInterval)
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

/// Recovery stays bounded while giving a route a few seconds to settle; an unbounded retry would
/// keep a failed microphone lease alive forever.
@Test func microphoneSessionRecoveryIsBounded() {
    #expect(MicrophoneSessionRecovery.retryAttempts == 3)
    #expect(MicrophoneSessionRecovery.retryDelay > 0)
    #expect(Double(MicrophoneSessionRecovery.retryAttempts) * MicrophoneSessionRecovery.retryDelay <= 5)
}

/// A slow classifier may drop input, but it must never retain an unbounded stream of PCM buffers.
@Test func microphoneAnalysisBacklogIsBounded() {
    #expect(MicrophoneAnalysisLimits.maxPendingBuffers > 0)
    #expect(MicrophoneAnalysisLimits.maxPendingBuffers <= 16)
}

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

/// Walking the retry loop the way both callers do (`attempt + 1` until `retryDelay` is nil) reads
/// the format exactly `formatAttempts` times and always terminates; a caller that started at a
/// negative attempt gets no retry at all.
/// ⚠ Pins the loop shape shared by `SoundWatcher.startEngine(attempt:)` and
/// `VoiceInputEngine.startEngine(attempt:sessionField:)`.
@Test func theRetryLoopReadsTheFormatExactlyFormatAttemptsTimes() {
    var attempt = 0
    var reads = 0
    while true {
        reads += 1
        guard MicrophoneStart.retryDelay(afterAttempt: attempt) != nil else { break }
        attempt += 1
    }
    #expect(reads == MicrophoneStart.formatAttempts)
    #expect(MicrophoneStart.retryDelay(afterAttempt: -1) == nil)
}

/// The whole retry budget has to stay inside the time a switch may take to answer. A blind user
/// gets no visual "working…" state, so anything past about half a second reads as a dead control.
@Test func theWholeRetryBudgetStaysUnderHalfASecond() {
    let total = Double(MicrophoneStart.formatAttempts - 1) * MicrophoneStart.formatRetryDelay
    #expect(total > 0)
    #expect(total <= 0.5)
}

// MARK: - Recognition lifetime guard

/// A usable route snapshot (speaker out, built-in mic in, `.usable`): the baseline every guard test
/// starts from before feeding it a degraded, changed or missing route.
private let healthySoundRoute = SoundRecognitionRoute(output: "Speaker",
                                                       input: "BuiltInMic",
                                                       inputQuality: .usable)

/// A route that changes to Bluetooth HFP while recognition is active stops immediately, even when
/// the output name has not changed. The input quality is part of the guard because a phone-call
/// microphone can degrade before Core Audio publishes a different output port.
/// ⚠ Pins `SoundRecognitionGuard.routeChanged`, driven by `SpeechQueue` notifications.
@Test func midSessionHFPInputDegradationStopsRecognition() {
    let alreadyCallQuality = SoundRecognitionRoute(output: "BluetoothHFP[airpods-a]",
                                                    input: "BuiltInMic",
                                                    inputQuality: .usable)
    #expect(!alreadyCallQuality.isUsable)
    var outputGuard = SoundRecognitionGuard()
    // Hoisted: `#expect` expands its argument into a closure that captures
    // the guard immutably, so mutating calls run here first, in order.
    let g1 = outputGuard.beginStart()
    #expect(g1)
    let g2 = outputGuard.sessionStarted(route: alreadyCallQuality) == .stop(.inputRouteDegraded)
    #expect(g2)

    var guardState = SoundRecognitionGuard()
    let g3 = guardState.beginStart()
    #expect(g3)
    let g4 = guardState.sessionStarted(route: healthySoundRoute)
    #expect(g4 == .continueRunning)
    let g5 = guardState.recognitionStarted(route: healthySoundRoute)
    #expect(g5 == .continueRunning)
    let degraded = SoundRecognitionRoute(output: "Speaker", input: "BluetoothHFP",
                                         inputQuality: .hfp)
    let g6 = guardState.routeChanged(degraded) == .stop(.inputRouteDegraded)
    #expect(g6)
    #expect(guardState.state == .idle)

    // Two devices can advertise the same A2DP type; UID/name are retained in the snapshot so the
    // second device is still an output-route change and cannot silently replace the beacon path.
    var deviceGuard = SoundRecognitionGuard()
    let deviceA = SoundRecognitionRoute(output: "BluetoothA2DP[uid-a|AirPods A]",
                                         input: "BuiltInMic[uid-mic|iPhone]",
                                         inputQuality: .usable)
    let deviceB = SoundRecognitionRoute(output: "BluetoothA2DP[uid-b|AirPods B]",
                                         input: "BuiltInMic[uid-mic|iPhone]",
                                         inputQuality: .usable)
    let g7 = deviceGuard.beginStart()
    #expect(g7)
    let g8 = deviceGuard.sessionStarted(route: deviceA)
    #expect(g8 == .continueRunning)
    let g9 = deviceGuard.recognitionStarted(route: deviceA)
    #expect(g9 == .continueRunning)
    let g10 = deviceGuard.routeChanged(deviceB) == .stop(.outputRouteChanged)
    #expect(g10)
}

/// SoundAnalysis failures are hard stops, not diagnostic-only state. The second callback after a
/// stop is ignored, so a late relay error cannot speak a duplicate failure or re-touch AVAudio.
@Test func analyzerThrowStopsOnce() {
    var guardState = SoundRecognitionGuard()
    let g11 = guardState.beginStart()
    #expect(g11)
    let g12 = guardState.sessionStarted(route: healthySoundRoute)
    #expect(g12 == .continueRunning)
    let g13 = guardState.recognitionStarted(route: healthySoundRoute)
    #expect(g13 == .continueRunning)
    let g14 = guardState.analyzerFailed() == .stop(.analyzerFailed)
    #expect(g14)
    let g15 = guardState.analyzerFailed()
    #expect(g15 == .ignored)

    var interruptedGuard = SoundRecognitionGuard()
    let g16 = interruptedGuard.beginStart()
    #expect(g16)
    let g17 = interruptedGuard.sessionStarted(route: healthySoundRoute)
    #expect(g17 == .continueRunning)
    let g18 = interruptedGuard.recognitionStarted(route: healthySoundRoute)
    #expect(g18 == .continueRunning)
    let g19 = interruptedGuard.interruptionBegan() == .stop(.interrupted)
    #expect(g19)
    let g20 = interruptedGuard.interruptionBegan()
    #expect(g20 == .ignored)
}

/// Permission revocation during an active run takes the feature down while leaving the rest of the
/// app alone. Re-granting permission does not implicitly restart a switch the user did not re-arm.
@Test func permissionRevokedMidSessionStopsRecognition() {
    var guardState = SoundRecognitionGuard()
    let g21 = guardState.beginStart()
    #expect(g21)
    let g22 = guardState.sessionStarted(route: healthySoundRoute)
    #expect(g22 == .continueRunning)
    let g23 = guardState.recognitionStarted(route: healthySoundRoute)
    #expect(g23 == .continueRunning)
    let g24 = guardState.permissionRevoked() == .stop(.permissionRevoked)
    #expect(g24)
    #expect(!guardState.isActive)
}

/// Turning the switch off while the permission prompt is up invalidates that prompt's generation;
/// a later Allow callback is inert and cannot start a microphone behind the visible switch.
@Test func permissionRaceCancellationInvalidatesLateGrant() {
    var guardState = SoundRecognitionGuard()
    let pending = guardState.beginPermissionRequest()
    let generation = try! #require(pending)
    let gCancel = guardState.cancel()
    #expect(gCancel == .cancelPendingStart)
    let g25 = guardState.permissionResolved(granted: true, generation: generation)
    #expect(g25 == .ignored)
    #expect(guardState.state == .idle)
}

/// Rapid route flapping cannot thrash start/stop or spam cues: the first degraded event wins and
/// all later notifications are ignored until an explicit user restart.
@Test func rapidRouteFlappingFailsOnceAndStaysIdle() {
    var guardState = SoundRecognitionGuard()
    let g26 = guardState.beginStart()
    #expect(g26)
    let g27 = guardState.sessionStarted(route: healthySoundRoute)
    #expect(g27 == .continueRunning)
    let g28 = guardState.recognitionStarted(route: healthySoundRoute)
    #expect(g28 == .continueRunning)
    let hfp = SoundRecognitionRoute(output: "Speaker", input: "BluetoothHFP",
                                    inputQuality: .hfp)
    let g29 = guardState.routeChanged(hfp) == .stop(.inputRouteDegraded)
    #expect(g29)
    let backToHealthy = healthySoundRoute
    let g30 = guardState.routeChanged(backToHealthy)
    #expect(g30 == .ignored)
    let g31 = guardState.routeChanged(hfp)
    #expect(g31 == .ignored)

    var missingInputGuard = SoundRecognitionGuard()
    let g32 = missingInputGuard.beginStart()
    #expect(g32)
    let g33 = missingInputGuard.sessionStarted(route: healthySoundRoute)
    #expect(g33 == .continueRunning)
    let g34 = missingInputGuard.recognitionStarted(route: healthySoundRoute)
    #expect(g34 == .continueRunning)
    let missingInput = SoundRecognitionRoute(output: "Speaker", input: "none",
                                              inputQuality: .unavailable)
    let g35 = missingInputGuard.routeChanged(missingInput) == .stop(.inputUnavailable)
    #expect(g35)
}

/// The normal cold start may expose an input-less route for a fraction of a second. That startup
/// settle is allowed once; the analyser still cannot become live until a usable route arrives.
@Test func startupInputRouteSettlesWithoutDisablingTheFeature() {
    var guardState = SoundRecognitionGuard()
    let g36 = guardState.beginStart()
    #expect(g36)
    let pending = SoundRecognitionRoute(output: "Speaker", input: "none",
                                        inputQuality: .unavailable)
    let g37 = guardState.sessionStarted(route: pending)
    #expect(g37 == .continueRunning)
    let g38 = guardState.routeChanged(healthySoundRoute)
    #expect(g38 == .continueRunning)
    let g39 = guardState.recognitionStarted(route: healthySoundRoute)
    #expect(g39 == .continueRunning)
}
