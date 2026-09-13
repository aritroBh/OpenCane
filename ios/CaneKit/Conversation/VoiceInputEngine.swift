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
//      still breaks through. Set just *before* the microphone lease (Step 55: the line playing is cut
//      before the microphone can hear it), released before the answer is spoken.
//    · Never answers itself (Step 55; the first mounted walk logged `conv_error query: "Head
//      height"`): while `SpeechQueue.isSpeaking` — a `.safety` line breaking through the hold — and
//      for `SelfHearFilter.tailSeconds` after, the tap drops microphone buffers (`SpeechBufferBox`, a
//      `Mutex<Bool>` read on the audio thread, no actor hop); and a final transcript equal to a line
//      the app dispatched while listening, or one clause of it (`SelfHearFilter`), is dropped
//      silently. Both log `voice_self_hear {action: paused | dropped, pause_ms, transcript,
//      matched_line}`. No audio-session change (hard rule 7: no `.voiceChat`, no echo control).
//    · Ends listening on its own (`UtteranceEndDetector`, CaneKitLogic): a blind walker cannot see
//      "Listening…" and should not need a second press.
//    · Every press has an audible outcome: an answer, a tone (Step 65 — rising when the mic opens,
//      a tap when it heard words, a falling note when it heard nothing, with "I did not catch
//      that." on the second empty press in a row), or the reason it could not listen. Silence is a
//      bug here (AGENTS.md "make the invisible visible").
//
//  Owner: `AppModel.voiceInput`, built in `AppModel.init` with the app's `SpeechQueue` and
//  `BeaconEngine`. Callers: `AppModel.toggleVoiceInput(source:)` (GuideCard "Talk to OpenCane",
//  the Action Button's empty `TalkToOpenCaneIntent`) and `AppModel.startVoiceInput()` (AirPods
//  double nod — start only, never a toggle). AppModel installs `onTranscriptionFinalized` (→
//  `ConversationCoordinator.handleQuery`, then `finishProcessing()`), `shouldRestorePlaybackSession`
//  (false while `SoundWatcher` owns the microphone) and `onEvent` (→ trip log), and forwards every
//  dispatched line from `SpeechQueue.onDispatch` to `noteDispatched`. This engine installs
//  `SpeechQueue.onSpeakingChanged` itself. GuideCard reads `isListening`.
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
//  tick), `SoundAlertsTests` (`MicrophoneStart` format retry), `SelfHearFilterTests` (3 s window,
//  0.3 s tail, whole line or clause, never "contains"). The engine itself (audio session,
//  recogniser, permissions) has no unit test; device test in CHANGELOG Steps 23–24 and 30.
//

import AVFoundation
import CaneKitLogic
import Foundation
import Observation
import Speech
import Synchronization

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
/// `@unchecked Sendable`: the state is a weak reference set once in `init` and then only read
/// (from the audio thread), and the `paused` flag, which is a `Mutex` (written on main, read on the
/// audio thread). The request itself is not Sendable; this box is the one place that crosses that
/// line. (A nonisolated relay, not a main-actor class — hard rule 1's ban on `@unchecked Sendable`
/// is about main-actor classes.)
private nonisolated final class SpeechBufferBox: @unchecked Sendable {
    /// The request buffers are fed to. Weak so the tap closure (alive until `removeTap`) never keeps
    /// a finished request alive; `VoiceInputEngine.recognitionRequest` holds it strongly.
    private weak var request: SFSpeechAudioBufferRecognitionRequest?
    /// True while the app is speaking (+ the 0.3 s tail): buffers are dropped, so the recogniser
    /// never hears OpenCane's own voice (Step 55). A `Mutex` read inside the tap — never an actor hop
    /// from the Core Audio thread (the Step 24 SIGTRAP rule in the ⚠ note above).
    private let paused = Mutex(false)

    /// - Parameter request: the current press's recognition request.
    init(_ request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    /// Pause (`true`) or resume (`false`) forwarding. Called on main by
    /// `VoiceInputEngine.speakingChanged` / `endSelfHearPause`.
    func setPaused(_ value: Bool) {
        paused.withLock { $0 = value }
    }

    /// Forwards one microphone buffer to the request; called on the Core Audio thread. A no-op once
    /// the request is gone or while paused.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard !paused.withLock({ $0 }) else { return }
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

    /// True while a permission prompt or audio graph is being negotiated. The Guide card exposes
    /// this state so a second tap cancels a pending start instead of silently re-arming it.
    private(set) var isStarting: Bool = false

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
    /// This listen's hard cap and style (Step 58). nil = a press: `UtteranceEndDetector.maxListen`
    /// and the falling `Earcon.nothing` when nothing is said (Step 65). A number = an unasked-for window opened by
    /// the voice shell (launch or follow-up): that cap, and silence when nothing is said — the walker
    /// did not press anything, so there is nothing to apologise for.
    @ObservationIgnored private var windowSeconds: Double?
    /// Who opened this listen (Step 65): picks the listening cue's level and whether an empty close
    /// makes any sound (`EarconPolicy`). Set by `startListening(windowSeconds:kind:)`.
    @ObservationIgnored private var listenKind: EarconPolicy.ListenKind = .press
    /// Empty presses in a row, 1, 2, 1, 2 … (`EarconPolicy.emptyPressCount`); the words "I did not
    /// catch that." come only on the second. Reset by a press that heard words.
    @ObservationIgnored private var emptyPressCount = 0
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
    /// Task polling permission and engine health for the full capture lifetime.
    @ObservationIgnored private var permissionWatchTask: Task<Void, Never>?
    /// Observer for graph invalidation events that do not always produce a recognizer error.
    @ObservationIgnored private var engineConfigurationObserver: NSObjectProtocol?
    /// Pure lifecycle guard; all state lives on the main actor and only Sendable snapshots enter it.
    @ObservationIgnored private var lifecycle = VoiceInputGuard()
    /// Generation fencing for permission and live-capture callbacks.
    @ObservationIgnored private var pendingPermissionGeneration: UInt64?
    @ObservationIgnored private var activeGeneration: UInt64?
    @ObservationIgnored private var nextGeneration: UInt64 = 0
    /// True only after this engine successfully acquired the shared microphone lease.
    @ObservationIgnored private var microphoneLeaseAcquired = false
    /// `Date().timeIntervalSinceReferenceDate` when the engine started, for `voice_end` timing.
    @ObservationIgnored private var listeningSince: Double = 0
    /// The lines the app dispatched during this press (`noteDispatched`), and the rule that says a
    /// final transcript is one of them (CaneKitLogic `SelfHearFilter`, Step 55). Reset per press.
    @ObservationIgnored private var selfHear = SelfHearFilter()
    /// When the tap was paused because the app started speaking (reference-date seconds); nil while
    /// buffers flow. `endSelfHearPause` logs the pause length from it.
    @ObservationIgnored private var selfHearPausedSince: Double?
    /// The `SelfHearFilter.tailSeconds` wait after the app stops speaking; cancelled when it speaks
    /// again or the press ends.
    @ObservationIgnored private var selfHearTail: Task<Void, Never>?

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

        // Step 55: the one `onSpeakingChanged` listener; it acts only while a press is listening.
        speech.onSpeakingChanged = { [weak self] speaking in self?.speakingChanged(speaking) }
    }

    /// A line was handed to a voice backend (`SpeechQueue.onDispatch`, forwarded by `AppModel`).
    /// Remembered for `SelfHearFilter` only while this engine is starting or listening: a line
    /// dispatched before the press — the launch menu, an answer — must never make the walker's own
    /// reply to it ("status") look like an echo.
    /// - Parameter text: the whole dispatched line.
    func noteDispatched(_ text: String) {
        guard isListening || isStarting else { return }
        selfHear.record(line: text, at: Date().timeIntervalSinceReferenceDate)
    }

    /// `SpeechQueue.isSpeaking` changed (Step 55). While listening: speaking → pause the tap at once
    /// (the hold lets only `.safety` through, so this is a warning breaking in); not speaking → keep
    /// it paused for `SelfHearFilter.tailSeconds` (the player's end callback and the AirPods path lag
    /// the last sample), then resume if nothing started meanwhile. Ignored when not listening.
    /// - Parameter speaking: the new `isSpeaking`.
    private func speakingChanged(_ speaking: Bool) {
        guard isListening, let box = bufferBox else { return }
        if speaking {
            selfHearTail?.cancel()
            selfHearTail = nil
            guard selfHearPausedSince == nil else { return }
            selfHearPausedSince = Date().timeIntervalSinceReferenceDate
            box.setPaused(true)
            return
        }
        guard selfHearPausedSince != nil else { return }
        selfHearTail?.cancel()
        let run = activeGeneration
        selfHearTail = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(SelfHearFilter.tailSeconds))
            guard !Task.isCancelled, let self, self.activeGeneration == run,
                  !self.speech.isSpeaking else { return }
            self.endSelfHearPause()
        }
    }

    /// Resume the tap and log `voice_self_hear {action: paused, pause_ms}` (the whole pause, tail
    /// included). No-op when not paused. Callers: the tail task, and `cleanupAudioPipeline` (a press
    /// that ends mid-pause still logs its pause).
    private func endSelfHearPause() {
        selfHearTail?.cancel()
        selfHearTail = nil
        guard let since = selfHearPausedSince else { return }
        selfHearPausedSince = nil
        bufferBox?.setPaused(false)
        onEvent?("voice_self_hear", [
            "action": "paused",
            "pause_ms": Int(((Date().timeIntervalSinceReferenceDate - since) * 1000).rounded()),
        ])
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
    func startListening(windowSeconds: Double? = nil, kind: EarconPolicy.ListenKind? = nil) {
        // A press during the format settle wait is the same press: the session and beacon are
        // already taken, and re-snapshotting the beacon here would remember it as off.
        guard !isListening, formatRetry == nil, !isStarting else { return }
        self.windowSeconds = windowSeconds
        listenKind = kind ?? (windowSeconds == nil ? .press : .followUp)
        // A new press starts with an empty self-hear history (Step 55).
        selfHear.reset()
        // Snapshot the beacon now: every failure below runs `cleanupAudioPipeline`, which puts
        // this value back, and a stale one from an earlier run would switch the beacon off.
        previousBeaconEnabled = beacon.enabled

        // Fence every asynchronous permission callback to this explicit request. The pending
        // state is observable so the Guide button can cancel it instead of starting twice.
        isStarting = true
        guard let permissionGeneration = lifecycle.beginPermissionRequest() else {
            isStarting = false
            return
        }
        pendingPermissionGeneration = permissionGeneration
        nextGeneration &+= 1

        // 0. Speech authorisation (SFSpeechRecognizer), then microphone permission.
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            continueRecordAuthorization(generation: permissionGeneration)
            return
        case .notDetermined:
            // `@Sendable` so the closure is nonisolated whatever queue Speech answers on.
            SFSpeechRecognizer.requestAuthorization { @Sendable [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self, self.pendingPermissionGeneration == permissionGeneration else { return }
                    if status == .authorized {
                        self.continueRecordAuthorization(generation: permissionGeneration)
                    } else {
                        self.resolvePermissions(granted: false, generation: permissionGeneration)
                    }
                }
            }
            return
        case .denied, .restricted:
            resolvePermissions(granted: false, generation: permissionGeneration)
            return
        @unknown default:
            break
        }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            continueRecordAuthorization(generation: permissionGeneration)
            return
        case .undetermined:
            // ⚠ `@Sendable`: the SDK says this block "may be called in a different thread
            // context" and its type is not NS_SWIFT_SENDABLE, so without it the closure is
            // inferred @MainActor and would trap off-main (the mechanism behind all 23 crash
            // reports pulled from the phone on 2026-09-12; see SoundWatcher / TripTracker).
            AVAudioApplication.requestRecordPermission { @Sendable [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self, self.pendingPermissionGeneration == permissionGeneration else { return }
                    self.resolvePermissions(granted: granted, generation: permissionGeneration)
                }
            }
            return
        case .denied:
            resolvePermissions(granted: false, generation: permissionGeneration)
            return
        @unknown default:
            resolvePermissions(granted: false, generation: permissionGeneration)
            return
        }

    }

    /// Completes microphone authorization after Speech permission is known.
    private func continueRecordAuthorization(generation: UInt64) {
        guard pendingPermissionGeneration == generation else { return }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            resolvePermissions(granted: true, generation: generation)
        case .undetermined:
            AVAudioApplication.requestRecordPermission { @Sendable [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self, self.pendingPermissionGeneration == generation else { return }
                    self.resolvePermissions(granted: granted, generation: generation)
                }
            }
        case .denied:
            resolvePermissions(granted: false, generation: generation)
        @unknown default:
            resolvePermissions(granted: false, generation: generation)
        }
    }

    /// Resolves the combined permission gate exactly once and enters microphone setup only for the
    /// current generation. Denials use the existing spoken failure channel.
    private func resolvePermissions(granted: Bool, generation: UInt64) {
        guard pendingPermissionGeneration == generation else { return }
        let decision = lifecycle.permissionResolved(granted: granted, generation: generation)
        guard case .continueRunning = decision else {
            pendingPermissionGeneration = nil
            if case .stop = decision { fail(with: failureMessage(for: decision)) }
            return
        }
        startAuthorizedListening(permissionGeneration: generation)
    }

    /// Acquires the shared microphone lease after both permissions are confirmed. Callbacks are
    /// installed before activation so a route move or interruption during setup cannot be missed.
    private func startAuthorizedListening(permissionGeneration: UInt64) {
        guard pendingPermissionGeneration == permissionGeneration else { return }
        pendingPermissionGeneration = nil
        guard lifecycle.beginStart() else { return }
        nextGeneration &+= 1
        let runGeneration = nextGeneration
        activeGeneration = runGeneration
        speech.onVoiceInputRouteChanged = { [weak self] before, after in
            self?.voiceInputRouteChanged(before: before, after: after, generation: runGeneration)
        }
        speech.onVoiceInputInterruption = { [weak self] event in
            self?.voiceInputInterruption(event, generation: runGeneration)
        }
        // Step 55: hold the speech channel *before* the microphone opens. The hold cuts the line
        // playing unless it is `.safety` (re-queued from its last resume point) and queues every
        // later sub-safety line, so the recogniser never starts on the app's own voice. Every failure
        // below runs `cleanupAudioPipeline`, which releases it.
        speech.setVoiceHold(true)

        let sessionField: String
        switch speech.setMicrophoneEnabled(true, owner: .voiceInput) {
        case .granted(let route):
            sessionField = "granted:\(route)"
            microphoneLeaseAcquired = true
        case .revertedRouteChanged:
            logStart(session: "reverted_route", format: nil)
            fail(with: "Voice input stopped because the audio route changed.")
            return
        case .failed(let err):
            logStart(session: "failed:\(err)", format: nil)
            fail(with: "The microphone could not start.")
            return
        }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            fail(with: "Voice input stopped because microphone access was revoked.")
            return
        }
        guard let route = speech.microphoneRouteSnapshot else {
            fail(with: "Voice input stopped because the microphone is unavailable.")
            return
        }
        let sessionDecision = lifecycle.sessionStarted(route: route)
        guard case .continueRunning = sessionDecision else {
            fail(with: failureMessage(for: sessionDecision))
            return
        }
        beacon.enabled = false
        guard let recognizer else { fail(with: "Speech recognition is not available right now."); return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        recognitionRequest = request
        latestTranscript = ""
        startEngine(attempt: 0, sessionField: sessionField, generation: runGeneration)
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
    private func startEngine(attempt: Int, sessionField: String, generation runGeneration: UInt64) {
        guard activeGeneration == runGeneration, lifecycle.isActive else { return }
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
            formatRetry = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self,
                      self.activeGeneration == runGeneration,
                      self.lifecycle.isActive else { return }
                self.formatRetry = nil
                self.startEngine(attempt: attempt + 1, sessionField: sessionField, generation: runGeneration)
            }
            return
        }

        let box = SpeechBufferBox(request)
        self.bufferBox = box
        box.installTap(on: inputNode, format: recordingFormat)

        // A graph reconfiguration can invalidate the tap without a recognizer callback. Observe it
        // for the full run and fence the callback to this capture generation.
        engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.audioEngineConfigurationChanged(generation: runGeneration)
            }
        }

        // Publish the live state before creating the recognition task: Apple's callback can report
        // an error synchronously, and that error must take the hard-stop path rather than vanish.
        isListening = true
        state = .listening
        // A `.safety` line may already be playing through the hold: the tap starts paused (Step 55).
        if speech.isSpeaking { speakingChanged(true) }

        // 5. Start recognition task through the nonisolated relay (hard rule 1).
        let relay = SpeechResultsRelay { [weak self] text, isFinal, error in
            self?.recognitionUpdate(text: text, isFinal: isFinal, error: error, generation: runGeneration)
        }
        self.resultsRelay = relay
        self.recognitionTask = relay.start(recognizer, request)

        do {
            engine.prepare()
            try engine.start()
        } catch {
            logStart(session: sessionField, format: formatField)
            let decision = lifecycle.recognitionFailed()
            if case .stop = decision { fail(with: failureMessage(for: decision)) }
            return
        }
        let liveRoute = speech.microphoneRouteSnapshot
        let recognitionDecision: VoiceInputDecision
        if let liveRoute {
            recognitionDecision = lifecycle.recognitionStarted(route: liveRoute)
        } else {
            recognitionDecision = .stop(.inputUnavailable)
        }
        guard case .continueRunning = recognitionDecision else {
            fail(with: failureMessage(for: recognitionDecision))
            return
        }
        isStarting = false
        startPermissionWatch(generation: runGeneration)
        generation += 1
        listeningSince = Date().timeIntervalSinceReferenceDate
        // The speech hold was set before the microphone lease (`startAuthorizedListening`, Step 55);
        // it is released in `cleanupAudioPipeline`, before any answer is spoken.
        logStart(session: sessionField, format: formatField)
        AudioServicesPlaySystemSound(1519) // Crisp tactile feedback confirms recording started
        // Step 65: the soft rising two-note (quieter for a follow-up window) — talk now.
        speech.perform(EarconPolicy.feedback(for: .listenOpened(listenKind)), .scene, ttl: 6)

        // 6. End-of-utterance + hard cap, both decided by `UtteranceEndDetector` (CaneKitLogic).
        endDetector = UtteranceEndDetector(startedAt: listeningSince,
                                           maxListen: windowSeconds ?? UtteranceEndDetector.maxListen)
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
    private func recognitionUpdate(text: String, isFinal: Bool, error: String?, generation: UInt64) {
        guard isListening, activeGeneration == generation else { return }
        if !text.isEmpty {
            latestTranscript = text
            state = .recognizing(partialText: text)
        }
        if let error {
            _ = error
            let decision = lifecycle.recognitionFailed()
            if case .stop = decision { fail(with: failureMessage(for: decision)) }
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
    /// answer is never held behind the walker's own dictation. Words → `Earcon.heard`; an empty
    /// press → `Earcon.nothing`, plus "I did not catch that." (`.scene`, ttl 6) on the second in a row;
    /// an empty launch / follow-up window → silence (`EarconPolicy`, Step 65). A
    /// transcript that is the app's own recent line (`SelfHearFilter`, Step 55) is dropped silently
    /// and logged `voice_self_hear {action: dropped, transcript, matched_line}` — it is not something
    /// the walker said, so there is nothing to answer. No-op unless listening.
    /// - Parameter reason: written to `voice_end` — "press" | "silence" | "timeout" | "final" |
    ///   "error:<text>".
    func stopListeningAndSubmit(reason: String = "press") {
        guard isListening else { return }
        let finalPrompt = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanupAudioPipeline()
        logEnd(reason: reason, transcriptLength: finalPrompt.count)

        if !finalPrompt.isEmpty {
            if let matched = selfHear.shouldDrop(transcript: finalPrompt,
                                                 now: Date().timeIntervalSinceReferenceDate) {
                onEvent?("voice_self_hear", [
                    "action": "dropped", "transcript": finalPrompt, "matched_line": matched,
                ])
                state = .idle
                return
            }
            state = .processing
            if listenKind == .press { emptyPressCount = EarconPolicy.emptyPressCount(previous: emptyPressCount, heardWords: true) }
            // Step 65: one short tap — heard you; the answer (or the thinking tick) follows.
            speech.perform(EarconPolicy.feedback(for: .listenHeardWords), .scene, ttl: 6)
            onTranscriptionFinalized?(finalPrompt)
        } else {
            state = .idle
            // Step 65: a press that heard nothing gets the soft falling note; the words "I did not
            // catch that." (cached, `SpokenPhrases.shellLines`) only on the second empty press in a
            // row. An unasked-for window (launch / follow-up) that heard nothing closes silently.
            if listenKind == .press {
                emptyPressCount = EarconPolicy.emptyPressCount(previous: emptyPressCount, heardWords: false)
            }
            speech.perform(EarconPolicy.feedback(for: .listenEmpty(listenKind, emptyPressCount: emptyPressCount)),
                           .scene, ttl: 6)
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
    /// Speaks nothing; logs `voice_end` with reason "cancel" only if it was listening. Called by
    /// the AppModel background and route-stop paths as well as a second Guide-button press while a
    /// permission prompt is pending.
    func cancel() {
        let wasListening = isListening
        generation += 1
        nextGeneration &+= 1
        pendingPermissionGeneration = nil
        if isListening || isStarting || formatRetry != nil || microphoneLeaseAcquired {
            cleanupAudioPipeline()
            if wasListening { logEnd(reason: "cancel", transcriptLength: latestTranscript.count) }
        }
        state = .idle
    }

    // MARK: - Failure relays

    /// Handles a shared-audio route transition. `SpeechQueue` has already restored `.playback`
    /// before invoking this callback; the guard makes the stop one-shot and generation-safe.
    private func voiceInputRouteChanged(before: SoundRecognitionRoute,
                                        after: SoundRecognitionRoute,
                                        generation: UInt64) {
        _ = before
        guard activeGeneration == generation else { return }
        let decision = lifecycle.routeChanged(after)
        guard case .stop = decision else { return }
        fail(with: failureMessage(for: decision))
    }

    /// Fails closed on an audio interruption. `.ended` never resumes a partial transcript; the user
    /// can start a fresh utterance after the call/Siri session has finished.
    private func voiceInputInterruption(_ event: SpeechQueue.MicrophoneInterruption,
                                        generation: UInt64) {
        guard activeGeneration == generation, event == .began else { return }
        let decision = lifecycle.interruptionBegan()
        guard case .stop = decision else { return }
        fail(with: failureMessage(for: decision))
    }

    /// Treats an engine graph change as a hard stop even when SpeechKit emits no error.
    private func audioEngineConfigurationChanged(generation: UInt64) {
        guard activeGeneration == generation else { return }
        let decision = lifecycle.recognitionFailed()
        guard case .stop = decision else { return }
        fail(with: failureMessage(for: decision))
    }

    /// Polls the two permission states and engine liveness while capture owns the microphone. iOS
    /// does not provide a reliable mid-session permission notification, so this bounded poll is the
    /// explicit cancellation path for Settings revocation.
    private func startPermissionWatch(generation: UInt64) {
        permissionWatchTask?.cancel()
        permissionWatchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(VoiceInputGuard.permissionPollInterval))
                guard !Task.isCancelled, let self,
                      self.activeGeneration == generation, self.isListening else { return }
                guard AVAudioApplication.shared.recordPermission == .granted,
                      SFSpeechRecognizer.authorizationStatus() == .authorized else {
                    let decision = self.lifecycle.permissionRevoked()
                    if case .stop = decision { self.fail(with: self.failureMessage(for: decision)) }
                    return
                }
                guard self.engine.isRunning else {
                    let decision = self.lifecycle.recognitionFailed()
                    if case .stop = decision { self.fail(with: self.failureMessage(for: decision)) }
                    return
                }
            }
        }
    }

    /// Maps a pure lifecycle failure to one concise spoken cue through the existing navigation
    /// speech channel. Route/port details remain in diagnostics rather than speech.
    private func failureMessage(for decision: VoiceInputDecision) -> String {
        guard case .stop(let failure) = decision else { return "Voice input is not ready." }
        switch failure {
        case .outputRouteChanged:
            return "Voice input stopped because the audio route changed."
        case .inputRouteDegraded:
            return "Voice input stopped because the microphone route is degraded."
        case .inputUnavailable:
            return "Voice input stopped because the microphone is unavailable."
        case .recognitionFailed:
            return "Voice input stopped because speech recognition failed."
        case .interrupted:
            return "Voice input stopped because audio was interrupted."
        case .permissionRevoked:
            return "Voice input stopped because microphone access was revoked."
        case .permissionDenied:
            return "Voice input is off in Settings."
        }
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
        isStarting = false
        // First, while the box still exists: a pause still open is logged and the tap resumed.
        endSelfHearPause()
        activeGeneration = nil
        pendingPermissionGeneration = nil
        permissionWatchTask?.cancel()
        permissionWatchTask = nil
        _ = lifecycle.cancel()
        speech.onVoiceInputRouteChanged = nil
        speech.onVoiceInputInterruption = nil
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver)
            self.engineConfigurationObserver = nil
        }
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

        // Stop every input consumer before releasing the speech hold. Releasing the hold drains
        // queued guidance immediately, so doing it first could make the recognizer hear OpenCane's
        // own line while the `.playAndRecord` engine is still live.
        if microphoneLeaseAcquired {
            let mayRestore = shouldRestorePlaybackSession.map { $0() } ?? true
            if mayRestore {
                // SpeechQueue keeps the owner and schedules bounded retries if this restore fails,
                // including the route-callback case where its snapshot is already nil.
                _ = speech.setMicrophoneEnabled(false, owner: .voiceInput)
            }
            microphoneLeaseAcquired = false
        }

        // Idempotent: safe on paths where the hold was never set (permission wait, teardown).
        speech.setVoiceHold(false)

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
        // A failed recognizer/route must never leave a partial command looking usable to the next
        // callback or UI read. The user-facing reason goes through the existing nav speech band.
        latestTranscript = ""
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
