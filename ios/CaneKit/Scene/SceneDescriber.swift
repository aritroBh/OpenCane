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
//  survives a crossing line; an answer to a question 10 s). There is no spoken progress line any
//  more: "Describing." (3 s TTL) was removed in Steps 29–33 — the button's "Describing…" state
//  and the Action button's own tick carry progress instead.
//
//  Also "Ask OpenCane" (Step 16, `ask(_:)`): one question about the same frame, answered by the
//  cloud model directly (never by the on-device fallback, which ignores prompts).
//
//  Owner: `AppModel.describer`, built in `AppModel.init` with `depth.processor`, `speech`, the
//  shared `VLMClientFactory.resolved(context:)` client and `AppModel.sceneContext`. Callers:
//  `AppModel.describeScene()` (button, watch, Action button, Camera Control) and
//  `AppModel.askAboutScene(_:)` (Siri / Shortcuts, `ConversationCoordinator` scene questions).
//  UI: `GuideCard` ("Where am I" / "Describing…", `lastDescription`, `lastError`); `SceneEngineCard`
//  on the Details tab (Step 47: `lastSource`, `lastCloudMs`, `lastFallbackReason`, `lastGate`,
//  `lastAt`, `lastTrigger`, `cloudName` — who actually answered, why the cloud was skipped, when).
//  Tests: `CloudSceneGateTests`, `QuestionPromptTests`, `PeopleAheadTests`, `SceneVocabularyTests`
//  (CaneKitLogic, the rules this class applies); `CaneKitUITests.testWhereAmIWithoutKeyReportsGracefully`
//  (no frame in the simulator → "Camera warming up", button comes back) and
//  `testWhereAmIDescribesAStreetViewFrame` (`make uitest-streetview`).
//
//  Threading / isolation: `@MainActor`. `describe()` spawns one main-actor `Task`; the three
//  slow steps leave main as follows:
//    · first-frame wait — `Task.sleep` polling of `hasCameraFrame` (lock-guarded, cheap);
//    · JPEG encode — `snapshot` is `@concurrent`, so it runs on the global executor (without
//      it, a static method of this main-actor class would run on main);
//    · Vision for the gate / people line — `OnDeviceVision.detect` and `withPeople` are
//      `@concurrent` (global executor);
//    · network — `client.describeScene(jpeg:)` / `cloud.describe(jpeg:prompt:)` are nonisolated async calls; under
//      NonisolatedNonsendingByDefault it starts on main (base64 + JSON body build) and suspends
//      for the URLSession round trip.
//  Only Sendable values (`Data`, `String`) cross; `DepthFrameProcessor` is Sendable by design.
//
//  Invariant: one description at a time (`isDescribing`), always reset by `defer` even when the
//  task is cancelled. A lock calls `cancelForBackground()` (generation bump + cancel) so a
//  pre-lock JPEG never speaks after the unlock (`SceneDescribePolicy`; Step 63). Missing keys
//  never crash (hard rule 4): the app speaks a graceful line.
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
    /// Last failure: "No camera frame", or the error's `localizedDescription` when the client
    /// threw (for "Where am I" only after the on-device fallback also failed; for a question, any
    /// cloud failure). Cleared when a run starts, not on success. A missing key is not a failure
    /// any more (the on-device client answers). Shown in red under the button on `GuideCard`.
    private(set) var lastError: String?
    /// The question the last run was answering, or "" when it was a plain "Where am I".
    /// `AppModel` reads it inside `onResult`, so the trip log records which question an answer
    /// belonged to — an answer logged without its question cannot be read back afterwards.
    private(set) var lastQuestion = ""
    /// Wall-clock milliseconds of the last successful client call (request build + network round
    /// trip + parse; excludes the frame wait, the JPEG encode and the gate's Vision pass).
    private(set) var lastLatencyMs = 0
    /// Provider name for the UI and logs ("On-device", "Muse + On-device", …) = `client.name`.
    /// Still declared optional for its callers' `?? "none"`, but never nil in practice.
    let providerName: String?

    // MARK: Provenance of the last run (Step 47, the Scene engine card on the Details tab)

    /// Display name of the client whose sentence was spoken last ("Muse", "On-device"); nil before
    /// the first run and after a failed one. For a question this is the cloud client's name.
    private(set) var lastSource: String?
    /// Cloud round trip of the last run in ms when the cloud was tried (answered, or failed after
    /// this long); nil when it was not tried or the run failed. From `VLMAnswer.cloudMs`.
    private(set) var lastCloudMs: Int?
    /// Why the cloud did not answer the last run ("The request timed out.", "HTTP 429: …"), from
    /// `VLMAnswer.fallbackReason`; nil when it answered, was not tried, or the run failed.
    private(set) var lastFallbackReason: String?
    /// The `CloudSceneGate` verdict of the last run exactly as logged in `describe_result.gate`:
    /// "spoken", "edited: …", "refused: …", "on-device", "error", "no frame". nil before the first run.
    private(set) var lastGate: String?
    /// When the last run finished (any outcome); nil before the first.
    private(set) var lastAt: Date?
    /// What asked for the last run; set when the run is accepted, so the trip log's
    /// `describe_result` (read in `onResult`) and the card agree. nil before the first run.
    private(set) var lastTrigger: DescribeTrigger?
    /// The cloud model's display name ("Muse", "Gemini", …) = `client.cloudPrimary?.name`; nil when
    /// the app runs on-device only. The Scene engine card names the chain with it.
    var cloudName: String? { client.cloudPrimary?.name }
    /// The on-device client's display name ("On-device") = `client.onDeviceFallback?.name`, or the
    /// client's own name when it *is* the on-device client.
    var onDeviceName: String { client.onDeviceFallback?.name ?? client.name }

    /// The client, injected by AppModel from `VLMClientFactory.resolved(context:)`; never nil.
    @ObservationIgnored private let client: any VLMClient
    /// Source of camera frames (`hasCameraFrame`, `jpegSnapshot`); shared with `DepthEngine`.
    @ObservationIgnored private let processor: DepthFrameProcessor
    /// Where progress, result and error lines are spoken (all `.scene`).
    @ObservationIgnored private let speech: SpeechQueue
    /// The client's side channel, shared with `AppModel` and the on-device client. It carries the
    /// LiDAR line `AppModel.handle` rewrites from every depth report ("1.4 meters ahead, obstacle.") — the gate's
    /// only source of a legitimate distance, and the prefix spoken in front of a cloud sentence,
    /// which is forbidden to give numbers — and, written from here, the depth grid of the very
    /// frame being described, so a person found in the image can be given a real distance.
    @ObservationIgnored private let context: SceneContext
    /// Bumped by `cancelForBackground` so a JPEG captured before a lock cannot speak after it
    /// (`SceneDescribePolicy.maySpeak`). Same shape as `voiceShellGeneration`.
    @ObservationIgnored private var describeGeneration = 0
    /// The live run; cancelled on background so the cloud `await` does not finish after the lock.
    @ObservationIgnored private var describeTask: Task<Void, Never>?

    /// The app went to the background: drop the run in flight so its pre-lock scene can never
    /// speak after the unlock (Step 63). `isDescribing` is cleared by the task's `defer`.
    /// Caller: `AppModel.scenePhaseChanged(.background)`.
    func cancelForBackground() {
        describeGeneration &+= 1
        describeTask?.cancel()
        describeTask = nil
    }

    /// Takes the resolved client (cloud with on-device fallback, or on-device only); changing keys
    /// needs an app relaunch.
    /// - Parameters:
    ///   - processor: source of camera frames and their depth grids (shared with `DepthEngine`).
    ///   - speech: where every line is spoken, at `.scene` priority.
    ///   - client: the resolved vision client; never nil.
    ///   - context: `AppModel.sceneContext`, the same instance `AppModel.handle` writes the LiDAR
    ///     line into and `OnDeviceVLMClient` reads.
    init(processor: DepthFrameProcessor, speech: SpeechQueue, client: any VLMClient,
         context: SceneContext) {
        self.processor = processor
        self.speech = speech
        self.client = client
        self.context = context
        providerName = client.name
    }

    /// Every outcome, for the trip log (AppModel → `describe_result`): the sentence spoken, or the
    /// error, the round trip in ms, the replay frame, the `CloudSceneGate` verdict (`gate`) and the
    /// cloud model's raw reply (`cloud_text`) so a walk log shows what was stripped or refused and
    /// what the model had actually said. Called on the main actor, exactly once per accepted run
    /// (no frame → `gate` "no frame"; throw → "error"; on-device answer → "on-device"). Not called
    /// for a run refused up front ("Still describing…", "I did not catch a question.").
    /// Set by `AppModel.wireDescriber`.
    @ObservationIgnored var onResult: ((_ text: String?, _ error: String?, _ ms: Int?, _ frame: String,
                                        _ gate: String, _ cloudText: String) -> Void)?

    /// Is it dark with no torch lit? (`AppModel.camerasInTheDark`, from `LowLightPolicy`, Step 49.)
    /// Read once per accepted run, at the moment the result is spoken: a true answer prefixes the
    /// description or answer with `darkCaveat`, because a camera model in the dark misses things
    /// and a blind walker cannot see why. Default false (the simulator, tests). Set by
    /// `AppModel.wireDescriber`.
    @ObservationIgnored var isDark: () -> Bool = { false }
    /// The spoken prefix when `isDark()`; the sentence after it is the model's as usual.
    static let darkCaveat = "It is dark, so this may miss things. "

    /// "Where am I". One description at a time. Speaks the result (or a spoken error); the Action
    /// Button tick and the disabled UI state provide progress without adding another spoken line.
    ///
    /// Flow: wait ≤ 3 s for a fresh camera frame (the paused frame is dropped on background), encode
    /// a ≤ 1024 px JPEG + its depth grid off main, send it to the client (cloud with on-device
    /// fallback, or on-device only; never nil), gate a cloud sentence (`grounded`), add the people
    /// line when the cloud answered, speak it (20 s TTL).
    /// Failures speak "Camera warming up. Try again." or "Scene description failed."; a press while
    /// one is running speaks "Still describing the previous scene." and is dropped.
    /// Caller: `AppModel.describeScene(trigger:)` (button, watch, Action button, Camera Control,
    /// the waypoint hook).
    /// - Parameter trigger: who asked (default the Guide button); kept as `lastTrigger` for the
    ///   Scene engine card and the `describe_result` log record.
    /// - Returns: true when a run was started, false when one was already in flight.
    @discardableResult
    func describe(trigger: DescribeTrigger = .button) -> Bool {
        run(question: nil, trigger: trigger)
    }

    /// "Ask OpenCane …": one question about the frame in front of the cane, one sentence back.
    ///
    /// Deliberately **not** a conversation. The research this shape comes from is written up in
    /// `QuestionPrompt` (CaneKitLogic): blind users want to ask rather than only listen, but the
    /// measured complaint about AI answers is their length, and open-ended conversational video
    /// assistants are weakest exactly on the moving scenes a walker is in. So: one question, one
    /// sentence, no follow-up and no state carried between asks.
    ///
    /// Safety is unchanged from "Where am I": the answer is spoken at `.scene`, the lowest
    /// priority, so any obstacle name, route line or "Head height." interrupts it; and it goes
    /// through the same `CloudSceneGate`, so a question cannot be used to get a number, a count or
    /// "the way is clear" past the gate.
    /// - Parameter question: what the walker said. Empty or wordless input is refused out loud
    ///   rather than sent to the model as a blank question.
    /// Caller: `AppModel.askAboutScene(_:)` (Siri / Shortcuts / the Action button, and
    /// `ConversationCoordinator` for anything `FastPathIntentClassifier.isSceneQuestion` matches).
    /// With no cloud client it says so and runs a plain description instead (`lastQuestion` still
    /// records what was asked).
    /// - Returns: true when a run was started; false for an empty question or a run in flight.
    @discardableResult
    func ask(_ question: String) -> Bool {
        guard let cleaned = QuestionPrompt.clean(question) else {
            speech.say("I did not catch a question.", .scene, ttl: 6)
            return false
        }
        return run(question: cleaned, trigger: .question)
    }

    /// The shared body of "Where am I" (`question == nil`) and "Ask OpenCane" (a question).
    ///
    /// One run at a time for both, because they share the one camera frame and the one voice: a
    /// question fired while a description is in flight is dropped, exactly as a double press on the
    /// watch already was.
    /// - Parameters:
    ///   - question: the cleaned question, or nil for a plain scene description.
    ///   - trigger: who asked; recorded as `lastTrigger` once the run is accepted.
    /// - Returns: true when the run's Task was started (`isDescribing` is then true until it ends).
    @discardableResult
    private func run(question: String?, trigger: DescribeTrigger) -> Bool {
        guard !isDescribing else {
            speech.say("Still describing the previous scene.", .scene, ttl: 6)
            return false
        }
        let client = self.client
        // A question needs a model that can read it. The on-device describer ignores the prompt
        // entirely and answers with a scene description, so answering "is there a bench?" with it
        // would be a different question's answer spoken as if it were this one's. Say so, then do
        // the thing that is actually possible.
        let cloud = client.cloudPrimary
        let requested = question            // what the walker asked, before any downgrade
        var asked = question
        if asked != nil, cloud == nil {
            speech.say("Asking a question needs the cloud model, which is not set up. Describing instead.",
                       .scene, ttl: 8)
            asked = nil
        }
        let question = asked
        isDescribing = true
        lastError = nil
        // ⚠ The question the WALKER asked, not the one that survived the downgrade above (review
        // round 1). A trip log that records a description with no question beside it cannot be read
        // back afterwards — and the no-cloud downgrade is precisely the run somebody will be trying
        // to explain.
        lastQuestion = requested ?? ""
        lastTrigger = trigger
        let generation = describeGeneration
        describeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isDescribing = false }

            // Cold launch from the Action button: give ARKit up to 3 s for a first frame.
            // A cancelled sleep (backgrounded) must not leave `isDescribing` stuck.
            var waited = 0
            while !self.processor.hasCameraFrame, waited < 30 {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                waited += 1
            }
            guard self.stillCurrent(generation) else { return }
            let processor = self.processor
            let frameName = FrameReplay.shared.currentName ?? ""
            guard let (jpeg, depth) = await Self.snapshot(processor) else {
                guard self.stillCurrent(generation) else { return }
                self.lastError = "No camera frame"
                self.recordOutcome(source: nil, cloudMs: nil, reason: nil, gate: "no frame")
                self.speech.say("Camera warming up. Try again.", .scene)
                self.onResult?(nil, "No camera frame", nil, frameName, "no frame", "")
                return
            }
            guard self.stillCurrent(generation) else { return }
            // Publish the frame's depth before the client runs: it turns "a person ahead" into
            // "a person ahead, about two meters" — and stays empty rather than guessing.
            self.context.setDepth(depth)
            self.context.setPeopleHandled(false)
            // AppModel keeps refreshing the shared text while a cloud request is in flight. Keep
            // the LiDAR sentence from this same image beside the captured JPEG instead of pairing
            // the answer with a later frame's distance.
            let capturedLidar = self.context.get()
            let started = Date()
            do {
                // The question path asks the cloud client DIRECTLY (see `VLMClient.cloudPrimary`):
                // no silent on-device fallback, because that would answer a different question.
                if let question, let cloud {
                    let raw = try await cloud.describe(jpeg: jpeg,
                                                       prompt: QuestionPrompt.text(for: question))
                    guard self.stillCurrent(generation) else { return }
                    self.lastLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
                    let (text, gate) = await self.groundedAnswer(raw, jpeg: jpeg, lidar: capturedLidar)
                    guard self.stillCurrent(generation) else { return }
                    // A question is always the cloud's answer (no fallback on this path).
                    self.recordOutcome(source: cloud.name, cloudMs: self.lastLatencyMs, reason: nil,
                                       gate: gate)
                    self.lastDescription = text
                    // ttl 10, not 20 like a plain description: the frame is already one cloud
                    // round-trip old when this line is spoken, and the walker may have kept
                    // walking (1.2 m/s × 10 s of cloud wait ≈ 12 m). A stale answer about where
                    // something was is worse than no answer; the wait itself is unavoidable and
                    // auditable (`ms` + `frame` in `describe_result`). Plain "Where am I" keeps
                    // 20 — that walker asked and stood still.
                    // Step 49: an answer given in the dark says so first (the caveat is a fact
                    // about the camera, not a claim by the model, so it is added after the gate).
                    let answer = (self.isDark() && !text.contains(CloudSceneGate.tooDark)) ? Self.darkCaveat + text : text
                    self.speech.say(answer, .scene, ttl: 10)
                    self.onResult?(answer, nil, self.lastLatencyMs, frameName, gate, raw)
                    return
                }
                let answer = try await client.describeScene(jpeg: jpeg)
                guard self.stillCurrent(generation) else { return }
                self.lastLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
                // Only a cloud sentence needs the gate; an on-device one is already faithful.
                var (text, gate) = answer.source == .cloud
                    ? await self.grounded(answer.text, jpeg: jpeg, lidar: capturedLidar)
                    : (answer.text, "on-device")
                guard self.stillCurrent(generation) else { return }
                // Who really answered, and why the cloud did not: the Scene engine card's headline.
                // A refused cloud sentence was spoken by the on-device client (`grounded`): the
                // card must not say "Muse answered" over "On-device spoke instead" (Codex review).
                let spokeOnDevice = gate.hasPrefix("refused")
                self.recordOutcome(source: spokeOnDevice ? self.onDeviceName
                                                         : (answer.answeredBy.isEmpty ? nil : answer.answeredBy),
                                   cloudMs: answer.cloudMs, reason: answer.fallbackReason, gate: gate)
                // People come AFTER the gate, deliberately. A cloud primary answers without ever
                // reaching the on-device client, so the body detectors would not have run — the
                // fact belongs to the description, not to one provider. And it is added after
                // gating because this line is a sensor reading, not something the model claimed:
                // its count comes from Vision and its distance from LiDAR, so the gate — whose job
                // is to refuse numbers the model invented — must never see it and strip it.
                if !self.context.peopleHandled(), self.context.peopleEnabled() {
                    text = await Self.withPeople(text, jpeg: jpeg, depth: depth,
                                                 mirrored: self.context.mirrored())
                    guard self.stillCurrent(generation) else { return }
                }
                // Step 49: in the dark with no torch the description is prefixed with the caveat —
                // spoken and shown (the Guide card's "Scene: …" line), after the gate and after the
                // people line, because it is about the camera, not something the model said. Not
                // when the model itself answered `CloudSceneGate.tooDark`: that sentence already is
                // the caveat, and it is spoken as the answer (with the LiDAR line in front, as usual).
                if self.isDark(), !text.contains(CloudSceneGate.tooDark) { text = Self.darkCaveat + text }
                self.lastDescription = text
                self.speech.say(text, .scene, ttl: 20)
                self.onResult?(text, nil, self.lastLatencyMs, frameName, gate,
                               answer.source == .cloud ? answer.text : "")
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                guard self.stillCurrent(generation) else { return }
                self.lastError = error.localizedDescription
                self.recordOutcome(source: nil, cloudMs: nil, reason: nil, gate: "error")
                // A failed question says so as a question. "Scene description failed" after
                // "is there a bench?" reads as an answer about the bench.
                self.speech.say(question == nil ? "Scene description failed."
                                                : "I could not answer that.", .scene)
                self.onResult?(nil, error.localizedDescription, nil, frameName, "error", "")
            }
        }
        return true
    }

    /// False when a lock bumped the generation after this run started (`SceneDescribePolicy`).
    private func stillCurrent(_ generation: Int) -> Bool {
        SceneDescribePolicy.maySpeak(started: generation, current: describeGeneration)
    }

    /// Writes the provenance of a finished run (`lastSource`, `lastCloudMs`, `lastFallbackReason`,
    /// `lastGate`, `lastAt`) in one place, **before** `onResult` fires so `AppModel.wireDescriber`
    /// logs the same values the Scene engine card shows. Called once per accepted run.
    /// - Parameters:
    ///   - source: who wrote the spoken sentence; nil for a failure or a missing frame.
    ///   - cloudMs: the cloud round trip when the cloud was tried.
    ///   - reason: the cloud's error when the on-device client answered instead.
    ///   - gate: the `CloudSceneGate` note, or "on-device" / "error" / "no frame".
    private func recordOutcome(source: String?, cloudMs: Int?, reason: String?, gate: String) {
        lastSource = source
        lastCloudMs = cloudMs
        lastFallbackReason = reason
        lastGate = gate
        lastAt = Date()
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
    /// - Parameters:
    ///   - cloud: the cloud model's raw sentence.
    ///   - jpeg: the frame it described (re-used for the Vision evidence and the fallback).
    ///   - lidar: the LiDAR line captured beside that frame ("" = none), the only legal distance.
    /// - Returns: what to speak, and the gate note for the trip log.
    private func grounded(_ cloud: String, jpeg: Data, lidar: String) async -> (String, String) {
        let seen = await OnDeviceVision.detect(jpeg: jpeg)
        let nouns = SceneVocabulary.narrationNouns(seen.labels)
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

    /// `grounded`, but for an *answer to a question* — the same gate, a different failure line.
    ///
    /// The one behaviour that must differ: when the gate refuses the model's answer, "Where am I"
    /// can quietly swap in the on-device description because a description is what was asked for.
    /// A question cannot. Substituting a description for a refused answer is how a walker who
    /// asked "is there a bench on my left?" hears "Sidewalk with trees ahead." and concludes there
    /// is no bench — an absence-of-evidence inference, which is the exact failure `CloudSceneGate`
    /// exists to prevent. So the refusal is said out loud first, and the description follows as
    /// what the app *can* offer, clearly separated from the question.
    /// - Parameters:
    ///   - cloud: the model's raw answer.
    ///   - jpeg: the frame it answered about, re-used for the gate's Vision evidence.
    ///   - lidar: the LiDAR line captured beside that frame ("" = none).
    /// - Returns: what to speak, and the gate note for the trip log.
    private func groundedAnswer(_ cloud: String, jpeg: Data, lidar: String) async -> (String, String) {
        let seen = await OnDeviceVision.detect(jpeg: jpeg)
        let nouns = SceneVocabulary.narrationNouns(seen.labels)
        let ocr = SceneVocabulary.readableTexts(seen.texts.filter { $0.confidence >= 0.5 }.map(\.text))
        let verdict = CloudSceneGate.check(cloud, lidar: lidar, ocr: ocr, detectedNouns: nouns)
        guard let safe = verdict.sentence else {
            // ⚠ The description that follows is LABELLED, and the label is the point (review
            // round 1). "I can't answer that. Sidewalk with trees ahead." is still two sentences a
            // walker reads as one answer — the second half sounds like the reason there is no
            // bench. "What I can describe is:" makes it a different statement about a different
            // question, which is what it actually is.
            var description = OnDeviceVLMClient.template(seen, lidar: lidar)
            if let onDevice = client.onDeviceFallback, let text = try? await onDevice.describe(jpeg: jpeg),
               !text.isEmpty {
                description = text
            }
            guard !description.isEmpty else { return ("I can't answer that.", verdict.note) }
            return ("I can't answer that. What I can describe is: " + description, verdict.note)
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
