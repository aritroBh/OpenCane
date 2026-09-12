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
//  pre-empt it) with `immediate: true` (Step 31: novel text never hits the natural-voice cache, so
//  it is spoken in the system voice at once instead of waiting on a TTS fetch). Effects that
//  announce themselves (`setHapticsSilenced`, `setOption`, `stopRoute`, `navigate(to:)`) are not
//  echoed (Step 23 Muse rounds: double-speak). Every turn is logged: `conv_turn` / `conv_error` /
//  `marker_dropped`.
//
//  Owner: `AppModel.conversation`, built in `AppModel.init` with the same `VLMClient` as the
//  describer. Callers: `AppModel`'s `voiceInput.onTranscriptionFinalized` (push-to-talk, head nod)
//  and `AppModel.handleSpokenQuery` (`TalkToOpenCaneIntent` with a filled query). GuideCard shows
//  `isProcessing` ("Thinking…") and `lastResponse`.
//
//  Threading / isolation:
//    · Main actor isolated throughout (`@MainActor @Observable`).
//    · Background network LLM calls run concurrently on URLSession; the JPEG is encoded in a
//      detached task so the main actor is not stalled.
//    · `appModel` is weak and re-read per call: `AppModel` owns this object (no retain cycle) and a
//      query may outlive a torn-down model across the network await (Step 23 Muse finding 3).
//
//  Tests: the pure halves are in CaneKitLogic (`ConversationLogicTests`: classifier, parser,
//  history ring, `sceneQuestionDetection`, `walkMarkerJSONRoundTrip`; `NodToTalkFastPathTests`).
//  This class has no unit test (app target) — device test in CHANGELOG Step 23.
//

import CaneKitLogic
import Foundation
import Observation

/// Orchestrates user queries, fast-path shortcuts, LLM tool calling, and action execution.
@MainActor
@Observable
final class ConversationCoordinator {

    // MARK: - Published State
    private(set) var history = ConversationHistory()
    /// Posts dropped by voice or by the `drop_marker` tool, persisted across launches by `PostStore`.
    var markers: [WalkMarker] { store.markers }
    /// Documents/posts/posts.json; both marker paths go through `dropPost(name:)`.
    let store = PostStore()
    private(set) var isProcessing: Bool = false
    private(set) var lastResponse: String?

    // Minimal 1x1 valid JPEG fallback when no camera frame is available
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
    private weak var appModel: AppModel?
    private let client: any VLMClient

    init(appModel: AppModel, client: any VLMClient) {
        self.appModel = appModel
        self.client = client
    }

    // MARK: - Query Handling

    /// Main entry point for spoken or typed conversational queries.
    func handleQuery(_ rawQuery: String) async {
        guard !isProcessing else { return }
        guard let model = appModel else { return }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        isProcessing = true
        defer { isProcessing = false }

        let now = Date().timeIntervalSince1970
        var turn = ConversationTurn(
            timestamp: now,
            userQuery: query,
            location: model.location.fix?.coordinate
        )

        // 1. Check Deterministic Fast-Path (<1 ms, 0 tokens)
        if let immediateAction = FastPathIntentClassifier.classify(query: query) {
            let (response, alreadySpoken) = executeAction(immediateAction)
            turn.agentResponse = response
            history.append(turn: turn)
            lastResponse = response

            // Only speak if the underlying effect did not already announce itself (e.g. setHapticsSilenced, stopRoute).
            // `immediate`: conversational answers are novel text, so a TTS fetch would stall
            // every answer on the network — system voice now, natural voice prefetched.
            if !alreadySpoken {
                model.speech.say(response, .scene, ttl: 12, immediate: true)
            }
            model.logger.event("conv_turn", ["query": query, "fast_path": true, "response": response, "already_spoken": alreadySpoken])
            return
        }

        // Scene questions use the dedicated camera path even when a cloud conversation client is
        // configured. That path binds the answer to the captured frame, LiDAR facts, Vision nouns
        // and the CloudSceneGate; the generic assistant must not turn a scene question into an
        // ungrounded conversational paragraph. `SceneDescriber` speaks the eventual answer.
        if FastPathIntentClassifier.isSceneQuestion(query) {
            let accepted = model.askAboutScene(query)
            turn.agentResponse = accepted ? "Checking the scene ahead."
                                          : "Still describing the previous scene."
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
            model.speech.say(response, .scene, ttl: 12, immediate: true)
            turn.agentResponse = response
            history.append(turn: turn)
            lastResponse = response
            model.logger.event("conv_turn", ["query": query, "fast_path": false, "cloud": false, "response": response])
            return
        }

        // 3. Build Telemetry Context & Prompt
        let context = buildContext()
        let prompt = ConversationPrompt.buildUserPrompt(query: query, context: context, history: history)

        // 4. Dispatch to the cloud LLM
        let tStart = Date()
        do {
            // Encode JPEG concurrently off main thread to prevent UI stalls
            let jpeg = await Task.detached { [weak processor = model.depth.processor] in
                processor?.jpegSnapshot()
            }.value ?? Self.minimalJPEG

            let rawReply = try await targetClient.describe(jpeg: jpeg, prompt: prompt)
            let latency = Int(Date().timeIntervalSince(tStart) * 1000)

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

            // Spoken at .scene priority so obstacle warnings always take priority (skip if tool already spoke).
            // `immediate`: the reply is novel text, so skip the TTS fetch wait (see `speakNow`).
            if !toolHandledSpeech {
                model.speech.say(parsed.spokenResponse, .scene, ttl: 15, immediate: true)
            }
            model.logger.event("conv_turn", [
                "query": query,
                "fast_path": false,
                "cloud": true,
                "response": parsed.spokenResponse,
                "latency_ms": latency
            ])
        } catch {
            let fallback = "I could not process that request right now."
            turn.agentResponse = fallback
            history.append(turn: turn)
            lastResponse = fallback
            model.speech.say(fallback, .scene, ttl: 8, immediate: true)
            model.logger.event("conv_error", ["query": query, "error": error.localizedDescription])
        }
    }

    // MARK: - Action & Tool Execution

    /// Executes an immediate fast-path action and returns the confirmation sentence plus whether it already spoke.
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
                return ("No severe hazards reported on this route.", false)
            default:
                return ("No trip records available.", false)
            }

        case .inspectScene(let question):
            model.askAboutScene(question)
            return ("Checking the scene ahead.", false)

        case .speakImmediate(let msg):
            return (msg, false)
        }
    }

    /// Executes tool calls generated by the LLM. Returns true if tool handled its own speech.
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
    @discardableResult
    private func dropPost(name: String) -> String {
        let fix = appModel?.location.fix
        let coord = fix?.coordinate ?? Coordinate(latitude: 0, longitude: 0)
        let persisted = store.append(WalkMarker(name: name, coordinate: coord,
                                                 timestamp: Date().timeIntervalSince1970))
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
