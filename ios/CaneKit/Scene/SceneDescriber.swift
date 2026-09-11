//
//  SceneDescriber.swift
//  CaneKit
//
//  "Where am I": grab the latest camera frame as a 1024 px JPEG, send it to the configured
//  vision model, speak one sentence. Triggered by the Action button (App Shortcut), the watch,
//  the on-screen button, or Camera Control if that ever fires under ARKit.
//

import CaneKitLogic
import Foundation
import Observation

@MainActor
@Observable
final class SceneDescriber {

    private(set) var isDescribing = false
    private(set) var lastDescription = ""
    private(set) var lastError: String?
    private(set) var lastLatencyMs = 0
    /// Provider name for the UI, or nil when no key is configured.
    let providerName: String?

    @ObservationIgnored private let client: (any VLMClient)?
    @ObservationIgnored private let processor: DepthFrameProcessor
    @ObservationIgnored private let speech: SpeechQueue

    init(processor: DepthFrameProcessor, speech: SpeechQueue) {
        self.processor = processor
        self.speech = speech
        client = VLMClientFactory.fromSecrets()
        providerName = client?.name
    }

    /// One description at a time. Speaks progress and the result (or a spoken error).
    func describe() {
        guard !isDescribing else { return }
        guard let client else {
            speech.say("No scene description key is set.", .scene)
            lastError = "No VLM key in Secrets.plist"
            return
        }
        isDescribing = true
        lastError = nil
        speech.say("Describing.", .scene, ttl: 3)

        Task { [weak self] in
            guard let self else { return }
            defer { self.isDescribing = false }

            // Cold launch from the Action button: give ARKit up to 3 s for a first frame.
            // A cancelled sleep (backgrounded) must not leave `isDescribing` stuck.
            var waited = 0
            while !self.processor.hasCameraFrame, waited < 30 {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                waited += 1
            }
            let processor = self.processor
            guard let jpeg = await Self.snapshot(processor) else {
                self.lastError = "No camera frame"
                self.speech.say("Camera warming up. Try again.", .scene)
                return
            }
            let started = Date()
            do {
                let text = try await client.describe(jpeg: jpeg)
                self.lastLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
                self.lastDescription = text
                self.speech.say(text, .scene, ttl: 20)
            } catch {
                self.lastError = error.localizedDescription
                self.speech.say("Scene description failed.", .scene)
            }
        }
    }

    /// JPEG encode off the main actor (~30–80 ms on device).
    @concurrent
    private static func snapshot(_ processor: DepthFrameProcessor) async -> Data? {
        processor.jpegSnapshot(maxDimension: 1024, quality: 0.7)
    }
}
