//
//  ConversationModels.swift
//  CaneKitLogic
//
//  Pure data models for conversational voice interaction, contextual history, and voice-dropped
//  markers ("posts"). Foundation only, Sendable, Codable, and Equatable.
//
//  Purpose:
//    · `WalkMarker` — a named voice-dropped breadcrumb/post at a GPS coordinate ("set a post here").
//    · `ConversationContext` — a live snapshot of navigation, safety, telemetry, and trip progress.
//    · `ConversationTurn` & `ConversationHistory` — rolling dialogue memory with tool invocations.
//    · `ConversationTool` & `ConversationAction` — actions the assistant can perform.
//
//  Why it exists: the "Talk to OpenCane" assistant (Step 23: Action Button / mic / nod to talk) has
//  two answer paths — `FastPathIntentClassifier` (deterministic, no network) and a cloud model
//  prompted by `ConversationPrompt` — and both need the same vocabulary of actions, the same
//  short-term memory and the same telemetry snapshot, testable without the app.
//
//  Owner / callers (app, all main actor): `ConversationCoordinator` (ios/CaneKit/Conversation)
//  holds the `ConversationHistory`, builds a `ConversationContext` per cloud turn
//  (`buildContext()`), runs `ConversationAction`s (`executeAction`) and `ToolInvocation`s
//  (`executeTool`). `PostStore` persists `[WalkMarker]` as Documents/posts/posts.json.
//
//  Key invariants:
//    · Foundation only (no UIKit / CoreLocation / MapKit); coordinates use `Coordinate`.
//    · Sendable throughout for Swift 6 strict concurrency.
//    · Decisions belong in CaneKitLogic with tests; effects belong in the app.
//    · ⚠ `WalkMarker`'s Codable shape is the on-disk posts.json format
//      (`walkMarkerJSONRoundTrip`): renaming a stored property orphans every saved post.
//    · ⚠ `ConversationTool` raw values are the tool names the cloud model is told to emit
//      (`ConversationPrompt.toolDeclarationsJSON`); change both together.
//  Tests: ConversationLogicTests.swift (13) and NodToTalkFastPathTests.swift (2).
//

import Foundation

// MARK: - Voice-Dropped Markers ("Posts")

/// A voice-dropped marker/post at a specific GPS coordinate ("set a post here", "mark entrance").
///
/// Created only by `ConversationCoordinator.dropPost(name:)` (fast path `.recordMarker` and the
/// cloud tool `drop_marker` both land there) and persisted by `PostStore`. No fix → the app still
/// records the name at (0, 0) and says "GPS weak", so a (0, 0) marker means "position unknown".
/// Pinned by `walkMarkerCreation`, `walkMarkerJSONRoundTrip`.
public struct WalkMarker: Sendable, Equatable, Codable, Identifiable {
    /// Unique marker identifier. Survives the posts.json round-trip (pinned).
    public let id: UUID
    /// Spoken or assigned name ("Marker 1", "Townsend Hall entrance", "Favorite bench").
    public let name: String
    /// The coordinate where the post was dropped (WGS-84); (0, 0) when there was no fix.
    public let coordinate: Coordinate
    /// Seconds since 1970 when dropped.
    public let timestamp: TimeInterval

    /// - Parameters:
    ///   - id: defaults to a fresh UUID; tests pass a fixed one.
    ///   - name: what the walker called it.
    ///   - coordinate: the fix at drop time, or (0, 0) with no fix.
    ///   - timestamp: seconds since 1970 (`Date().timeIntervalSince1970` in the app).
    public init(id: UUID = UUID(), name: String, coordinate: Coordinate, timestamp: TimeInterval) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.timestamp = timestamp
    }
}

// MARK: - Context Telemetry Facts

/// A bounded fact representing an obstacle detected in the walking corridor.
///
/// ⚠ Not populated yet: `ConversationCoordinator.buildContext()` always passes
/// `recentObstacles: []`, and `ConversationPrompt.buildUserPrompt` does not serialize obstacles.
/// Kept as the schema for a later step; do not assume the model sees obstacles.
public struct ObstacleFact: Sendable, Equatable, Codable {
    /// Seconds (caller's clock) when the obstacle was seen.
    public let timestamp: TimeInterval
    /// Lane the obstacle is in: "left", "center" or "right" (free text, not an enum).
    public let side: String               // "left", "center", "right"
    /// Metres to the obstacle (LiDAR lane depth).
    public let distanceMeters: Float
    /// What it is, when known.
    public let label: String              // e.g. "pedestrian", "pole", "head-height obstacle"

    /// Memberwise; every field is stored as given (no validation).
    public init(timestamp: TimeInterval, side: String, distanceMeters: Float, label: String) {
        self.timestamp = timestamp
        self.side = side
        self.distanceMeters = distanceMeters
        self.label = label
    }
}

/// A bounded fact representing a detected ground hazard or roadside sign.
///
/// ⚠ Not populated by the app yet (`buildContext()` passes `recentHazards: []`). When present,
/// `ConversationPrompt.buildUserPrompt` puts only the LAST one's `description` into the prompt as
/// `recent_hazard`.
public struct HazardFact: Sendable, Equatable, Codable {
    /// Seconds (caller's clock) when the hazard was announced.
    public let timestamp: TimeInterval
    /// Hazard family: e.g. a `GroundHazardKind` raw value, "sign" or "vision" (free text).
    public let kind: String               // "dropOff", "curb", "sign", "pothole"
    /// The line that was spoken; this is what reaches the prompt.
    public let description: String        // "Caution: sidewalk closed."
    /// Where it was, when a fix existed.
    public let coordinate: Coordinate?

    /// Memberwise; `coordinate` defaults to nil (no fix).
    public init(timestamp: TimeInterval, kind: String, description: String, coordinate: Coordinate? = nil) {
        self.timestamp = timestamp
        self.kind = kind
        self.description = description
        self.coordinate = coordinate
    }
}

/// Live snapshot of all system, navigation, and environmental telemetry injected into the agent.
///
/// Built fresh for every cloud turn by `ConversationCoordinator.buildContext()` (the fast path
/// never needs it). Only some fields reach the model — see `ConversationPrompt.buildUserPrompt`
/// for which keys are written; `isNavigating`, `recentObstacles`, `gpsAccuracyM`,
/// `hapticsHealthy`, `hapticsSilenced` and `elapsedSeconds` are carried but not serialized today.
/// Sentinels: `batteryPercent` −1 and `gpsAccuracyM` −1 mean unknown.
public struct ConversationContext: Sendable, Equatable, Codable {
    // Navigation
    /// Where the walker is going. ⚠ The app currently passes `NavigationEngine.instruction` (the
    /// current spoken line) while navigating, not a place name; nil when idle.
    public var currentDestination: String?
    /// Next waypoint / instruction text (the app passes `nav.instruction`, nil when empty).
    public var nextWaypointName: String?
    /// Whole metres to the next waypoint (`nav.distanceToNext`), nil when unknown.
    public var distanceToNextMeters: Int?
    /// True while a route is guiding (`nav.isNavigating`).
    public var isNavigating: Bool

    // Safety & Environment
    /// Recent obstacles (not populated yet; see `ObstacleFact`).
    public var recentObstacles: [ObstacleFact]
    /// Recent announced hazards (not populated yet; see `HazardFact`).
    public var recentHazards: [HazardFact]
    /// The walker's saved posts (`ConversationCoordinator.markers`); their names go to the prompt.
    public var savedMarkers: [WalkMarker]

    // Hardware & Telemetry
    /// Phone battery 0…100, or −1 when unknown (then omitted from the prompt).
    public var batteryPercent: Int
    /// Headphones are the current audio output (`AudioRouteMonitor`).
    public var headphonesConnected: Bool
    /// Output route name ("AirPods Pro"); the prompt says "none" when not connected.
    public var headphoneName: String
    /// Horizontal accuracy of the last fix (m), −1 with no fix.
    public var gpsAccuracyM: Double
    /// Core Haptics engine is running.
    public var hapticsHealthy: Bool
    /// The walker silenced cane haptics (cues go to the watch / speech).
    public var hapticsSilenced: Bool

    // Walking Progress
    /// Seconds since the route started (`TripTracker.elapsed`).
    public var elapsedSeconds: TimeInterval
    /// Metres walked on this route (`TripTracker.distanceM`); omitted from the prompt when 0.
    public var distanceWalkedM: Double
    /// Steps since the route started (HealthKit via `TripTracker.steps`), nil before it reports.
    public var steps: Int?

    /// Every field defaults to the "nothing known, idle" snapshot (battery / accuracy −1, haptics
    /// healthy and not silenced). Pinned by `promptConstruction`.
    public init(currentDestination: String? = nil,
                nextWaypointName: String? = nil,
                distanceToNextMeters: Int? = nil,
                isNavigating: Bool = false,
                recentObstacles: [ObstacleFact] = [],
                recentHazards: [HazardFact] = [],
                savedMarkers: [WalkMarker] = [],
                batteryPercent: Int = -1,
                headphonesConnected: Bool = false,
                headphoneName: String = "",
                gpsAccuracyM: Double = -1,
                hapticsHealthy: Bool = true,
                hapticsSilenced: Bool = false,
                elapsedSeconds: TimeInterval = 0,
                distanceWalkedM: Double = 0,
                steps: Int? = nil) {
        self.currentDestination = currentDestination
        self.nextWaypointName = nextWaypointName
        self.distanceToNextMeters = distanceToNextMeters
        self.isNavigating = isNavigating
        self.recentObstacles = recentObstacles
        self.recentHazards = recentHazards
        self.savedMarkers = savedMarkers
        self.batteryPercent = batteryPercent
        self.headphonesConnected = headphonesConnected
        self.headphoneName = headphoneName
        self.gpsAccuracyM = gpsAccuracyM
        self.hapticsHealthy = hapticsHealthy
        self.hapticsSilenced = hapticsSilenced
        self.elapsedSeconds = elapsedSeconds
        self.distanceWalkedM = distanceWalkedM
        self.steps = steps
    }
}

// MARK: - Conversation Turns & History

/// A tool invocation executed during a conversation turn.
///
/// Built by `ConversationResponseParser.parse` when the model names a known `ConversationTool`;
/// executed by `ConversationCoordinator.executeTool` and appended to the turn's `toolsInvoked`.
public struct ToolInvocation: Sendable, Equatable, Codable {
    /// Which tool the model asked for.
    public let tool: ConversationTool
    /// The model's `args`, as strings (booleans arrive as "true" / "false" and are parsed with
    /// `Bool(_:)` by the app; a JSON non-string value makes the whole reply fall back to plain text).
    public let arguments: [String: String]
    /// The sanitized spoken reply that accompanied the call (the parser copies it here).
    public let resultSummary: String

    /// Memberwise.
    public init(tool: ConversationTool, arguments: [String: String], resultSummary: String) {
        self.tool = tool
        self.arguments = arguments
        self.resultSummary = resultSummary
    }
}

/// One round of spoken dialogue between the walker and OpenCane.
///
/// Created by `ConversationCoordinator.handleQuery` for every non-empty query (fast path, scene
/// path, no-cloud line and cloud path alike) and appended to `ConversationHistory`.
public struct ConversationTurn: Sendable, Equatable, Identifiable, Codable {
    /// Unique turn id.
    public let id: UUID
    /// Seconds since 1970 when the query arrived.
    public let timestamp: TimeInterval
    /// What the walker said or typed (trimmed).
    public let userQuery: String
    /// What OpenCane answered (or the fallback line); nil until answered.
    public var agentResponse: String?
    /// The GPS fix at query time, nil with no fix.
    public let location: Coordinate?
    /// Tools the cloud model invoked in this turn (the fast path records none).
    public var toolsInvoked: [ToolInvocation]
    /// Cloud round-trip in milliseconds; nil for fast-path / local turns.
    public var latencyMs: Int?

    /// Memberwise with defaults for the not-yet-known parts (response, location, tools, latency).
    public init(id: UUID = UUID(),
                timestamp: TimeInterval,
                userQuery: String,
                agentResponse: String? = nil,
                location: Coordinate? = nil,
                toolsInvoked: [ToolInvocation] = [],
                latencyMs: Int? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.userQuery = userQuery
        self.agentResponse = agentResponse
        self.location = location
        self.toolsInvoked = toolsInvoked
        self.latencyMs = latencyMs
    }
}

/// A sliding window of conversation turns for short-term memory.
///
/// Owner: `ConversationCoordinator.history` (main actor). Not persisted: memory ends with the
/// process. Note `ConversationPrompt.buildUserPrompt` sends only the last 3 turns of it.
/// Pinned by `historyRingBuffer`.
public struct ConversationHistory: Sendable, Equatable {
    /// Default maximum turns retained in memory.
    public static let defaultMaxTurns: Int = 6

    /// Turns oldest first, at most `maxTurns`.
    public private(set) var turns: [ConversationTurn]
    /// Capacity of the window (not validated; a value ≤ 0 keeps nothing).
    public let maxTurns: Int

    /// - Parameters:
    ///   - turns: seed turns (not trimmed until the next `append`).
    ///   - maxTurns: window size, default `defaultMaxTurns` (6).
    public init(turns: [ConversationTurn] = [], maxTurns: Int = defaultMaxTurns) {
        self.turns = turns
        self.maxTurns = maxTurns
    }

    /// Appends a new turn, purging the oldest if over `maxTurns`.
    public mutating func append(turn: ConversationTurn) {
        turns.append(turn)
        if turns.count > maxTurns {
            turns.removeFirst(turns.count - maxTurns)
        }
    }

    /// Updates the latest turn with the agent's completed response and tool execution record.
    /// Replaces (not appends to) the tool list; a no-op on an empty history. The app currently
    /// fills the turn before `append` instead, so only the tests call this.
    public mutating func updateLastResponse(_ response: String, tools: [ToolInvocation] = [], latencyMs: Int? = nil) {
        guard !turns.isEmpty else { return }
        let idx = turns.count - 1
        turns[idx].agentResponse = response
        turns[idx].toolsInvoked = tools
        turns[idx].latencyMs = latencyMs
    }

    /// Clears the history. No app caller today (memory lasts until the process ends).
    public mutating func clear() {
        turns.removeAll()
    }
}

// MARK: - Tools & Actions

/// Discrete tools available to the conversational dispatcher.
///
/// ⚠ Raw values are the tool names in `ConversationPrompt.toolDeclarationsJSON` and in the model's
/// JSON reply; an unknown name parses to no tool call. `ConversationCoordinator.executeTool`
/// handles `navigateTo`, `stopNavigation`, `dropMarker`, `queryScene`, `setSetting` and
/// `setCaneSilenced`; `queryStatus` and `queryHistory` fall to its `default` (no effect — the
/// model's own `spoken_response` is all the walker hears).
public enum ConversationTool: String, Sendable, Codable, CaseIterable {
    /// Start a walking route; arg `destination` → `AppModel.navigate(to:)`.
    case navigateTo = "navigate_to"
    /// Stop the route → `AppModel.stopRoute()`.
    case stopNavigation = "stop_navigation"
    /// Save the current spot; arg `name` (default "Marker N") → `dropPost(name:)`.
    case dropMarker = "drop_marker"
    /// Ask about the camera frame; arg `question` → `AppModel.askAboutScene(_:)`.
    case queryScene = "query_scene"
    /// Telemetry question (not executed by the app today; see the type comment).
    case queryStatus = "query_status"
    /// Trip-history question (not executed by the app today).
    case queryHistory = "query_history"
    /// Toggle a hands-free option; args `option` (a `HandsFreeOption` raw value) and `enabled`.
    case setSetting = "set_setting"
    /// Silence / unsilence cane haptics; arg `silenced` ("true" / "false").
    case setCaneSilenced = "set_cane_silenced"
}

/// Telemetry aspect requested in a status query. Answered by `ConversationCoordinator.executeAction`
/// with the matching `StatusSummary` line (`all` → `StatusSummary.sentence`).
public enum StatusAspect: String, Sendable, Codable {
    // `all` everything (`StatusSummary.sentence`, six clauses); `battery` phone battery;
    // `headphones` audio output / AirPods; `gps` fix and accuracy (never produced by the fast path
    // today); `route` progress / distance to the next point; `haptics` engine / silenced / watch.
    case all, battery, headphones, gps, route, haptics
}

/// Metric requested in a history query. Answered by `ConversationCoordinator.executeAction`
/// from `TripTracker` (`steps`, `distanceWalked`); `hazardsEncountered` currently gets a fixed
/// "No severe hazards reported on this route." (not backed by the hazard log), and
/// `pastWaypoints` / `recentEvents` get "No trip records available.".
public enum HistoryMetric: String, Sendable, Codable {
    // `steps` HealthKit steps this route; `distanceWalked` metres this route; `hazardsEncountered`
    // hazards announced (not implemented in the app, see above); `pastWaypoints` / `recentEvents`
    // have no answer yet.
    case steps, distanceWalked, hazardsEncountered, pastWaypoints, recentEvents
}

/// Concrete actions executed by the app model.
///
/// Produced by `FastPathIntentClassifier.classify` (the only producer today) and executed by
/// `ConversationCoordinator.executeAction`, which returns the confirmation line and whether the
/// underlying `AppModel` effect already spoke (so the answer is not said twice).
public enum ConversationAction: Sendable, Equatable {
    /// Say this text as the answer (not produced by the classifier today).
    case speakImmediate(String)
    /// Walk to a destination: a gazetteer `CampusPlace.name` or the capitalised typed target;
    /// the app calls `AppModel.navigate(to:)`, which runs the gazetteer + MapKit path again.
    case startRoute(destination: String)
    /// Stop the route (`AppModel.stopRoute()` speaks "Route stopped.").
    case stopRoute
    /// Save a post with this name ("Marker" when none was given).
    case recordMarker(name: String)
    /// Ask the camera path a question (not produced by the classifier; scene questions are routed
    /// by `FastPathIntentClassifier.isSceneQuestion` instead).
    case inspectScene(question: String)
    /// Answer one status aspect from live `StatusFacts`.
    case answerStatus(aspect: StatusAspect)
    /// Answer a trip-history metric; `windowSeconds` nil = this route (the app ignores it today).
    case answerHistory(metric: HistoryMetric, windowSeconds: TimeInterval?)
    /// Turn a hands-free option on / off; `option` must be a `HandsFreeOption` raw value
    /// ("beacon", "dropOffs", "hazardWatch", "nodToTalk", …) or the app says "Option not recognized.".
    case updateSetting(option: String, enabled: Bool)
    /// Silence (true) or restore (false) cane haptics (`AppModel.setHapticsSilenced`).
    case silenceCane(silenced: Bool)
    // MARK: Voice shell (Step 56) — produced by `FastPathIntentClassifier` rule 0 (`VoiceMenu`)

    /// "route" / one: start the recorded CIF demo route (`AppModel.startDemoRoute`); while a
    /// route runs, the route clause instead. "take me to …" stays `.startRoute`.
    case startDefaultRoute
    /// "where am I" / "describe" / two / three: describe the scene (`AppModel.describeScene`).
    case describeScene
    /// "status" / four: the whole spoken status report (`AppModel.speakStatus`).
    case speakStatus
    /// "repeat" / five: say the current instruction again (`AppModel.repeatInstruction`).
    case repeatInstruction
    /// "next": skip to the next waypoint (`AppModel.nextWaypoint`).
    case nextWaypoint
    /// "quiet" / six, "standard", "detailed": set the cue level (`AppModel.setCueLevel`).
    case setCueLevel(CueLevel)
    /// "help" / seven: read the numbered list (`VoiceMenu.helpLine`).
    case help
    /// "emergency" / eight: prompt for the confirmation-gated call (`EmergencyConfirm`).
    case emergency
    /// "yes" (true) / "no", "cancel" (false): the answer to a pending emergency prompt.
    case confirm(Bool)
}
