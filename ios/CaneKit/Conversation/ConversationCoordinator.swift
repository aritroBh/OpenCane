//
//  ConversationCoordinator.swift
//  CaneKit
//
//  Manages conversational assistant state, history, marker persistence, and tool dispatching.
//  Bridges CaneKitLogic decision models with AppModel effects.
//
//  Threading / isolation:
//    · Main actor isolated throughout (`@MainActor @Observable`).
//    · Background network LLM calls run concurrently on URLSession.
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
    private(set) var markers: [WalkMarker] = []
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
            let response = executeAction(immediateAction)
            turn.agentResponse = response
            history.append(turn: turn)
            lastResponse = response

            model.speech.say(response, .scene, ttl: 12)
            model.logger.event("conv_turn", ["query": query, "fast_path": true, "response": response])
            return
        }

        // 2. Build Telemetry Context & Prompt
        let context = buildContext()
        let prompt = ConversationPrompt.buildUserPrompt(query: query, context: context, history: history)

        // 3. Dispatch to LLM via cloudPrimary (avoids on-device FallbackVLMClient prompt dropping)
        let tStart = Date()
        do {
            let targetClient = client.cloudPrimary ?? client
            let jpeg = model.depth.processor.jpegSnapshot() ?? Self.minimalJPEG
            let rawReply = try await targetClient.describe(jpeg: jpeg, prompt: prompt)
            let latency = Int(Date().timeIntervalSince(tStart) * 1000)

            let parsed = ConversationResponseParser.parse(rawText: rawReply)

            // 4. Execute tool call if requested by model
            var toolHandledSpeech = false
            if let invocation = parsed.toolCall {
                toolHandledSpeech = executeTool(invocation)
                turn.toolsInvoked.append(invocation)
            }

            turn.agentResponse = parsed.spokenResponse
            turn.latencyMs = latency
            history.append(turn: turn)
            lastResponse = parsed.spokenResponse

            // Spoken at .scene priority so obstacle warnings always take priority (skip if tool already spoke)
            if !toolHandledSpeech {
                model.speech.say(parsed.spokenResponse, .scene, ttl: 15)
            }
            model.logger.event("conv_turn", [
                "query": query,
                "fast_path": false,
                "response": parsed.spokenResponse,
                "latency_ms": latency
            ])
        } catch {
            let fallback = "I could not process that request right now."
            turn.agentResponse = fallback
            history.append(turn: turn)
            lastResponse = fallback
            model.speech.say(fallback, .scene, ttl: 8)
            model.logger.event("conv_error", ["query": query, "error": error.localizedDescription])
        }
    }

    // MARK: - Action & Tool Execution

    /// Executes an immediate fast-path action and returns the confirmation sentence.
    private func executeAction(_ action: ConversationAction) -> String {
        guard let model = appModel else { return "" }
        switch action {
        case .silenceCane(let silenced):
            model.setHapticsSilenced(silenced)
            return StatusSummary.hapticsLine(
                healthy: model.haptics.isHealthy,
                silenced: silenced,
                watchReachable: model.watch.isReachable
            )

        case .updateSetting(let opt, let enabled):
            if let option = HandsFreeOption(rawValue: opt) {
                model.setOption(option, enabled: enabled)
                return enabled ? "\(option.spokenName) on." : "\(option.spokenName) off."
            }
            return "Option not recognized."

        case .answerStatus(let aspect):
            let facts = currentStatusFacts()
            switch aspect {
            case .battery:
                return StatusSummary.batteryLine(facts) ?? "Battery level unknown."
            case .headphones:
                return StatusSummary.audioLine(facts)
            case .route:
                return StatusSummary.routeLine(facts)
            case .gps:
                return StatusSummary.gpsLine(facts)
            case .haptics:
                return StatusSummary.hapticsLine(healthy: facts.hapticsHealthy, silenced: facts.hapticsSilenced, watchReachable: facts.watchReachable)
            case .all:
                return StatusSummary.sentence(facts)
            }

        case .startRoute(let dest):
            model.navigate(to: dest)
            return "Routing to \(dest)."

        case .stopRoute:
            model.stopRoute()
            return "Route stopped."

        case .recordMarker(let name):
            let coord = model.location.fix?.coordinate ?? Coordinate(latitude: 0, longitude: 0)
            let marker = WalkMarker(name: name, coordinate: coord, timestamp: Date().timeIntervalSince1970)
            markers.append(marker)
            model.logger.event("marker_dropped", ["name": name, "lat": coord.latitude, "lon": coord.longitude])
            return "\(name) marked at current location."

        case .answerHistory(let metric, _):
            switch metric {
            case .steps:
                if let steps = model.trip.steps {
                    return "\(steps) steps walked so far."
                }
                return "Step counter is not ready yet."
            case .distanceWalked:
                let m = Int(model.trip.distanceM.rounded())
                return "You have walked \(m) meters on this route."
            case .hazardsEncountered:
                return "No severe hazards reported on this route."
            default:
                return "No trip records available."
            }

        case .inspectScene(let question):
            model.askAboutScene(question)
            return "Checking the scene ahead."

        case .speakImmediate(let msg):
            return msg
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
            return false
        case .dropMarker:
            let name = invocation.arguments["name"] ?? "Marker \(markers.count + 1)"
            let coord = model.location.fix?.coordinate ?? Coordinate(latitude: 0, longitude: 0)
            markers.append(WalkMarker(name: name, coordinate: coord, timestamp: Date().timeIntervalSince1970))
            return false
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
