//
//  SceneDescriber.swift
//  CaneKit
//
//  "Where am I": grab the latest camera frame as a 1024 px JPEG, send it to the configured
//  vision model, speak one sentence. Triggered by the Action button (App Shortcut), the watch,
//  the on-screen button, or Camera Control if that ever fires under ARKit.
//  All triggers funnel through `AppModel.describeScene()`.
//
//  Speech: everything here is `.scene`, the lowest priority — a description never interrupts an
//  obstacle name, a route line or "Head height.", and waits behind them (result TTL 20 s so it
//  survives a crossing line; "Describing." TTL 3 s so a late progress line is dropped).
//
//  Threading / isolation: `@MainActor`. `describe()` spawns one main-actor `Task`; the three
//  slow steps leave main as follows:
//    · first-frame wait — `Task.sleep` polling of `hasCameraFrame` (lock-guarded, cheap);
//    · JPEG encode — `snapshot` is `@concurrent`, so it runs on the global executor (without
//      it, a static method of this main-actor class would run on main);
//    · network — `client.describe(jpeg:)` is a nonisolated async call; under
//      NonisolatedNonsendingByDefault it starts on main (base64 + JSON body build) and suspends
//      for the URLSession round trip.
//  Only Sendable values (`Data`, `String`) cross; `DepthFrameProcessor` is Sendable by design.
//
//  Invariant: one description at a time (`isDescribing`), always reset by `defer` even when the
//  task is cancelled. Missing keys never crash (hard rule 4): the app speaks a graceful line.
//

import CaneKitLogic
import Foundation
import Observation

/// "Where am I": camera snapshot → vision-language model → one spoken sentence.
/// Owned by `AppModel` (constructed with the depth engine's processor and the speech queue).
@MainActor
@Observable
final class SceneDescriber {

    /// True from `describe()` until the result/error is spoken; disables the button and
    /// rejects re-entry (a double-press on the watch sends one request).
    private(set) var isDescribing = false
    /// Last successful description (shown under the "Where am I" button).
    private(set) var lastDescription = ""
    /// Last failure (missing key, no camera frame, provider/network error); nil on success.
    private(set) var lastError: String?
    /// Wall-clock milliseconds of the last successful `client.describe` call (request build +
    /// network round trip + parse; excludes the frame wait and JPEG encode).
    private(set) var lastLatencyMs = 0
    /// Provider name for the UI, or nil when no key is configured.
    let providerName: String?

    /// Provider chosen once at init by `VLMClientFactory.fromSecrets()`; nil = no key.
    @ObservationIgnored private let client: any VLMClient
    /// Source of camera frames (`hasCameraFrame`, `jpegSnapshot`); shared with `DepthEngine`.
    @ObservationIgnored private let processor: DepthFrameProcessor
    /// Where progress, result and error lines are spoken (all `.scene`).
    @ObservationIgnored private let speech: SpeechQueue

    /// Resolves the provider from Secrets once; changing keys needs an app relaunch.
    init(processor: DepthFrameProcessor, speech: SpeechQueue, client: any VLMClient) {
        self.processor = processor
        self.speech = speech
        self.client = client
        providerName = client.name
    }

    /// One description at a time. Speaks progress and the result (or a spoken error).
    ///
    /// Flow: speak "Describing." (3 s TTL), wait ≤ 3 s for a fresh camera frame (the paused frame
    /// is dropped on background), encode a ≤ 1024 px JPEG off main, send it to the client (cloud
    /// with on-device fallback, or on-device only; never nil), speak the sentence (20 s TTL).
    /// Failures speak "Camera warming up. Try again." or "Scene description failed.".
    /// Caller: `AppModel.describeScene()` (button, watch, Action button, Camera Control).
    /// Every outcome, for the trip log (AppModel → `describe_result`): the sentence, or the
    /// error, and the round trip in ms. Called on the main actor.
    @ObservationIgnored var onResult: ((_ text: String?, _ error: String?, _ ms: Int?, _ frame: String) -> Void)?

    func describe() {
        guard !isDescribing else { return }
        let client = self.client
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
            let frameName = FrameReplay.shared.currentName ?? ""
            guard let jpeg = await Self.snapshot(processor) else {
                self.lastError = "No camera frame"
                self.speech.say("Camera warming up. Try again.", .scene)
                self.onResult?(nil, "No camera frame", nil, frameName)
                return
            }
            let started = Date()
            do {
                let text = try await client.describe(jpeg: jpeg)
                self.lastLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
                self.lastDescription = text
                self.speech.say(text, .scene, ttl: 20)
                self.onResult?(text, nil, self.lastLatencyMs, frameName)
            } catch {
                self.lastError = error.localizedDescription
                self.speech.say("Scene description failed.", .scene)
                self.onResult?(nil, error.localizedDescription, nil, frameName)
            }
        }
    }

    /// JPEG encode off the main actor (~30–80 ms on device).
    /// `@concurrent` is load-bearing: without it this static method would share the class's
    /// main-actor isolation and the encode would block the UI. `DepthFrameProcessor` is
    /// Sendable, so passing it across is safe.
    @concurrent
    private static func snapshot(_ processor: DepthFrameProcessor) async -> Data? {
        processor.jpegSnapshot(maxDimension: 1024, quality: 0.7)
    }
}
