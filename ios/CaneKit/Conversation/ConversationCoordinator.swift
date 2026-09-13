//
//  ConversationCoordinator.swift
//  CaneKit
//
//  Manages conversational assistant state, history, marker persistence, and tool dispatching.
//  Bridges CaneKitLogic decision models with AppModel effects.
//
//  Why it exists (Step 23, "Talk to OpenCane"): a blind walker with one hand on the cane needs to
//  ask for things by voice — status, a destination, a post, a setting — without a screen. Every
//  query takes exactly one of four paths, in this order:
//    1. Fast path (`FastPathIntentClassifier.classify`): deterministic, offline, 0 tokens —
//       settings, status, route start/stop, posts, trip metrics.
//    2. Scene question (`FastPathIntentClassifier.isSceneQuestion`): always the grounded camera
//       path (`AppModel.askAboutScene` → `SceneDescriber.ask`, `CloudSceneGate`), never the chat
//       model, even with a cloud key.
//    3. No cloud model (`client.cloudPrimary == nil`): one honest "I need a network model" line.
//    4. Cloud model: `ConversationPrompt` + a camera frame → `ConversationResponseParser` → at most
//       one tool call (`executeTool`) + one spoken sentence.
//  Every answer is spoken at `.scene` (the lowest band: route, obstacle and safety lines always
//  pre-empt it) in the one natural voice (Step 54, owner decision 2026-09-13): a cached answer plays
//  at once, a novel one races the ElevenLabs fetch for at most 2.5 s (`VoiceEngineChoice`), and the
//  system voice speaks only when that fetch fails. Step 31's `immediate: true` is gone. Effects that
//  announce themselves (`setHapticsSilenced`, `setOption`, `stopRoute`, `navigate(to:)`) are not
//  echoed (Step 23 Muse rounds: double-speak). Every turn is logged: `conv_turn` / `conv_error` /
//  `marker_dropped`.
//
//  Voice shell (Steps 56, 57, 59):
//    · Rule 0 of the fast path is the eight-word menu (`VoiceMenu`): route, where am I, describe,
//      status, repeat, quiet, help, emergency, their digits, next / standard / detailed, yes / no.
//      Each maps to an existing `AppModel` entry point in `executeAction`; `conv_turn.ivr` names the
//      item. "route" alone is the CIF demo route; "take me to …" reaches any place.
//    · Latest wins, with a budget (`ConversationBudget`): every new query cancels a cloud turn still
//      in flight (that turn logs `conv_turn {superseded: true}` and never speaks); a cloud turn says
//      "One moment." at 1.5 s and gives up at 4 s ("That is taking too long…", `conv_error
//      {timeout: true}`). A stale completion never speaks. The old `isProcessing` drop is gone.
//    · Emergency is two utterances (`EmergencyConfirm`): "emergency" speaks the prompt with the
//      contact's name and number (`.nav`, ttl 8); only "yes" inside 8 s opens `tel:` (the trip log
//      is flushed first, the app leaves the foreground). "no" or silence → "Emergency canceled."
//      Logs `emergency {action, contact}` — the contact's name, never the number.
//
//  Owner: `AppModel.conversation`, built in `AppModel.init` with the same `VLMClient` as the
//  describer. Callers: `AppModel`'s `voiceInput.onTranscriptionFinalized` (push-to-talk, head nod)
//  and `AppModel.handleSpokenQuery` (`TalkToOpenCaneIntent` with a filled query). `VoiceTile` shows
//  `isProcessing` ("Thinking…") and `lastResponse`; the voice shell reads `awaitingEmergencyAnswer`
//  to give the emergency prompt its answer window.
//
//  Threading / isolation:
//    · Main actor isolated throughout (`@MainActor @Observable`).
//    · Background network LLM calls run concurrently on URLSession; the JPEG is encoded in a
//      detached task so the main actor is not stalled.
//    · `appModel` is weak and re-read per call: `AppModel` owns this object (no retain cycle) and a
//      query may outlive a torn-down model across the network await (Step 23 Muse finding 3).
//
//  Tests: the pure halves are in CaneKitLogic (`ConversationLogicTests`: classifier, parser,
//  history ring, `sceneQuestionDetection`, `walkMarkerJSONRoundTrip`, `ivrRuleRunsBeforeEverythingElse`;
//  `NodToTalkFastPathTests`; `VoiceMenuTests`; `ConversationBudgetTests`; `EmergencyConfirmTests`).
//  This class has no unit test (app target) — device test in CHANGELOG Step 23.
//

import CaneKitLogic
import Foundation
import Observation
import UIKit

/// Orchestrates user queries, fast-path shortcuts, LLM tool calling, and action execution.
/// One instance (`AppModel.conversation`); main actor; the latest query wins (`ConversationBudget`).
@MainActor
@Observable
final class ConversationCoordinator {

    // MARK: - Published State
    /// Rolling memory of the last `ConversationHistory.defaultMaxTurns` (6) turns — every path
    /// appends one, including fast-path and scene turns. The last 3 are sent to the cloud model as
    /// `[RECENT DIALOGUE]` by `ConversationPrompt.buildUserPrompt` (the current turn is appended
    /// only after the reply). In memory only: lost on relaunch.
    private(set) var history = ConversationHistory()
    /// Posts dropped by voice or by the `drop_marker` tool, persisted across launches by `PostStore`.
    var markers: [WalkMarker] { store.markers }
    /// Documents/posts/posts.json; both marker paths go through `dropPost(name:)`.
    let store = PostStore()
    /// True while the latest `handleQuery` runs (including its cloud round trip). A newer query no
    /// longer waits or is dropped: it supersedes the older one (Step 57), and only the latest call
    /// clears this flag. `VoiceTile` titles the mic "Thinking…" from it.
    private(set) var isProcessing: Bool = false
    /// The last answer text (fast path, scene acknowledgement, cloud reply or error line), shown
    /// under the Talk button. For an action that spoke for itself it is the coordinator's own
    /// summary ("Routing to X."), which may differ from what was actually spoken.
    private(set) var lastResponse: String?

    /// The cloud turn's filler / timeout clock and the latest-wins ledger (Step 57). Pure;
    /// `ConversationBudgetTests`.
    private var budget = ConversationBudget()
    /// The gate between "emergency" and a phone call (Step 59). Pure; `EmergencyConfirmTests`.
    private var emergency = EmergencyConfirm()
    /// The in-flight cloud turn; cancelled by a newer query or by the budget's timeout.
    private var cloudTask: Task<Void, Never>?
    /// The 0.25 s ticker that drives `budget.tick` for the in-flight cloud turn.
    private var tickerTask: Task<Void, Never>?
    /// Turn ids the budget timed out, so their cancelled task logs `timed_out`, not `superseded`.
    /// An id is removed when its `conv_turn` is written.
    private var timedOutTurns = Set<Int>()
    /// Turn ids that spoke "One moment." (`conv_turn.filler_spoken`). Removed when logged.
    private var fillerTurns = Set<Int>()
    /// Bumped by every `handleQuery`; only the call holding the latest value clears `isProcessing`.
    private var queryGeneration = 0
    /// Fires once, just after the emergency window, to speak "Emergency canceled." when no answer came.
    private var emergencyExpiryTask: Task<Void, Never>?

    /// True while an emergency prompt waits for its yes / no (inside `EmergencyConfirm.confirmWindow`).
    /// For the voice shell's follow-up listen (`VoiceShellPolicy.followUp(answerWasQuestion:)`).
    var awaitingEmergencyAnswer: Bool { emergency.isPending(now: Self.clock()) }

    // Minimal 1x1 valid JPEG fallback when no camera frame is available
    /// Sent with a cloud query when `DepthFrameProcessor.jpegSnapshot()` returns nil (no retained
    /// camera frame yet, or it was dropped when ARKit paused, or encoding failed):
    /// `VLMClient.describe(jpeg:prompt:)` always takes an image, and a conversational question
    /// must not fail for want of one.
    private static let minimalJPEG = Data([
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x01, 0x00, 0x48,
        0x00, 0x48, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
        0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x14, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x09, 0xFF, 0xDA, 0x00, 0x08,
        0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0x3F, 0xFF, 0xD9
    ])

    // MARK: - Dependencies
    /// The engine owner every effect goes through. Weak: `AppModel` owns this coordinator, and a
    /// query can span a network await (Step 23 Muse finding 3). Every function returns quietly (or
    /// with neutral facts) when it is nil.
    private weak var appModel: AppModel?
    /// The app's shared vision client (`VLMClientFactory.resolved`). Only its `cloudPrimary` is
    /// used here: the on-device client ignores a conversational prompt and answers with a scene
    /// description, which is a wrong answer to anything else (Step 23 Muse finding 1).
    private let client: any VLMClient

    /// - Parameters:
    ///   - appModel: the owner (held weakly).
    ///   - client: the same `VLMClient` `SceneDescriber` and `HazardScanner` use.
    /// Called once from `AppModel.init`, after every stored property is set.
    init(appModel: AppModel, client: any VLMClient) {
        self.appModel = appModel
        self.client = client
    }

    // MARK: - Query Handling

    /// Main entry point for spoken or typed conversational queries.
    /// Takes one of the four paths in the file header and always leaves one `history` turn,
    /// `lastResponse` and a trip-log record behind — except when it returns early: no `appModel`, or
    /// a blank query (nothing spoken, nothing logged). A cloud turn still in flight is superseded
    /// first (latest wins, Step 57), whichever path the new query takes.
    /// - Parameter rawQuery: the recogniser's transcript or the intent's text; trimmed here.
    /// Speech TTLs: fast path and no-cloud line 12 s, cloud answer 15 s, error 8 s, filler 3 s,
    /// timeout 8 s (all `.scene`, one natural voice — Step 54).
    func handleQuery(_ rawQuery: String) async {
        guard let model = appModel else { return }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        supersedeCloudTurn()
        queryGeneration += 1
        let generation = queryGeneration
        isProcessing = true
        defer { if generation == queryGeneration { isProcessing = false } }

        let now = Date().timeIntervalSince1970
        var turn = ConversationTurn(
            timestamp: now,
            userQuery: query,
            location: model.location.fix?.coordinate
        )

        // 1. Check Deterministic Fast-Path (<1 ms, 0 tokens); rule 0 is the voice menu.
        if let immediateAction = FastPathIntentClassifier.classify(query: query) {
            let (response, alreadySpoken) = executeAction(immediateAction)
            turn.agentResponse = response
            history.append(turn: turn)
            lastResponse = response

            // Only speak if the underlying effect did not already announce itself (e.g. setHapticsSilenced, stopRoute).
            // One voice (Step 54): cached → natural at once, else the 2.5 s race.
            if !alreadySpoken {
                model.speech.say(response, .scene, ttl: 12)
            }
            var fields: [String: Any] = ["query": query, "fast_path": true, "response": response,
                                         "already_spoken": alreadySpoken]
            if let item = VoiceMenu.match(query) { fields["ivr"] = item.rawValue }
            model.logger.event("conv_turn", fields)
            return
        }

        // Scene questions use the dedicated camera path even when a cloud conversation client is
        // configured. That path binds the answer to the captured frame, LiDAR facts, Vision nouns
        // and the CloudSceneGate; the generic assistant must not turn a scene question into an
        // ungrounded conversational paragraph. `SceneDescriber` speaks the eventual answer.
        if FastPathIntentClassifier.isSceneQuestion(query) {
            let accepted = model.askAboutScene(query)
            turn.agentResponse = accepted ? "Checking the scene ahead."
                                          : SpokenPhrases.describerBusyLine
            history.append(turn: turn)
            lastResponse = turn.agentResponse
            model.logger.event("conv_turn", [
                "query": query, "fast_path": false, "scene_path": true,
                "response": turn.agentResponse ?? ""
            ])
            return
        }

        // 2. No cloud key in Secrets.plist: the on-device client drops a conversational prompt and
        //    answers with a scene description, which is a wrong answer to anything else. So a scene
        //    question goes to the describer (which explains the downgrade itself, see
        //    `SceneDescriber.ask`), and everything else gets one honest line pointing at what the
        //    fast path can answer offline. Pinned by `sceneQuestionDetection` (ConversationLogicTests).
        guard let targetClient = client.cloudPrimary else {
            let response = "I need a network model for that. Try asking about the scene, battery, GPS, or your route."
            model.speech.say(response, .scene, ttl: 12)
            turn.agentResponse = response
            history.append(turn: turn)
            lastResponse = response
            model.logger.event("conv_turn", ["query": query, "fast_path": false, "cloud": false, "response": response])
            return
        }

        // 3. Build Telemetry Context & Prompt
        let context = buildContext()
        let prompt = ConversationPrompt.buildUserPrompt(query: query, context: context, history: history)

        // 4. Dispatch to the cloud LLM under the budget: filler at 1.5 s, timeout at 4 s (Step 57).
        let id = budget.begin(now: Self.clock())
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runCloudTurn(id: id, query: query, prompt: prompt, client: targetClient, turn: turn)
        }
        cloudTask = task
        tickerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runBudgetTicker(id: id, query: query, turn: turn, task: task)
        }
        await task.value
    }

    /// Latest wins: drop the cloud turn in flight, if any. Its task sees the cancellation (or a
    /// refused `budget.finished`) and logs `conv_turn {superseded: true}` without speaking.
    private func supersedeCloudTurn() {
        budget.cancel()
        cloudTask?.cancel()
        tickerTask?.cancel()
        cloudTask = nil
        tickerTask = nil
    }

    /// One cloud turn: frame + prompt → reply → at most one tool → one spoken sentence. Speaks and
    /// logs only while `budget.finished(id:)` says this is still the live turn.
    /// - Parameters:
    ///   - id: the budget's turn id.
    ///   - query: the trimmed query (for the log).
    ///   - prompt: the built cloud prompt.
    ///   - targetClient: `client.cloudPrimary`.
    ///   - turn: the history turn begun in `handleQuery`.
    private func runCloudTurn(id: Int, query: String, prompt: String, client targetClient: any VLMClient,
                              turn: ConversationTurn) async {
        guard let model = appModel else { return }
        var turn = turn
        let started = Self.clock()
        do {
            // Encode JPEG concurrently off main thread to prevent UI stalls
            let jpeg = await Task.detached { [weak processor = model.depth.processor] in
                processor?.jpegSnapshot()
            }.value ?? Self.minimalJPEG
            try Task.checkCancellation()
            let rawReply = try await targetClient.describe(jpeg: jpeg, prompt: prompt)
            guard budget.finished(id: id) else {
                logStaleTurn(id: id, query: query, started: started)
                return
            }
            tickerTask?.cancel()
            let latency = Self.ms(since: started)
            let parsed = ConversationResponseParser.parse(rawText: rawReply)

            // 5. Execute tool call if requested by model
            var toolHandledSpeech = false
            if let invocation = parsed.toolCall {
                toolHandledSpeech = executeTool(invocation)
                turn.toolsInvoked.append(invocation)
            }

            turn.agentResponse = parsed.spokenResponse
            turn.latencyMs = latency
            history.append(turn: turn)
            lastResponse = parsed.spokenResponse

            if !toolHandledSpeech {
                model.speech.say(parsed.spokenResponse, .scene, ttl: 15)
            }
            model.logger.event("conv_turn", [
                "query": query,
                "fast_path": false,
                "cloud": true,
                "response": parsed.spokenResponse,
                "latency_ms": latency,
                "budget_ms": latency,
                "filler_spoken": fillerTurns.remove(id) != nil,
                "superseded": false,
                "timed_out": false
            ])
        } catch {
            guard budget.finished(id: id) else {
                logStaleTurn(id: id, query: query, started: started)
                return
            }
            tickerTask?.cancel()
            let fallback = "I could not process that request right now."
            turn.agentResponse = fallback
            history.append(turn: turn)
            lastResponse = fallback
            model.speech.say(fallback, .scene, ttl: 8)
            model.logger.event("conv_error", ["query": query, "error": error.localizedDescription,
                                              "budget_ms": Self.ms(since: started),
                                              "filler_spoken": fillerTurns.remove(id) != nil])
        }
    }

    /// Drives the budget for turn `id` every `UtteranceEndDetector.checkInterval` (0.25 s): speaks
    /// "One moment." once at 1.5 s, and at 4 s cancels `task`, speaks the timeout line and logs
    /// `conv_error {timeout: true}`. Exits as soon as the turn is no longer the live one.
    private func runBudgetTicker(id: Int, query: String, turn: ConversationTurn, task: Task<Void, Never>) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(UtteranceEndDetector.checkInterval))
            guard !Task.isCancelled, budget.inFlightID == id, let model = appModel else { return }
            switch budget.tick(now: Self.clock()) {
            case .none:
                continue
            case .speakFiller:
                fillerTurns.insert(id)
                model.speech.say(ConversationBudget.fillerLine, .scene, ttl: 3)
            case .timeout:
                timedOutTurns.insert(id)
                task.cancel()
                var timedOut = turn
                timedOut.agentResponse = ConversationBudget.timeoutLine
                history.append(turn: timedOut)
                lastResponse = ConversationBudget.timeoutLine
                model.speech.say(ConversationBudget.timeoutLine, .scene, ttl: 8)
                model.logger.event("conv_error", ["query": query, "error": "timeout", "timeout": true,
                                                  "budget_ms": Int(ConversationBudget.budget * 1000)])
                return
            }
        }
    }

    /// The `conv_turn` of a cloud turn that ended after it stopped being the live one: superseded by
    /// a newer query, or timed out by the budget. Never speaks.
    private func logStaleTurn(id: Int, query: String, started: Double) {
        let timedOut = timedOutTurns.remove(id) != nil
        appModel?.logger.event("conv_turn", [
            "query": query, "fast_path": false, "cloud": true, "response": "",
            "budget_ms": Self.ms(since: started),
            "filler_spoken": fillerTurns.remove(id) != nil,
            "superseded": !timedOut, "timed_out": timedOut
        ])
    }

    /// Monotonic seconds for the budget and the emergency window (never the wall clock).
    private static func clock() -> Double { ProcessInfo.processInfo.systemUptime }

    /// Whole milliseconds since `started` on `clock()`.
    private static func ms(since started: Double) -> Int { Int(((clock() - started) * 1000).rounded()) }

    // MARK: - Action & Tool Execution

    /// Executes an immediate fast-path action and returns the confirmation sentence plus whether it already spoke.
    /// `alreadySpoken == true` means the AppModel effect announced itself, so `handleQuery` only
    /// records the returned text (history, `lastResponse`, `conv_turn`) and does not speak it.
    /// ⚠ Answers here must be facts the app actually holds — see the `.hazardsEncountered` note.
    private func executeAction(_ action: ConversationAction) -> (response: String, alreadySpoken: Bool) {
        guard let model = appModel else { return ("", false) }
        switch action {
        case .silenceCane(let silenced):
            model.setHapticsSilenced(silenced)
            let line = StatusSummary.hapticsLine(
                healthy: model.haptics.isHealthy,
                silenced: silenced,
                watchReachable: model.watch.isReachable
            )
            return (line, true) // setHapticsSilenced already speaks at .nav

        case .updateSetting(let opt, let enabled):
            if let option = HandsFreeOption(rawValue: opt) {
                model.setOption(option, enabled: enabled)
                // The recorded line is the *request*; `setOption` speaks the read-back state (and,
                // for "off", what stops), so a refused switch is spoken correctly but logged as asked.
                let line = enabled ? "\(option.spokenName) on." : "\(option.spokenName) off."
                return (line, true) // setOption already speaks at .nav
            }
            return ("Option not recognized.", false)

        case .answerStatus(let aspect):
            let facts = currentStatusFacts()
            switch aspect {
            case .battery:
                return (StatusSummary.batteryLine(facts) ?? "Battery level unknown.", false)
            case .headphones:
                return (StatusSummary.audioLine(facts), false)
            case .route:
                return (StatusSummary.routeLine(facts), false)
            case .gps:
                return (StatusSummary.gpsLine(facts), false)
            case .haptics:
                return (StatusSummary.hapticsLine(healthy: facts.hapticsHealthy, silenced: facts.hapticsSilenced, watchReachable: facts.watchReachable), false)
            case .all:
                return (StatusSummary.sentence(facts), false)
            }

        case .startRoute(let dest):
            model.navigate(to: dest)
            // navigate(to:) speaks "Finding a route to <dest>." at once, then "Walking to <place>, N
            // meters." (or the failure line) once the MapKit build finishes — all at .nav.
            return ("Routing to \(dest).", true) // navigate(to:) already speaks "Walking to ..." at .nav

        case .stopRoute:
            model.stopRoute()
            return ("Route stopped.", true) // stopRoute() already speaks "Route stopped." at .nav

        case .recordMarker(let name):
            return (dropPost(name: name), false)

        case .answerHistory(let metric, _):
            switch metric {
            case .steps:
                if let steps = model.trip.steps {
                    return ("\(steps) steps walked so far.", false)
                }
                return ("Step counter is not ready yet.", false)
            case .distanceWalked:
                let m = Int(model.trip.distanceM.rounded())
                return ("You have walked \(m) meters on this route.", false)
            case .hazardsEncountered:
                // ⚠ Fixed sentence: it does NOT consult `AppModel.hazardLog.records`, so it is said
                // even after hazards were announced and mapped on this route. Known gap; a real
                // answer should count this route's hazard records.
                return ("No severe hazards reported on this route.", false)
            default:
                // `.pastWaypoints` / `.recentEvents`: not implemented on the fast path.
                return ("No trip records available.", false)
            }

        case .inspectScene(let question):
            // The acknowledgement is spoken now; `SceneDescriber` speaks the answer later. Unlike
            // the scene-question path in `handleQuery`, a refused ask (describer busy) is not
            // distinguished here — the Bool from `askAboutScene` is discarded.
            model.askAboutScene(question)
            return ("Checking the scene ahead.", false)

        // MARK: Voice shell (Step 56) — rule 0 of the fast path

        case .startDefaultRoute:
            // "route" while walking is a question about the route, never a restart of the demo.
            if model.nav.isNavigating {
                return (StatusSummary.routeLine(currentStatusFacts()), false)
            }
            model.startDemoRoute()
            return (VoiceMenu.Item.route.confirmationLine, true) // the route intro / depth wait speaks

        case .describeScene:
            // `describeScene` speaks "Still describing the previous scene." itself when busy.
            let accepted = model.describeScene(trigger: .voice)
            return accepted ? (VoiceMenu.Item.describe.confirmationLine, false)
                            : (SpokenPhrases.describerBusyLine, true)

        case .speakStatus:
            model.speakStatus() // speaks every clause at .scene
            return (StatusSummary.sentence(currentStatusFacts()), true)

        case .repeatInstruction:
            model.repeatInstruction()
            return (VoiceMenu.Item.repeatLast.confirmationLine, true)

        case .nextWaypoint:
            model.nextWaypoint() // advances (the next line speaks) or says "No route running."
            return ("Next.", true)

        case .setCueLevel(let level):
            // An unchanged level speaks nothing from `cueLevel.didSet`, so the shell confirms it.
            guard model.cueLevel != level else { return (level.spokenLine, false) }
            model.setCueLevel(level)
            return (level.spokenLine, true)

        case .help:
            return (VoiceMenu.helpLine, false)

        // MARK: Emergency (Step 59) — two utterances, never one

        case .emergency:
            let profile = model.medicalProfile.profile
            switch emergency.emergency(now: Self.clock(), name: profile.emergencyContactName,
                                       number: profile.emergencyContactPhone) {
            case .prompt(let line):
                model.speech.say(line, .nav, ttl: EmergencyConfirm.confirmWindow)
                model.logger.event("emergency", ["action": "prompted", "contact": profile.emergencyContactName])
                scheduleEmergencyExpiry()
                return (line, true)
            default:
                model.logger.event("emergency", ["action": "no_contact", "contact": profile.emergencyContactName])
                return (EmergencyConfirm.noContactLine, false)
            }

        case .confirm(let yes):
            let contact = model.medicalProfile.profile.emergencyContactName
            switch emergency.confirm(yes, now: Self.clock()) {
            case .call(let tel):
                emergencyExpiryTask?.cancel()
                guard let url = URL(string: "tel:\(tel)") else { return (EmergencyConfirm.nothingPendingLine, false) }
                model.logger.event("emergency", ["action": "confirmed", "contact": contact])
                model.speech.say(EmergencyConfirm.callingLine, .nav, ttl: 6)
                // The call leaves the app; a log that ends mid-buffer would hide that it happened.
                model.logger.flush()
                UIApplication.shared.open(url)
                return (EmergencyConfirm.callingLine, true)
            case .cancel:
                emergencyExpiryTask?.cancel()
                model.logger.event("emergency", ["action": "declined", "contact": contact])
                return (EmergencyConfirm.canceledLine, false)
            default:
                return (EmergencyConfirm.nothingPendingLine, false)
            }

        case .speakImmediate(let msg):
            return (msg, false)
        }
    }

    /// After an emergency prompt: once the window has passed with no yes / no, speak "Emergency
    /// canceled." (`.nav`) and log `emergency {action: timeout}`. A new prompt restarts it; an answer
    /// cancels it. The sleep runs 0.1 s past the window so `expire` sees it lapsed.
    private func scheduleEmergencyExpiry() {
        emergencyExpiryTask?.cancel()
        emergencyExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(EmergencyConfirm.confirmWindow + 0.1))
            guard let self, !Task.isCancelled, let model = self.appModel else { return }
            if self.emergency.expire(now: Self.clock()) {
                model.speech.say(EmergencyConfirm.canceledLine, .nav, ttl: 6)
                model.logger.event("emergency", ["action": "timeout",
                                                 "contact": model.medicalProfile.profile.emergencyContactName])
            }
        }
    }

    /// Executes tool calls generated by the LLM. Returns true if tool handled its own speech.
    /// Arguments are strings (`ToolInvocation.arguments`); a missing or unparseable argument makes
    /// the tool a no-op returning false, so the model's `spoken_response` is spoken instead — which
    /// may claim an action that did not happen. `query_status` / `query_history` fall to `default`
    /// (no local effect; the model answers from the context it was sent).
    /// ⚠ `.dropMarker` discards `dropPost`'s confirmation, including "could not be saved": the
    /// model's sentence is spoken, and only the `marker_dropped` log shows `persisted: false`.
    @discardableResult
    private func executeTool(_ invocation: ToolInvocation) -> Bool {
        guard let model = appModel else { return false }
        switch invocation.tool {
        case .navigateTo:
            if let dest = invocation.arguments["destination"] {
                model.navigate(to: dest)
                return true // model.navigate announces "Walking to ..."
            }
            return false
        case .stopNavigation:
            model.stopRoute()
            return true // model.stopRoute() announces "Route stopped." at .nav
        case .dropMarker:
            dropPost(name: invocation.arguments["name"] ?? "Marker \(markers.count + 1)")
            return false // the model's spoken_response confirms; the store holds the post
        case .queryScene:
            let question = invocation.arguments["question"] ?? "Describe the scene ahead"
            model.askAboutScene(question)
            return true
        case .setSetting:
            if let opt = invocation.arguments["option"], let option = HandsFreeOption(rawValue: opt),
               let enabledStr = invocation.arguments["enabled"], let enabled = Bool(enabledStr) {
                model.setOption(option, enabled: enabled)
                return true
            }
            return false
        case .setCaneSilenced:
            if let silStr = invocation.arguments["silenced"], let silenced = Bool(silStr) {
                model.setHapticsSilenced(silenced)
                return true
            }
            return false
        default:
            return false
        }
    }

    /// The one place a post is recorded: fast path (`.recordMarker`) and LLM tool (`.dropMarker`) both
    /// land here so the store, the trip log and the wording cannot drift apart. No fix → still
    /// recorded at (0, 0) so the name is not lost, and the confirmation says "GPS weak" so the
    /// walker knows the spot is not pinned. Returns the confirmation sentence.
    /// The fix is `location.fix` at any accuracy and age (no gate, unlike `recordHazard`'s 120 s).
    /// Logs `marker_dropped` with `name`, `lat`, `lon`, `has_fix`, `persisted` and, on a store
    /// failure, `error`.
    /// - Parameter name: the spoken name, or "Marker N" from the tool path when none was given.
    @discardableResult
    private func dropPost(name: String) -> String {
        let fix = appModel?.location.fix
        let coord = fix?.coordinate ?? Coordinate(latitude: 0, longitude: 0)
        let marker = WalkMarker(name: name, coordinate: coord,
                                timestamp: Date().timeIntervalSince1970)
        let persisted = store.append(marker)
        // Mirrored whether or not posts.json accepted it: the walker said the words, so the post
        // exists. The phone's marker UUID is the cloud row's primary key, so a retry cannot
        // duplicate it.
        appModel?.cloud.recordPost(marker)
        var fields: [String: Any] = [
            "name": name, "lat": coord.latitude, "lon": coord.longitude,
            "has_fix": fix != nil, "persisted": persisted
        ]
        if let error = store.lastError { fields["error"] = error }
        appModel?.logger.event("marker_dropped", fields)
        if !persisted {
            return fix != nil
                ? "\(name) marked for this session, but could not be saved."
                : "\(name) marked for this session. GPS weak and could not be saved."
        }
        return fix != nil ? "\(name) marked at current location." : "\(name) marked. GPS weak."
    }

    // MARK: - Context Gathering

    /// The telemetry snapshot serialised into the cloud prompt (`ConversationPrompt`).
    /// Known approximations (the model is NOT told about them — keep them in mind when reading replies):
    /// `currentDestination` is the *next waypoint's instruction*, not the destination name;
    /// `nextWaypointName` is the same instruction, and "No route" when idle (never nil in
    /// practice); `recentObstacles` / `recentHazards` are always empty (not wired). With no
    /// `appModel`, a neutral all-unknown context.
    private func buildContext() -> ConversationContext {
        guard let model = appModel else {
            return ConversationContext(
                currentDestination: nil,
                nextWaypointName: nil,
                distanceToNextMeters: nil,
                isNavigating: false,
                recentObstacles: [],
                recentHazards: [],
                savedMarkers: markers,
                batteryPercent: -1,
                headphonesConnected: false,
                headphoneName: "",
                gpsAccuracyM: -1,
                hapticsHealthy: false,
                hapticsSilenced: false,
                elapsedSeconds: 0,
                distanceWalkedM: 0,
                steps: nil
            )
        }
        let facts = currentStatusFacts()
        return ConversationContext(
            currentDestination: model.nav.isNavigating ? model.nav.instruction : nil,
            nextWaypointName: model.nav.instruction.isEmpty ? nil : model.nav.instruction,
            distanceToNextMeters: model.nav.distanceToNext,
            isNavigating: model.nav.isNavigating,
            recentObstacles: [],
            recentHazards: [],
            savedMarkers: markers,
            batteryPercent: facts.batteryPercent,
            headphonesConnected: facts.headphonesConnected,
            headphoneName: facts.headphoneName,
            gpsAccuracyM: facts.gpsAccuracyM,
            hapticsHealthy: facts.hapticsHealthy,
            hapticsSilenced: facts.hapticsSilenced,
            elapsedSeconds: model.trip.elapsed,
            distanceWalkedM: model.trip.distanceM,
            steps: model.trip.steps
        )
    }

    /// The same `StatusFacts` `AppModel.speakStatus()` builds for the Siri status report, read live
    /// from the engines, so a fast-path status answer and the spoken status use one wording
    /// (`StatusSummary`). Battery −1 and GPS accuracy −1 mean unknown. With no `appModel`, all
    /// false / unknown.
    private func currentStatusFacts() -> StatusFacts {
        guard let model = appModel else {
            return StatusFacts(
                lidarSupported: false,
                obstacleDetectionRunning: false,
                depthFps: 0,
                gpsFix: false,
                gpsAccuracyM: -1,
                locationDenied: false,
                headphonesConnected: false,
                headphoneName: "",
                headTracking: false,
                hapticsHealthy: false,
                hapticsSilenced: false,
                watchReachable: false,
                routeRunning: false,
                routeInstruction: "",
                metresToNext: nil,
                batteryPercent: -1
            )
        }
        return StatusFacts(
            lidarSupported: model.lidarSupported,
            obstacleDetectionRunning: model.depth.isRunning,
            depthFps: model.depth.fps,
            gpsFix: model.location.fix != nil,
            gpsAccuracyM: model.location.fix?.accuracy ?? -1,
            locationDenied: model.location.denied,
            headphonesConnected: model.audioRoute.headphonesConnected,
            headphoneName: model.audioRoute.outputName,
            headTracking: model.head.isConnected || model.faceHead.isTracking,
            hapticsHealthy: model.haptics.isHealthy,
            hapticsSilenced: model.hapticsSilenced,
            watchReachable: model.watch.isReachable,
            routeRunning: model.nav.isNavigating,
            routeInstruction: model.nav.instruction,
            metresToNext: model.nav.distanceToNext,
            batteryPercent: model.batteryPercent
        )
    }
}
