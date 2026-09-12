//
//  VoiceInputEngine.swift
//  CaneKit
//
//  Push-to-talk voice-to-text recognition for the conversational assistant.
//  Uses SFSpeechRecognizer on-device and coordinates with SpeechQueue under AGENTS.md Hard Rule 7.
//
//  Purpose:
//    · Captures user speech using the iPhone's built-in upward-facing microphone array.
//    · Maintains AirPods on high-bitrate stereo A2DP without degrading to 8 kHz mono Bluetooth HFP.
//    · Automatically ducks/silences the spatial audio beacon while listening, restoring .playback
//      and the beacon immediately upon release or VAD silence.
//
//  Threading / isolation:
//    · Main actor isolated (`@MainActor @Observable`).
//    · Real-time audio engine tap calls back on an audio thread; buffer relay is nonisolated Sendable.
//

import AVFoundation
import CaneKitLogic
import Foundation
import Observation
import Speech

/// Operational states of the voice input engine.
enum VoiceInputState: Equatable, Sendable {
    case idle
    case listening
    case recognizing(partialText: String)
    case processing
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
private nonisolated final class SpeechBufferBox: @unchecked Sendable {
    private weak var request: SFSpeechAudioBufferRecognitionRequest?

    init(_ request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    func installTap(on node: AVAudioNode, format: AVAudioFormat) {
        node.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
    }
}

/// Push-to-talk voice recognition controller. Owned by `AppModel`.
@MainActor
@Observable
final class VoiceInputEngine {

    // MARK: - Published State
    private(set) var state: VoiceInputState = .idle
    private(set) var isListening: Bool = false
    private(set) var latestTranscript: String = ""

    // MARK: - Dependencies
    private unowned let speech: SpeechQueue
    private unowned let beacon: BeaconEngine
    private let recognizer: SFSpeechRecognizer?

    // MARK: - Internal Audio Pipeline
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var bufferBox: SpeechBufferBox?
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var previousBeaconEnabled: Bool = false

    // MARK: - Callbacks & Coordination
    /// Delivered on the main actor when transcription is finalized.
    var onTranscriptionFinalized: ((String) -> Void)?
    /// Checked on teardown; returns false if another microphone feature (SoundWatcher) is live.
    var shouldRestorePlaybackSession: (() -> Bool)?

    init(speech: SpeechQueue, beacon: BeaconEngine) {
        self.speech = speech
        self.beacon = beacon
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    // MARK: - Control

    /// Starts speech recognition. Acquires SpeechQueue's `.playAndRecord` microphone lease for
    /// push-to-talk, preserving A2DP and rejecting the start if SoundWatcher already owns it.
    func startListening() {
        guard !isListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            fail(with: "Speech recognizer is unavailable.")
            return
        }

        // 1. Activate microphone session via SpeechQueue (Hard Rule 7)
        let sessionResult = speech.setMicrophoneEnabled(true, owner: .voiceInput)
        switch sessionResult {
        case .granted:
            break
        case .revertedRouteChanged(let before, let after):
            fail(with: "Audio route changed from \(before) to \(after).")
            return
        case .failed(let err):
            fail(with: "Microphone session failed: \(err)")
            return
        }

        // 2. Silence spatial audio beacon while saving previous state
        previousBeaconEnabled = beacon.enabled
        beacon.enabled = false

        // 3. Configure recognition request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.recognitionRequest = request
        self.latestTranscript = ""

        // 4. Configure audio engine tap
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard MicrophoneStart.isUsableInputFormat(sampleRate: recordingFormat.sampleRate, channels: recordingFormat.channelCount) else {
            cleanupAudioPipeline()
            fail(with: "Audio input format is settling.")
            return
        }

        let box = SpeechBufferBox(request)
        self.bufferBox = box
        box.installTap(on: inputNode, format: recordingFormat)

        // 5. Start recognition task
        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                if let result {
                    let formatted = result.bestTranscription.formattedString
                    self.latestTranscript = formatted
                    self.state = .recognizing(partialText: formatted)
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.stopListeningAndSubmit()
                }
            }
        }

        do {
            engine.prepare()
            try engine.start()
            self.isListening = true
            self.state = .listening
            AudioServicesPlaySystemSound(1519) // Crisp tactile feedback confirms recording started
        } catch {
            cleanupAudioPipeline()
            fail(with: "Audio engine could not start: \(error.localizedDescription)")
            return
        }

        // 6. Safety timeout (10 seconds max PTT)
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.isListening else { return }
            self.stopListeningAndSubmit()
        }
    }

    /// Stops listening, cleans up audio, restores .playback session, and delivers finalized prompt.
    func stopListeningAndSubmit() {
        guard isListening else { return }
        timeoutTask?.cancel()
        timeoutTask = nil

        let finalPrompt = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanupAudioPipeline()

        if !finalPrompt.isEmpty {
            state = .processing
            onTranscriptionFinalized?(finalPrompt)
        } else {
            state = .idle
        }
    }

    /// Cancels listening without submitting.
    func cancel() {
        timeoutTask?.cancel()
        timeoutTask = nil
        cleanupAudioPipeline()
        state = .idle
    }

    // MARK: - Teardown

    private func cleanupAudioPipeline() {
        isListening = false

        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }

        bufferBox = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil

        // Restore .playback audio session if no other microphone feature (like SoundWatcher) is using it
        if let shouldRestore = shouldRestorePlaybackSession, shouldRestore() {
            _ = speech.setMicrophoneEnabled(false, owner: .voiceInput)
        } else if shouldRestorePlaybackSession == nil {
            _ = speech.setMicrophoneEnabled(false, owner: .voiceInput)
        }

        // Restore beacon state to previous setting
        beacon.enabled = previousBeaconEnabled
    }

    private func fail(with message: String) {
        cleanupAudioPipeline()
        state = .error(message)
    }
}
