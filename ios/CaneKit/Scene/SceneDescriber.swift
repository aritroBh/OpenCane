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
//  Faithfulness: a CLOUD sentence is never spoken as it arrives. It goes through
//  `CloudSceneGate` (CaneKitLogic) against the LiDAR line, the text Vision read in that frame and
//  the nouns Vision classified, because a cloud model invents exactly the things a blind walker
//  cannot check — street names it never read ("S 5th St" on this route's Street View frames),
//  distances (below chance in GuideDog, ACL 2026), counts (52.7 %), and "the path ahead is clear"
//  when the lens is against a jacket. Refused → the on-device describer speaks instead. An
//  on-device sentence arrives already gated (`SceneVocabulary.isFaithful`) and is spoken as it is.
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
    /// Provider name for the UI ("On-device", "Muse + On-device", …); never nil in practice.
    let providerName: String?

    /// The client, injected by AppModel from `VLMClientFactory.resolved(context:)`; never nil.
    @ObservationIgnored private let client: any VLMClient
    /// Source of camera frames (`hasCameraFrame`, `jpegSnapshot`); shared with `DepthEngine`.
    @ObservationIgnored private let processor: DepthFrameProcessor
    /// Where progress, result and error lines are spoken (all `.scene`).
    @ObservationIgnored private let speech: SpeechQueue
    /// The client's side channel, shared with `AppModel` and the depth engine. It carries the
    /// LiDAR line the depth engine keeps up to date ("Obstacle ahead at 1.4 meters.") — the gate's
    /// only source of a legitimate distance, and the prefix spoken in front of a cloud sentence,
    /// which is forbidden to give numbers — and, written from here, the depth grid of the very
    /// frame being described, so a person found in the image can be given a real distance.
    @ObservationIgnored private let context: SceneContext

    /// Takes the resolved client (cloud with on-device fallback, or on-device only); changing keys
    /// needs an app relaunch.
    /// - Parameters:
    ///   - processor: source of camera frames and their depth grids (shared with `DepthEngine`).
    ///   - speech: where every line is spoken, at `.scene` priority.
    ///   - client: the resolved vision client; never nil.
    ///   - context: `AppModel.sceneContext`, the same instance the depth engine writes to.
    init(processor: DepthFrameProcessor, speech: SpeechQueue, client: any VLMClient,
         context: SceneContext) {
        self.processor = processor
        self.speech = speech
        self.client = client
        self.context = context
        providerName = client.name
    }

    /// One description at a time. Speaks progress and the result (or a spoken error).
    ///
    /// Flow: speak "Describing." (3 s TTL), wait ≤ 3 s for a fresh camera frame (the paused frame
    /// is dropped on background), encode a ≤ 1024 px JPEG off main, send it to the client (cloud
    /// with on-device fallback, or on-device only; never nil), speak the sentence (20 s TTL).
    /// Failures speak "Camera warming up. Try again." or "Scene description failed.".
    /// Caller: `AppModel.describeScene()` (button, watch, Action button, Camera Control).
    /// Every outcome, for the trip log (AppModel → `describe_result`): the sentence spoken, or the
    /// error, the round trip in ms, the replay frame, the `CloudSceneGate` verdict (`gate`) and the
    /// cloud model's raw reply (`cloud_text`) so a walk log shows what was stripped or refused and
    /// what the model had actually said. Called on the main actor.
    @ObservationIgnored var onResult: ((_ text: String?, _ error: String?, _ ms: Int?, _ frame: String,
                                        _ gate: String, _ cloudText: String) -> Void)?

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
            guard let (jpeg, depth) = await Self.snapshot(processor) else {
                self.lastError = "No camera frame"
                self.speech.say("Camera warming up. Try again.", .scene)
                self.onResult?(nil, "No camera frame", nil, frameName, "no frame", "")
                return
            }
            // Publish the frame's depth before the client runs: it turns "a person ahead" into
            // "a person ahead, about two meters" — and stays empty rather than guessing.
            self.context.setDepth(depth)
            self.context.setPeopleHandled(false)
            let started = Date()
            do {
                let answer = try await client.describeScene(jpeg: jpeg)
                self.lastLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
                // Only a cloud sentence needs the gate; an on-device one is already faithful.
                var (text, gate) = answer.source == .cloud
                    ? await self.grounded(answer.text, jpeg: jpeg)
                    : (answer.text, "on-device")
                // People come AFTER the gate, deliberately. A cloud primary answers without ever
                // reaching the on-device client, so the body detectors would not have run — the
                // fact belongs to the description, not to one provider. And it is added after
                // gating because this line is a sensor reading, not something the model claimed:
                // its count comes from Vision and its distance from LiDAR, so the gate — whose job
                // is to refuse numbers the model invented — must never see it and strip it.
                if !self.context.peopleHandled(), self.context.peopleEnabled() {
                    text = await Self.withPeople(text, jpeg: jpeg, depth: depth,
                                                 mirrored: self.context.mirrored())
                }
                self.lastDescription = text
                self.speech.say(text, .scene, ttl: 20)
                self.onResult?(text, nil, self.lastLatencyMs, frameName, gate,
                               answer.source == .cloud ? answer.text : "")
            } catch {
                self.lastError = error.localizedDescription
                self.speech.say("Scene description failed.", .scene)
                self.onResult?(nil, error.localizedDescription, nil, frameName, "error", "")
            }
        }
    }

    /// Turns a cloud sentence into something the sensors can back, and says what happened.
    ///
    /// Runs Vision over the same frame the cloud saw (labels + text) so the gate compares the
    /// sentence with evidence from that moment, not from wherever the walker is now, then:
    ///   · `CloudSceneGate` strips counts and refuses invented numbers, unread names and any
    ///     promise that the way is clear;
    ///   · a surviving sentence gets the LiDAR line in front of it, because the prompt forbids the
    ///     model to give distances and the walker still needs the measured one — exactly what
    ///     `OnDeviceVLMClient` does with its own sentence;
    ///   · a refused sentence is replaced by the on-device description (the client's own fallback),
    ///     so "Where am I" still answers; with no fallback client the deterministic template does.
    /// - Returns: what to speak, and the gate note for the trip log.
    private func grounded(_ cloud: String, jpeg: Data) async -> (String, String) {
        let lidar = context.get()
        let seen = await OnDeviceVision.detect(jpeg: jpeg)
        let nouns = SceneVocabulary.nouns(seen.labels, max: 5)
        // Same confidence floor and junk filter the on-device facts use: Vision "read" "11" and
        // "J.I" off road markings, and junk text must not licence a name in the sentence.
        let ocr = SceneVocabulary.readableTexts(seen.texts.filter { $0.confidence >= 0.5 }.map(\.text))
        let verdict = CloudSceneGate.check(cloud, lidar: lidar, ocr: ocr, detectedNouns: nouns)
        guard let safe = verdict.sentence else {
            if let onDevice = client.onDeviceFallback, let text = try? await onDevice.describe(jpeg: jpeg),
               !text.isEmpty {
                return (text, verdict.note)
            }
            return (OnDeviceVLMClient.template(seen, lidar: lidar), verdict.note)
        }
        guard !lidar.isEmpty, !SceneVocabulary.mentionsDistance(safe, from: lidar) else {
            return (safe, verdict.note)
        }
        return (lidar + " " + safe, verdict.note)
    }

    /// JPEG encode off the main actor (~30–80 ms on device), plus the depth grid of the **same**
    /// ARKit frame — `jpegSnapshotWithDepth` takes both in one critical section and compares their
    /// frame timestamps, so a depth dropout yields `.empty` rather than an old grid paired with a
    /// new image. `@concurrent` is load-bearing: without it this static method would share the
    /// class's main-actor isolation and the encode would block the UI. `DepthFrameProcessor` is
    /// Sendable, so passing it across is safe.
    /// - Returns: the JPEG and its depth grid (`.empty` when depth is unavailable or unpaired),
    ///   or nil when there is no fresh camera frame.
    @concurrent
    private static func snapshot(_ processor: DepthFrameProcessor) async -> (Data, DepthSnapshot)? {
        processor.jpegSnapshotWithDepth(maxDimension: 1024, quality: 0.7)
    }

    /// Prepends the people line to a sentence a **cloud** provider produced, when the sentence
    /// does not already carry the whole fact (`PeopleAhead.needsSpeaking`: every detected noun,
    /// every number, every direction word).
    ///
    /// Only reached when the on-device client did not run (`SceneContext.peopleHandled` still
    /// false), which means the cloud answered — so this costs nothing on the on-device path, and
    /// on the cloud path it runs after a network round trip where a Neural Engine pass is noise.
    /// `@concurrent`: off the main actor, like every other Vision call.
    /// - Parameters:
    ///   - text: the provider's sentence.
    ///   - jpeg: the frame it described.
    ///   - depth: the depth grid of that same frame (`.empty` = no distances).
    ///   - mirrored: swap left and right for a mirrored mount.
    /// - Returns: `text`, with the people line in front of it when one is needed.
    @concurrent
    private static func withPeople(_ text: String, jpeg: Data, depth: DepthSnapshot,
                                   mirrored: Bool) async -> String {
        let d = OnDeviceVLMClient.withDistances(
            await OnDeviceVision.detect(jpeg: jpeg, readText: false, classify: false,
                                        detectPeople: true),
            depth: depth)
        OnDeviceVision.lastPeople.withLock { $0 = PeopleAhead.summary(d.sightings) }
        guard let line = PeopleAhead.line(d.sightings, mirrored: mirrored),
              PeopleAhead.needsSpeaking(line, given: text,
                                        detected: PeopleAhead.nouns(d.sightings)) else { return text }
        return line + " " + text
    }
}
