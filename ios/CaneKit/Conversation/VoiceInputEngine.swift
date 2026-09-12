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
private nonisolated final class SpeechBufferBox: @unchecked Sendable {
    private weak var request: SFSpeechAudioBufferRecognitionRequest?

    init(_ request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
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
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var previousBeaconEnabled: Bool = false

    // MARK: - Callbacks
    /// Delivered on the main actor when transcription is finalized.
    var onTranscriptionFinalized: ((String) -> Void)?

    init(speech: SpeechQueue, beacon: BeaconEngine) {
        self.speech = speech
        self.beacon = beacon
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    // MARK: - Control

    /// Starts speech recognition. Transitions audio session to .playAndRecord preserving A2DP.
    func startListening() {
        guard !isListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            fail(with: "Speech recognizer is unavailable.")
            return
        }

        // 1. Activate microphone session via SpeechQueue (Hard Rule 7)
        let sessionResult = speech.setMicrophoneEnabled(true)
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

        // 4. Initialize AVAudioEngine
        let audioEngine = AVAudioEngine()
        self.engine = audioEngine
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        let box = SpeechBufferBox(request)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: recordingFormat) { buffer, _ in
            box.append(buffer)
        }

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
            audioEngine.prepare()
            try audioEngine.start()
            self.isListening = true
            self.state = .listening
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

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            self.engine = nil
        }

        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil

        // Restore .playback audio session immediately
        _ = speech.setMicrophoneEnabled(false)

        // Restore beacon state to previous setting
        beacon.enabled = previousBeaconEnabled
    }

    private func fail(with message: String) {
        cleanupAudioPipeline()
        state = .error(message)
    }
}
