//
//  SoundWatcher.swift
//  CaneKit
//
//  The microphone's job: hear the traffic the LiDAR cannot see. Sirens, horns and vehicle sounds
//  reach the walker from behind, around a corner, and from 100 m away — none of which the 5 m
//  LiDAR, the camera or the GPS route can tell them about.
//
//  How: Apple's built-in sound classifier (`SNClassifySoundRequest(classifierIdentifier:
//  .version1)`, 303 labels on this phone — counted, see below) over the live microphone, via
//  `AVAudioEngine.inputNode` → `SNAudioStreamAnalyzer`. Every classification window is reduced to
//  at most one `DangerSound` and handed to CaneKitLogic `SoundAlertPolicy`, which holds the
//  confidence gates, the two-window agreement rule and the per-kind repeat intervals
//  (AGENTS.md hard rule 3; tests in SoundAlertsTests).
//
//  Label identifiers are **read off the phone, never guessed**. Apple documents "hundreds of
//  sounds" but publishes no list of the strings, and `SNClassifySoundRequest.knownClassifications`
//  is the documented way to get them. `start()` intersects `SoundAlerts.candidateLabels` with that
//  array and matches only labels this iOS version actually has, logging both the matches and the
//  misses as `sound_watch_labels`. Measured on the iPhone 17 Pro Max / iOS 27 (2026-09-11,
//  trip-log `probe_f_sound_labels`): 303 known labels, of which these exist — siren,
//  police_siren, ambulance_siren, fire_engine_siren, civil_defense_siren, emergency_vehicle,
//  car_horn, air_horn, train_horn, bicycle_bell, car_passing_by, traffic_noise, engine,
//  engine_idling, bus, truck, motorcycle — and "vehicle", "car", "honk", "car_alarm",
//  "tire_squeal" and friends do **not**.
//
//  Audio session — the real cost, stated plainly. `.playback` has no input, so this feature needs
//  `.playAndRecord`, which AGENTS.md hard rule 7 and ios/README.md §2 deliberately forbid as the
//  app's steady state (HFP would drop AirPods to call quality and kill the HRTF beacon). The
//  compromise: the switch is **off by default**, the category change goes through the one owner of
//  the session (`SpeechQueue.setMicrophoneEnabled`), `.allowBluetoothHFP` is never requested, and
//  if the output route changes *at all* the session is reverted and this watcher refuses to run and
//  says so. Speech, obstacle warnings and the beacon are the safety path; a microphone feature
//  never outranks them.
//
//  Owner: `AppModel.sounds` (one instance). Alerts are spoken at `.obstacle` priority — below
//  route lines and below "Head height." (docs/design.md §5): a sound the walker can also hear
//  themselves is worth less than a warning they cannot.
//
//  Threading / isolation: `@MainActor @Observable`. `SNResultsObserving` is called by
//  SoundAnalysis on its own queue, and the microphone tap is called on an AVAudioEngine render
//  thread, so both go through `nonisolated` relays that carry only Sendable values (`String`,
//  `Double`) and hop with `Task { @MainActor in … }` (AGENTS.md hard rule 1). The analyser itself
//  runs on a dedicated serial queue, as Apple's article requires.
//
//  Key invariants:
//    · Nothing runs until `start()`, and `start()` is only called from the Hazards card's switch.
//    · A degraded audio route always wins: `lastError` is set, the session is `.playback` again,
//      and `isRunning` stays false.
//    · `stop()` always restores `.playback`, even if the engine failed half-way up.
//

import AVFoundation
import CaneKitLogic
import Foundation
import Observation
import SoundAnalysis

/// Danger-sound recognition on the live microphone. Off by default; owned by `AppModel`.
@MainActor
@Observable
final class SoundWatcher {

    // MARK: Published

    /// True while the microphone tap and the analyser are live.
    private(set) var isRunning = false
    /// Last line spoken because of a sound ("Siren nearby."), for the Hazards card.
    private(set) var lastAlert: String?
    /// Why the watcher is not running: a refused microphone, a degraded audio route, or an engine
    /// failure. Shown on the Hazards card in the warning colour; never cleared silently.
    private(set) var lastError: String?
    /// "17 of 30 labels available" — proof in the UI that the classifier really has the labels
    /// this build matches on.
    private(set) var labelReport = ""

    /// Fired on the main actor for each sound worth announcing. `AppModel` speaks it and logs it.
    @ObservationIgnored var onAlert: ((DangerSound) -> Void)?
    /// Trip-log hook: `(kind, fields)`, wired by `AppModel.wireSounds()`.
    @ObservationIgnored var onDiagnostic: ((String, [String: Any]) -> Void)?

    // MARK: Private

    /// The one audio engine for the microphone tap; created lazily on first `start()` and reused,
    /// because a fresh `AVAudioEngine` per start leaks render threads.
    @ObservationIgnored private let engine = AVAudioEngine()
    /// Serial queue the analyser runs on (Apple: "running the stream analyzer on a dedicated
    /// dispatch queue" keeps the audio engine responsive).
    @ObservationIgnored private let analysisQueue = DispatchQueue(label: "canekit.sound", qos: .userInitiated)
    /// Non-nil while running; discarded on `stop()` because an analyser is bound to one input
    /// format (Apple: "if the input device's audio format changes… create a new one").
    @ObservationIgnored private var analyzer: SNAudioStreamAnalyzer?
    /// Strong reference to the results relay (SoundAnalysis holds observers weakly).
    @ObservationIgnored private var observer: SoundResultsRelay?
    /// Carries microphone buffers from the audio tap thread to the analysis queue; non-nil only
    /// while running.
    @ObservationIgnored private var pump: SoundAnalysisPump?
    /// The confidence / agreement / repeat rules (CaneKitLogic, SoundAlertsTests).
    @ObservationIgnored private var policy = SoundAlertPolicy()
    /// The labels this phone's classifier actually has, mapped to their kind. Built in `start()`
    /// from `knownClassifications`; empty until then, so nothing can match before the check.
    @ObservationIgnored private var activeLabels: [String: DangerSound] = [:]
    /// The audio-session owner; the only object allowed to call `setCategory`.
    @ObservationIgnored private let speech: SpeechQueue

    /// True when this build can create the built-in classifier at all (it cannot on a platform
    /// without the model). Evaluated once; gates the Hazards card's switch.
    static let isAvailable: Bool = (try? SNClassifySoundRequest(classifierIdentifier: .version1)) != nil

    /// - Parameter speech: `AppModel.speech`, which owns the audio session.
    init(speech: SpeechQueue) {
        self.speech = speech
    }

    // MARK: Lifecycle

    /// Ask for the microphone, put the session into `.playAndRecord` (reverting if that costs the
    /// output route), build the analyser and start the engine.
    ///
    /// Order matters: permission → session → labels → analyser → tap → engine. A failure at any
    /// step leaves `lastError` set, `isRunning` false and the session back on `.playback`.
    /// Caller: `AppModel.dangerSoundsEnabled`'s `didSet` and `AppModel.start()` when the setting
    /// was already on.
    func start() {
        guard !isRunning else { return }
        lastError = nil
        // Permission first: `.playAndRecord` on a phone that has refused the microphone would
        // succeed and then deliver silence, which looks exactly like "no sirens today".
        switch AVAudioApplication.shared.recordPermission {
        case .denied:
            fail("Microphone is off for CaneKit. Sound alerts need it.")
            return
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if granted { self.start() } else {
                        self.fail("Microphone is off for CaneKit. Sound alerts need it.")
                    }
                }
            }
            return
        case .granted:
            break
        @unknown default:
            break
        }

        switch speech.setMicrophoneEnabled(true) {
        case .granted(let route):
            onDiagnostic?("sound_watch", ["action": "session", "route": route])
        case .revertedRouteChanged(let before, let after):
            onDiagnostic?("sound_watch", ["action": "session_reverted", "before": before, "after": after])
            fail("Sound alerts would change the audio route from \(before) to \(after), so they stayed off.")
            return
        case .failed(let message):
            onDiagnostic?("sound_watch", ["action": "session_failed", "error": message])
            fail("Sound alerts could not use the microphone: \(message)")
            return
        }

        guard let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else {
            _ = speech.setMicrophoneEnabled(false)
            fail("This phone has no built-in sound classifier.")
            return
        }
        // Two windows must agree before anything is spoken, so the window hop sets the latency:
        // `overlapFactor` 0.5 over the classifier's own window ≈ 0.5 s per window.
        request.overlapFactor = 0.5
        buildLabelTable(request)

        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            _ = speech.setMicrophoneEnabled(false)
            fail("No microphone input available.")
            return
        }
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let relay = SoundResultsRelay { [weak self] label, confidence in
            Task { @MainActor [weak self] in self?.classified(label: label, confidence: confidence) }
        } onFailure: { [weak self] message in
            Task { @MainActor [weak self] in self?.lastError = message }
        }
        do {
            try analyzer.add(request, withObserver: relay)
        } catch {
            _ = speech.setMicrophoneEnabled(false)
            fail("Sound analysis refused the request: \(error.localizedDescription)")
            return
        }
        self.analyzer = analyzer
        observer = relay
        policy.reset()

        // The tap is called on an audio thread and must return fast, so it only hands the buffer
        // to the analyser's own queue (Apple: "run the stream analyzer on a dedicated dispatch
        // queue"). `SoundAnalysisPump` is what makes that legal under strict concurrency.
        let pump = SoundAnalysisPump(analyzer: analyzer, queue: analysisQueue)
        self.pump = pump
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            pump.feed(buffer, at: time.sampleTime)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            _ = speech.setMicrophoneEnabled(false)
            fail("The audio engine could not start: \(error.localizedDescription)")
            return
        }
        isRunning = true
        onDiagnostic?("sound_watch", ["action": "start", "sample_rate": format.sampleRate,
                                      "labels": activeLabels.count])
    }

    /// Stop the tap and the engine, drop the analyser and **always** restore `.playback`.
    /// Callers: the Hazards card's switch (through `AppModel.dangerSoundsEnabled`) and
    /// `AppModel.scenePhaseChanged(.background)`. It deliberately survives a route ending: the
    /// walker asked to be told about traffic, not about traffic on a route.
    func stop() {
        guard isRunning || analyzer != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        analyzer?.removeAllRequests()
        analyzer = nil
        observer = nil
        pump = nil
        policy.reset()
        isRunning = false
        _ = speech.setMicrophoneEnabled(false)
        onDiagnostic?("sound_watch", ["action": "stop"])
    }

    // MARK: Classification

    /// Keep only the candidate labels this phone's classifier really has, and log the rest.
    /// Without this the feature could look enabled while matching identifiers that do not exist.
    private func buildLabelTable(_ request: SNClassifySoundRequest) {
        let known = Set(request.knownClassifications)
        var table: [String: DangerSound] = [:]
        var missing: [String] = []
        for (kind, labels) in SoundAlerts.labels {
            for label in labels {
                if known.contains(label) { table[label] = kind } else { missing.append(label) }
            }
        }
        activeLabels = table
        labelReport = "\(table.count) of \(SoundAlerts.candidateLabels.count) labels available"
        onDiagnostic?("sound_watch_labels", [
            "known_count": known.count,
            "matched": table.keys.sorted(),
            "missing": missing.sorted(),
        ])
    }

    /// One classification window's best danger-sound candidate (already filtered and hopped to
    /// main by `SoundResultsRelay`): run it through the policy and announce what survives.
    /// - Parameters:
    ///   - label: a classifier identifier known to be in `activeLabels`.
    ///   - confidence: 0…1 from `SNClassification.confidence`.
    private func classified(label: String, confidence: Double) {
        guard isRunning else { return }
        let kind = activeLabels[label]
        let now = Date().timeIntervalSinceReferenceDate
        guard let announce = policy.update(kind: kind, confidence: confidence, now: now) else { return }
        lastAlert = announce.spokenLine
        onDiagnostic?("sound_alert", ["sound": announce.rawValue, "label": label,
                                      "confidence": (confidence * 100).rounded() / 100])
        onAlert?(announce)
    }

    /// Record a reason the watcher is not running and make sure the flag agrees with it.
    private func fail(_ message: String) {
        lastError = message
        isRunning = false
    }

}

/// Hands microphone buffers from the audio tap thread to the analyser's serial queue.
///
/// It exists only to make that hop legal under Swift 6 strict concurrency: neither
/// `SNAudioStreamAnalyzer` nor `AVAudioPCMBuffer` is `Sendable`, and the tap block escapes the
/// audio thread. `@unchecked Sendable` is sound here — the analyser is touched **only** from
/// `queue` (a serial queue), each buffer is handed over exactly once and never read again by the
/// tap, and the pump is dropped (with the tap removed first) in `SoundWatcher.stop()`. It is not
/// used to silence a real data race (AGENTS.md hard rule 1).
private nonisolated final class SoundAnalysisPump: @unchecked Sendable {

    private let analyzer: SNAudioStreamAnalyzer
    private let queue: DispatchQueue

    init(analyzer: SNAudioStreamAnalyzer, queue: DispatchQueue) {
        self.analyzer = analyzer
        self.queue = queue
    }

    /// Called on the audio tap thread; returns immediately.
    /// - Parameters:
    ///   - buffer: the PCM buffer the tap delivered (SoundAnalysis only accepts PCM).
    ///   - position: `AVAudioTime.sampleTime`, the analyser's stream position.
    func feed(_ buffer: AVAudioPCMBuffer, at position: AVAudioFramePosition) {
        let box = SoundBufferBox(buffer)
        queue.async { [self] in
            analyzer.analyze(box.buffer, atAudioFramePosition: position)
        }
    }
}

/// Carries one non-`Sendable` `AVAudioPCMBuffer` across the tap → analysis-queue hop. Sound
/// because the buffer is written once before the hop and read once after it, by one queue.
private nonisolated final class SoundBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

/// `SNResultsObserving` relay. SoundAnalysis calls it on the analyser's queue, so it is
/// `nonisolated` and carries only Sendable values (`String`, `Double`) into the main-actor hop
/// (AGENTS.md hard rule 1). It keeps no state of its own, so it is trivially safe there.
///
/// It forwards the whole window's best *danger* candidate rather than the top classification: the
/// classifier's most confident label on a street is usually "speech" or "silence", and filtering
/// on main would mean hopping 2 × per second for nothing.
private nonisolated final class SoundResultsRelay: NSObject, SNResultsObserving, @unchecked Sendable {

    /// `(label, confidence)` of the best danger sound in a window; a window with none reports
    /// `("", 0)` so the policy's agreement run is correctly broken.
    private let onResult: @Sendable (String, Double) -> Void
    /// The analyser gave up (format change, internal error).
    private let onFailure: @Sendable (String) -> Void

    init(onResult: @escaping @Sendable (String, Double) -> Void,
         onFailure: @escaping @Sendable (String) -> Void) {
        self.onResult = onResult
        self.onFailure = onFailure
    }

    /// One classification window. Only the best label with a `DangerSound` mapping is forwarded;
    /// the mapping itself is checked again on the main actor against the *measured* label table.
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult else { return }
        var bestLabel = ""
        var bestConfidence = 0.0
        for c in classification.classifications {
            guard SoundAlerts.kind(for: c.identifier) != nil else { continue }
            if c.confidence > bestConfidence {
                bestLabel = c.identifier
                bestConfidence = c.confidence
            }
        }
        onResult(bestLabel, bestConfidence)
    }

    /// Analysis failed; the message reaches `SoundWatcher.lastError`.
    func request(_ request: SNRequest, didFailWithError error: Error) {
        onFailure("Sound analysis failed: \(error.localizedDescription)")
    }

    /// Stream ended (only on `removeAllRequests` here); nothing to do.
    func requestDidComplete(_ request: SNRequest) {}
}
