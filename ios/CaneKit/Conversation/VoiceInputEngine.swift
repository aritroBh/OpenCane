//
//  VoiceInputEngine.swift
//  CaneKit
//
//  Push-to-talk voice-to-text recognition for the conversational assistant.
//  Uses SFSpeechRecognizer (on-device when the phone supports it, Apple's server otherwise) and
//  coordinates with SpeechQueue under AGENTS.md Hard Rule 7.
//
//  Purpose:
//    · Captures user speech using the iPhone's built-in upward-facing microphone array.
//    · Maintains AirPods on high-bitrate stereo A2DP without degrading to 8 kHz mono Bluetooth HFP.
//    · Automatically silences the spatial audio beacon while listening, restoring .playback
//      and the beacon immediately upon release, end of utterance or timeout.
//    · Holds the speech channel while listening (`SpeechQueue.setVoiceHold`): route and
//      obstacle lines queue with their TTLs instead of talking over the dictation; `.safety`
//      still breaks through. Released before the answer is spoken.
//    · Ends listening on its own (`UtteranceEndDetector`, CaneKitLogic): a blind walker cannot see
//      "Listening…" and should not need a second press.
//    · Every press has an audible outcome: an answer, "I did not catch that.", or the reason it
//      could not listen. Silence is a bug here (AGENTS.md "make the invisible visible").
//
//  Owner: `AppModel.voiceInput`, built in `AppModel.init` with the app's `SpeechQueue` and
//  `BeaconEngine`. Callers: `AppModel.toggleVoiceInput(source:)` (GuideCard "Talk to OpenCane",
//  the Action Button's empty `TalkToOpenCaneIntent`) and `AppModel.startVoiceInput()` (AirPods
//  double nod — start only, never a toggle). AppModel installs `onTranscriptionFinalized` (→
//  `ConversationCoordinator.handleQuery`, then `finishProcessing()`), `shouldRestorePlaybackSession`
//  (false while `SoundWatcher` owns the microphone) and `onEvent` (→ trip log). GuideCard reads
//  `isListening`.
//
//  Threading / isolation:
//    · Main actor isolated (`@MainActor @Observable`).
//    · Real-time audio engine tap calls back on an audio thread; buffer relay is nonisolated Sendable.
//    · Recognition results are relayed through a nonisolated class that carries only Sendable
//      values into a main-actor hop (hard rule 1), mirroring `SoundResultsRelay`.
//    · ⚠ Every framework callback closure formed in a main-actor method must be `@Sendable` (or be
//      formed in a nonisolated relay): an inferred `@MainActor` closure invoked off main traps
//      (Step 24 physical-device crash; 23 crash reports pulled on 2026-09-12).
//
//  Tests: the numbers are in CaneKitLogic — `UtteranceEndTests` (1.5 s silence, 10 s cap, 0.25 s
//  tick), `SoundAlertsTests` (`MicrophoneStart` format retry). The engine itself (audio session,
//  recogniser, permissions) has no unit test; device test in CHANGELOG Steps 23–24 and 30.
//

import AVFoundation
import CaneKitLogic
import Foundation
import Observation
import Speech

/// Operational states of the voice input engine. Published as `VoiceInputEngine.state`; no view
/// reads it today (the UI keys off `isListening` and `ConversationCoordinator.isProcessing`).
enum VoiceInputState: Equatable, Sendable {
    /// Ready for a press. Also the state after a permission denial, a cancel, an empty transcript
    /// and `finishProcessing()`.
    case idle
    /// The microphone is open and no words have been recognised yet.
    case listening
    /// Words are arriving; `partialText` is the latest partial transcript.
    case recognizing(partialText: String)
    /// A non-empty transcript was handed to `onTranscriptionFinalized`; the owner is answering and
    /// must call `finishProcessing()` when done.
    case processing
    /// The last press failed; the message was already spoken at `.nav`. Left until the next
    /// successful start or `cancel()` (a later denial also resets to `.idle`).
    case error(String)
}

/// Bridges non-Sendable AVAudioPCMBuffer from the realtime audio tap to SFSpeechAudioBufferRecognitionRequest.
///
/// ⚠ Core Audio Tap Isolation:
/// `AVAudioNode.installTap` accepts an unannotated closure block executed on a realtime Core Audio thread.
/// Under Swift 6 with `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`, installing the tap from within a `@MainActor`
/// function infers the closure to be `@MainActor` isolated. When Core Audio invokes it off-main, the runtime
/// triggers `_swift_task_checkIsolatedSwift` and traps with SIGTRAP (`_dispatch_assert_queue_fail`).
/// By installing the tap from this `nonisolated` class method, the tap block is guaranteed nonisolated.
/// `@unchecked Sendable`: the only state is a weak reference set once in `init` and then only read
/// (from the audio thread). The request itself is not Sendable; this box is the one place that
/// crosses that line. (A nonisolated relay, not a main-actor class — hard rule 1's ban on
/// `@unchecked Sendable` is about main-actor classes.)
private nonisolated final class SpeechBufferBox: @unchecked Sendable {
    /// The request buffers are fed to. Weak so the tap closure (alive until `removeTap`) never keeps
    /// a finished request alive; `VoiceInputEngine.recognitionRequest` holds it strongly.
    private weak var request: SFSpeechAudioBufferRecognitionRequest?

    /// - Parameter request: the current press's recognition request.
    init(_ request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    /// Forwards one microphone buffer to the request; called on the Core Audio thread. A no-op once
    /// the request is gone.
    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    /// Installs the bus-0 tap (2048-frame buffers, `format` = the input node's validated output
    /// format). The closure is formed here, in a nonisolated method, so it is nonisolated — see the
    /// ⚠ note above. Caller: `VoiceInputEngine.startEngine(attempt:sessionField:)`.
    func installTap(on node: AVAudioNode, format: AVAudioFormat) {
        node.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
    }
}

/// Starts the `SFSpeechRecognitionTask` from a `nonisolated` context so its result handler is
/// **not** inferred `@MainActor` (the same trap `SpeechBufferBox` exists for), and forwards only
/// Sendable values — the formatted transcript, `isFinal`, an error description — into a
/// main-actor hop (AGENTS.md hard rule 1; the pattern is `SoundResultsRelay` in SoundWatcher).
/// `recognizer.queue` is `.main`, so the hop is one run-loop turn, never a thread change.
private nonisolated final class SpeechResultsRelay: Sendable {
    /// The main-actor sink, `VoiceInputEngine.recognitionUpdate` (captured weakly by the engine).
    private let onResult: @MainActor @Sendable (String, Bool, String?) -> Void

    /// - Parameter onResult: `(transcript, isFinal, errorDescription)`; `transcript` is "" when
    ///   the callback carried only an error. Runs on the main actor.
    init(onResult: @escaping @MainActor @Sendable (String, Bool, String?) -> Void) {
        self.onResult = onResult
    }

    /// Creates the task. Synchronous, so the non-Sendable recogniser and request never cross an
    /// isolation boundary; only the closure formed here escapes, and it is nonisolated.
    func start(_ recognizer: SFSpeechRecognizer, _ request: SFSpeechAudioBufferRecognitionRequest)
        -> SFSpeechRecognitionTask {
        let onResult = self.onResult
        return recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString ?? ""
            let final = result?.isFinal ?? false
            let message = error?.localizedDescription
            Task { @MainActor in onResult(text, final, message) }
        }
    }
}

/// Push-to-talk voice recognition controller. Owned by `AppModel`.
///
/// Lifecycle of one press (`startListening`): speech authorisation → microphone permission →
/// `.playAndRecord` session (hard rule 7 exception) → beacon off → recogniser task → engine → the
/// end ticker. Listening ends on the first of: a second press (`stopListeningAndSubmit`), the
/// transcript unchanged for `UtteranceEndDetector.silenceAfterSpeech`, the `maxListen` cap, a
/// final result, or a recogniser error. Every end is spoken or answered; `voice_start` /
/// `voice_end` trip-log events (`onEvent`) say what the engine saw.
@MainActor
@Observable
final class VoiceInputEngine {

    // MARK: - Published State
    /// Where the engine is in a press (see `VoiceInputState`). Not read by any view today.
    private(set) var state: VoiceInputState = .idle
    /// True from a successful engine start until `cleanupAudioPipeline` (submit, silence, cap,
    /// final, error, cancel). Not true while waiting for a permission prompt or the format retry.
    /// GuideCard shows "Listening…" from it; `AppModel.toggleVoiceInput` decides start vs submit.
    private(set) var isListening: Bool = false
    /// The latest (partial) transcript of the current press; "" at each start. Kept after the
    /// press ends until the next start.
    private(set) var latestTranscript: String = ""

    // MARK: - Dependencies
    /// The app's speech channel: microphone lease (`setMicrophoneEnabled(_:owner: .voiceInput)`),
    /// the voice hold, and every spoken outcome. `unowned`: `AppModel` owns both and outlives this.
    private unowned let speech: SpeechQueue
    /// The spatial beacon, silenced while listening and restored to `previousBeaconEnabled` after.
    private unowned let beacon: BeaconEngine
    /// en-US recogniser (nil if the locale is unsupported), delivering on the main queue.
    private let recognizer: SFSpeechRecognizer?

    // MARK: - Internal Audio Pipeline
    /// One engine reused across presses (Step 24: engine reuse); its input node is the phone mic
    /// while the session is `.playAndRecord` with A2DP output.
    @ObservationIgnored private let engine = AVAudioEngine()
    /// The tap's nonisolated buffer relay for the current press; nil between presses.
    @ObservationIgnored private var bufferBox: SpeechBufferBox?
    /// Strong reference to the results relay for the current press; nil between presses.
    @ObservationIgnored private var resultsRelay: SpeechResultsRelay?
    /// The current press's streaming request (partial results on; on-device when supported).
    /// Set before the format check so the retry can reuse it; `endAudio()`ed on teardown.
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    /// The running recognition task; cancelled on teardown (its late callbacks are ignored
    /// because `isListening` is already false).
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    /// Polls `UtteranceEndDetector` every `checkInterval` while listening; also owns the cap.
    @ObservationIgnored private var endTicker: Task<Void, Never>?
    /// The current press's end-of-utterance state machine (value type: copy → update → write back
    /// in `checkEnd`); nil between presses.
    @ObservationIgnored private var endDetector: UtteranceEndDetector?
    /// The one settle wait between input-format reads (`startEngine(attempt:)`); non-nil only
    /// while a press is waiting for the route, when the session is already `.playAndRecord` and
    /// the beacon already off, so `cancel()` and a second press must treat it as live.
    @ObservationIgnored private var formatRetry: Task<Void, Never>?
    /// `beacon.enabled` as it was when this press began (snapshotted at the top of
    /// `startListening`, before any failure path can run the teardown that restores it). Muse
    /// Step 23 finding 4: beacon state saved and restored across voice sessions.
    @ObservationIgnored private var previousBeaconEnabled: Bool = false
    /// Bumped on every successful engine start and every `cancel()` so a permission prompt (or a
    /// format-retry wait) answered after `cancel()` cannot start the microphone behind the
    /// walker's back (same fence as `SoundWatcher.generation`).
    @ObservationIgnored private var generation = 0
    /// `Date().timeIntervalSinceReferenceDate` when the engine started, for `voice_end` timing.
    @ObservationIgnored private var listeningSince: Double = 0

    // MARK: - Callbacks & Coordination
    /// Delivered on the main actor when transcription is finalized with a non-empty prompt. The
    /// owner must call `finishProcessing()` when its reply is done so `state` leaves `.processing`.
    var onTranscriptionFinalized: ((String) -> Void)?
    /// Checked on teardown; returns false if another microphone feature (SoundWatcher) is live.
    /// nil (not wired) is treated as true: the session is restored to `.playback`.
    var shouldRestorePlaybackSession: (() -> Bool)?
    /// Diagnostics for the trip log: `("voice_start" | "voice_end", fields)`. Wired by `AppModel`
    /// to `logger.event`. Field names never include `t` or `kind` (`TripLogRecord` owns those).
    var onEvent: ((String, [String: Any]) -> Void)?

    /// - Parameters:
    ///   - speech: the app's `SpeechQueue` (held unowned).
    ///   - beacon: the app's `BeaconEngine` (held unowned).
    /// Creates the en-US recogniser; asks for no permission (that happens on the first press).
    init(speech: SpeechQueue, beacon: BeaconEngine) {
        self.speech = speech
        self.beacon = beacon
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        // Explicit, not assumed: the result handler's main-actor hop is cheap only because the
        // recogniser already calls back on main.
        self.recognizer?.queue = .main
    }

    // MARK: - Control

    /// Starts speech recognition. Acquires SpeechQueue's `.playAndRecord` microphone lease for
    /// push-to-talk, preserving A2DP and rejecting the start if SoundWatcher already owns it.
    ///
    /// Permissions come first, and both are asked for explicitly: without speech authorisation the
    /// recognition task errors immediately, the transcript stays empty, and the old engine went
    /// back to `.idle` without a word — the walker heard nothing at all after the tick. A denial
    /// is spoken once at `.nav` and the engine stays `.idle` (hard rule 4 spirit: never crash,
    /// never go quiet, say what is missing). A prompt that is still up when the walker presses
    /// again is fenced by `generation`.
    func startListening() {
        // A press during the format settle wait is the same press: the session and beacon are
        // already taken, and re-snapshotting the beacon here would remember it as off.
        guard !isListening, formatRetry == nil else { return }
        // Snapshot the beacon now: every failure below runs `cleanupAudioPipeline`, which puts
        // this value back, and a stale one from an earlier run would switch the beacon off.
        previousBeaconEnabled = beacon.enabled

        // 0. Speech authorisation (SFSpeechRecognizer), then microphone permission.
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            break
        case .notDetermined:
            let generation = self.generation
            // `@Sendable` so the closure is nonisolated whatever queue Speech answers on.
            SFSpeechRecognizer.requestAuthorization { @Sendable [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    if status == .authorized { self.startListening() } else {
                        self.denied(speech: true)
                    }
                }
            }
            return
        case .denied, .restricted:
            denied(speech: true)
            return
        @unknown default:
            break
        }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            break
        case .undetermined:
            let generation = self.generation
            // ⚠ `@Sendable`: the SDK says this block "may be called in a different thread
            // context" and its type is not NS_SWIFT_SENDABLE, so without it the closure is
            // inferred @MainActor and would trap off-main (the mechanism behind all 23 crash
            // reports pulled from the phone on 2026-09-12; see SoundWatcher / TripTracker).
            AVAudioApplication.requestRecordPermission { @Sendable [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    if granted { self.startListening() } else { self.denied(speech: false) }
                }
            }
            return
        case .denied:
            denied(speech: false)
            return
        @unknown default:
            break
        }
        // Availability is read after the permissions on purpose: a recogniser that is unavailable
        // *because* it is unauthorised must lead to the prompt, not to this line.
        guard let recognizer, recognizer.isAvailable else {
            logStart(session: "recognizer_unavailable", format: nil)
            fail(with: "Speech recognition is not available right now.")
            return
        }

        // 1. Activate microphone session via SpeechQueue (Hard Rule 7)
        let sessionField: String
        switch speech.setMicrophoneEnabled(true, owner: .voiceInput) {
        case .granted(let route):
            sessionField = "granted:\(route)"
        case .revertedRouteChanged(let before, let after):
            logStart(session: "reverted:\(before)>\(after)", format: nil)
            fail(with: "Listening would change your headphone sound, so it stayed off.")
            return
        case .failed(let err):
            logStart(session: "failed:\(err)", format: nil)
            fail(with: "The microphone could not start.")
            return
        }

        // 2. Silence spatial audio beacon (its previous state was captured at the top)
        beacon.enabled = false

        // 3. Configure recognition request. On-device when the phone has the model; otherwise the
        //    flag is left off and Apple's server recognises (needs network) — never a silent fail.
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.recognitionRequest = request
        self.latestTranscript = ""

        startEngine(attempt: 0, sessionField: sessionField)
    }

    /// Read the microphone's input format and, once it is real, install the tap and start the
    /// engine and the end ticker.
    ///
    /// Split out of `startListening()` for the same reason as `SoundWatcher.startEngine`: right
    /// after the session went `.playAndRecord` iOS is still settling the route, so the first read
    /// can answer 0 Hz / 0 channels — typically the first-ever press with AirPods. The format check
    /// cannot go (`installTap` traps on an invalid format), so it is re-read once after
    /// `MicrophoneStart.formatRetryDelay` (CaneKitLogic; `SoundAlertsTests` own the numbers) and
    /// only then does the walker hear "not ready yet". A `cancel()` during the wait is honoured by
    /// `generation`, and the final failure tears down exactly as a first-read failure did.
    /// - Parameters:
    ///   - attempt: zero-based; `MicrophoneStart.retryDelay(afterAttempt:)` decides whether there
    ///     is another one.
    ///   - sessionField: the `session` value for `voice_start`, decided by `startListening()`.
    private func startEngine(attempt: Int, sessionField: String) {
        guard let recognizer, let request = recognitionRequest else { return }
        // 4. Configure audio engine tap. `prepare()` realises the input node against the now-active
        //    session; only on a retry so the happy path is untouched.
        if attempt > 0 { engine.prepare() }
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        let formatField = "\(Int(recordingFormat.sampleRate))Hz x\(recordingFormat.channelCount)"
            + (attempt > 0 ? " (retry)" : "")
        guard MicrophoneStart.isUsableInputFormat(sampleRate: recordingFormat.sampleRate, channels: recordingFormat.channelCount) else {
            guard let delay = MicrophoneStart.retryDelay(afterAttempt: attempt) else {
                logStart(session: sessionField, format: formatField)
                fail(with: "The microphone is not ready yet. Try again.")
                return
            }
            let generation = self.generation
            formatRetry = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                self.formatRetry = nil
                self.startEngine(attempt: attempt + 1, sessionField: sessionField)
            }
            return
        }

        let box = SpeechBufferBox(request)
        self.bufferBox = box
        box.installTap(on: inputNode, format: recordingFormat)

        // 5. Start recognition task through the nonisolated relay (hard rule 1).
        let relay = SpeechResultsRelay { [weak self] text, isFinal, error in
            self?.recognitionUpdate(text: text, isFinal: isFinal, error: error)
        }
        self.resultsRelay = relay
        self.recognitionTask = relay.start(recognizer, request)

        do {
            engine.prepare()
            try engine.start()
        } catch {
            logStart(session: sessionField, format: formatField)
            fail(with: "The microphone could not start.")
            return
        }
        generation += 1
        isListening = true
        state = .listening
        listeningSince = Date().timeIntervalSinceReferenceDate
        // Hold the speech channel: route and obstacle chatter queues instead of talking over
        // the dictation (and the recogniser never hears the app's own voice). `.safety` still
        // breaks through. Released in `cleanupAudioPipeline`, before any answer is spoken.
        speech.setVoiceHold(true)
        logStart(session: sessionField, format: formatField)
        AudioServicesPlaySystemSound(1519) // Crisp tactile feedback confirms recording started

        // 6. End-of-utterance + hard cap, both decided by `UtteranceEndDetector` (CaneKitLogic).
        endDetector = UtteranceEndDetector(startedAt: listeningSince)
        endTicker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(UtteranceEndDetector.checkInterval))
                guard !Task.isCancelled, let self, self.isListening else { return }
                switch self.checkEnd() {
                case .listening: continue
                case .endOfUtterance: self.stopListeningAndSubmit(reason: "silence"); return
                case .timeout: self.stopListeningAndSubmit(reason: "timeout"); return
                }
            }
        }
    }

    /// One recogniser callback, already on the main actor. Updates the partial transcript and
    /// ends listening on a final result or an error (with whatever words arrived — an error
    /// after a good transcript still answers the question).
    private func recognitionUpdate(text: String, isFinal: Bool, error: String?) {
        guard isListening else { return }
        if !text.isEmpty {
            latestTranscript = text
            state = .recognizing(partialText: text)
        }
        if let error {
            stopListeningAndSubmit(reason: "error:\(error)")
        } else if isFinal {
            stopListeningAndSubmit(reason: "final")
        } else if checkEnd() == .endOfUtterance {
            stopListeningAndSubmit(reason: "silence")
        }
    }

    /// Feed the detector the latest transcript and the clock (`timeIntervalSinceReferenceDate`, the
    /// same clock as `listeningSince`). `.listening` when no detector exists (not listening).
    private func checkEnd() -> UtteranceEndDetector.Verdict {
        guard var detector = endDetector else { return .listening }
        let verdict = detector.update(transcript: latestTranscript, now: Date().timeIntervalSinceReferenceDate)
        endDetector = detector
        return verdict
    }

    /// Second press: stops listening, cleans up audio, restores .playback session, and delivers
    /// the finalized prompt. Also the shared end path for silence / cap / final / error.
    /// Teardown (which releases the speech hold) runs *before* the prompt is delivered, so the
    /// answer is never held behind the walker's own dictation. An empty transcript speaks
    /// "I did not catch that." (`.scene`, ttl 6, immediate). No-op unless listening.
    /// - Parameter reason: written to `voice_end` — "press" | "silence" | "timeout" | "final" |
    ///   "error:<text>".
    func stopListeningAndSubmit(reason: String = "press") {
        guard isListening else { return }
        let finalPrompt = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanupAudioPipeline()
        logEnd(reason: reason, transcriptLength: finalPrompt.count)

        if !finalPrompt.isEmpty {
            state = .processing
            onTranscriptionFinalized?(finalPrompt)
        } else {
            state = .idle
            // The one line a blind walker needs most: proof the press was heard and nothing else was.
            // `immediate`: no TTS fetch wait on the most time-critical confirmation in the app.
            speech.say("I did not catch that.", .scene, ttl: 6, immediate: true)
        }
    }

    /// The owner's reply to the last transcript is finished (spoken or failed): back to `.idle`
    /// so the next press starts clean. No-op unless the engine is `.processing` — a press that
    /// began listening again meanwhile is not disturbed. Caller: `AppModel`'s
    /// `onTranscriptionFinalized` wiring.
    func finishProcessing() {
        if state == .processing { state = .idle }
    }

    /// Cancels listening without submitting; also voids a permission prompt still on screen.
    /// Speaks nothing; logs `voice_end` with reason "cancel" only if it was listening. No caller
    /// today (AppModel's background path does not cancel a press) — kept for that teardown.
    func cancel() {
        generation += 1
        if isListening {
            cleanupAudioPipeline()
            logEnd(reason: "cancel", transcriptLength: latestTranscript.count)
        } else if formatRetry != nil {
            // Waiting for the input format: the session and beacon are already taken, give them back.
            cleanupAudioPipeline()
        }
        state = .idle
    }

    // MARK: - Teardown

    /// The one teardown for every exit (submit, silence, cap, final, error, cancel, failed start,
    /// format-retry wait): release the speech hold, stop the end ticker and any format retry,
    /// remove the tap and stop the engine, end and cancel recognition, give the microphone lease
    /// back (unless `shouldRestorePlaybackSession` says SoundWatcher still needs `.playAndRecord`),
    /// and restore the beacon to `previousBeaconEnabled`. Safe to call when nothing was started.
    /// Does not change `state` — callers set it.
    private func cleanupAudioPipeline() {
        isListening = false
        // Release the speech hold first. The failure line / "I did not catch that." / answer
        // spoken right after this still plays before anything older: the release drains the
        // queue's head first (a still-valid held line is higher-priority guidance, correctly
        // first), then the fresh line. Nothing is ever stuck behind the hold itself.
        // Idempotent: safe on paths where the hold was never set (permission wait, teardown).
        speech.setVoiceHold(false)
        endTicker?.cancel()
        endTicker = nil
        endDetector = nil
        formatRetry?.cancel()
        formatRetry = nil

        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }

        bufferBox = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        resultsRelay = nil

        // Restore .playback audio session if no other microphone feature (like SoundWatcher) is using it
        if let shouldRestore = shouldRestorePlaybackSession, shouldRestore() {
            _ = speech.setMicrophoneEnabled(false, owner: .voiceInput)
        } else if shouldRestorePlaybackSession == nil {
            _ = speech.setMicrophoneEnabled(false, owner: .voiceInput)
        }

        // Restore beacon state to previous setting
        beacon.enabled = previousBeaconEnabled
    }

    /// A permission is missing: say so once at `.nav`, log it, stay `.idle`. The wording tells the
    /// walker (or the sighted helper) which switch to find in Settings.
    /// Nothing was acquired yet on this path (permissions come before the session and beacon), so
    /// it needs no teardown. Logs `voice_start` with `session` "speech_denied" / "record_denied".
    /// - Parameter isSpeechPermission: true for Speech Recognition, false for the microphone.
    private func denied(speech isSpeechPermission: Bool) {
        let line = isSpeechPermission
            ? "Speech recognition is off for OpenCane. Allow it in Settings to talk to me."
            : "The microphone is off for OpenCane. Allow it in Settings to talk to me."
        logStart(session: isSpeechPermission ? "speech_denied" : "record_denied", format: nil)
        state = .idle
        speech.say(line, .nav, ttl: 8)
    }

    /// Tear down and tell the walker why, at `.nav` so it is not lost behind a scene line. The
    /// message is short and already user-facing; the technical reason goes to the trip log via
    /// `voice_start`'s `session` / `format` fields (callers log before calling this).
    /// - Parameter message: the spoken, user-facing reason; also stored in `state` as `.error`.
    private func fail(with message: String) {
        cleanupAudioPipeline()
        state = .error(message)
        speech.say(message, .nav, ttl: 8)
    }

    // MARK: - Trip log

    /// `voice_start`: what the engine saw when the press arrived, so a silent phone can be read
    /// back from the log (`recognizer`, `on_device`, `speech_auth`, `record`, `format`, `session`).
    /// Written once per press outcome: on success, and on every failure path before it speaks.
    /// - Parameters:
    ///   - session: "granted:<route>", "reverted:<before>><after>", "failed:<error>",
    ///     "recognizer_unavailable", "speech_denied" or "record_denied".
    ///   - format: "<Hz>Hz x<channels>" (+ " (retry)"), or nil before the input was read ("").
    private func logStart(session: String, format: String?) {
        let auth: String
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: auth = "authorized"
        case .denied: auth = "denied"
        case .restricted: auth = "restricted"
        case .notDetermined: auth = "notDetermined"
        @unknown default: auth = "unknown"
        }
        let record: String
        switch AVAudioApplication.shared.recordPermission {
        case .granted: record = "granted"
        case .denied: record = "denied"
        case .undetermined: record = "undetermined"
        @unknown default: record = "unknown"
        }
        onEvent?("voice_start", [
            "recognizer": recognizer?.isAvailable ?? false,
            "on_device": recognizer?.supportsOnDeviceRecognition ?? false,
            "speech_auth": auth,
            "record": record,
            "format": format ?? "",
            "session": session,
        ])
    }

    /// `voice_end`: why listening stopped, how long it ran and how many characters were heard.
    /// Fields: `reason` ("press" | "silence" | "timeout" | "final" | "error:<text>" | "cancel"),
    /// `transcript_length` (characters, trimmed for a submit), `seconds` (3 dp since the engine
    /// started). Tune `UtteranceEndDetector.silenceAfterSpeech` from these, not by feel.
    private func logEnd(reason: String, transcriptLength: Int) {
        let seconds = Date().timeIntervalSinceReferenceDate - listeningSince
        onEvent?("voice_end", [
            "reason": reason,
            "transcript_length": transcriptLength,
            "seconds": (seconds * 1000).rounded() / 1000,
        ])
    }
}
