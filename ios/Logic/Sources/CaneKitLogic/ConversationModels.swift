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
//  Key invariants:
//    · Foundation only (no UIKit / CoreLocation / MapKit); coordinates use `Coordinate`.
//    · Sendable throughout for Swift 6 strict concurrency.
//    · Decisions belong in CaneKitLogic with tests; effects belong in the app.
//

import Foundation

// MARK: - Voice-Dropped Markers ("Posts")

/// A voice-dropped marker/post at a specific GPS coordinate ("set a post here", "mark entrance").
public struct WalkMarker: Sendable, Equatable, Codable, Identifiable {
    /// Unique marker identifier.
    public let id: UUID
    /// Spoken or assigned name ("Marker 1", "Townsend Hall entrance", "Favorite bench").
    public let name: String
    /// The coordinate where the post was dropped.
    public let coordinate: Coordinate
    /// Seconds since 1970 when dropped.
    public let timestamp: TimeInterval

    public init(id: UUID = UUID(), name: String, coordinate: Coordinate, timestamp: TimeInterval) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.timestamp = timestamp
    }
}

// MARK: - Context Telemetry Facts

/// A bounded fact representing an obstacle detected in the walking corridor.
public struct ObstacleFact: Sendable, Equatable, Codable {
    public let timestamp: TimeInterval
    public let side: String               // "left", "center", "right"
    public let distanceMeters: Float
    public let label: String              // e.g. "pedestrian", "pole", "head-height obstacle"

    public init(timestamp: TimeInterval, side: String, distanceMeters: Float, label: String) {
        self.timestamp = timestamp
        self.side = side
        self.distanceMeters = distanceMeters
        self.label = label
    }
}

/// A bounded fact representing a detected ground hazard or roadside sign.
public struct HazardFact: Sendable, Equatable, Codable {
    public let timestamp: TimeInterval
    public let kind: String               // "dropOff", "curb", "sign", "pothole"
    public let description: String        // "Caution: sidewalk closed."
    public let coordinate: Coordinate?

    public init(timestamp: TimeInterval, kind: String, description: String, coordinate: Coordinate? = nil) {
        self.timestamp = timestamp
        self.kind = kind
        self.description = description
        self.coordinate = coordinate
    }
}

/// Live snapshot of all system, navigation, and environmental telemetry injected into the agent.
public struct ConversationContext: Sendable, Equatable, Codable {
    // Navigation
    public var currentDestination: String?
    public var nextWaypointName: String?
    public var distanceToNextMeters: Int?
    public var isNavigating: Bool

    // Safety & Environment
    public var recentObstacles: [ObstacleFact]
    public var recentHazards: [HazardFact]
    public var savedMarkers: [WalkMarker]

    // Hardware & Telemetry
    public var batteryPercent: Int
    public var headphonesConnected: Bool
    public var headphoneName: String
    public var gpsAccuracyM: Double
    public var hapticsHealthy: Bool
    public var hapticsSilenced: Bool

    // Walking Progress
    public var elapsedSeconds: TimeInterval
    public var distanceWalkedM: Double
    public var steps: Int?

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
public struct ToolInvocation: Sendable, Equatable, Codable {
    public let tool: ConversationTool
    public let arguments: [String: String]
    public let resultSummary: String

    public init(tool: ConversationTool, arguments: [String: String], resultSummary: String) {
        self.tool = tool
        self.arguments = arguments
        self.resultSummary = resultSummary
    }
}

/// One round of spoken dialogue between the walker and OpenCane.
public struct ConversationTurn: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public let timestamp: TimeInterval
    public let userQuery: String
    public var agentResponse: String?
    public let location: Coordinate?
    public var toolsInvoked: [ToolInvocation]
    public var latencyMs: Int?

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
public struct ConversationHistory: Sendable, Equatable {
    /// Default maximum turns retained in memory.
    public static let defaultMaxTurns: Int = 6

    public private(set) var turns: [ConversationTurn]
    public let maxTurns: Int

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
    public mutating func updateLastResponse(_ response: String, tools: [ToolInvocation] = [], latencyMs: Int? = nil) {
        guard !turns.isEmpty else { return }
        let idx = turns.count - 1
        turns[idx].agentResponse = response
        turns[idx].toolsInvoked = tools
        turns[idx].latencyMs = latencyMs
    }

    /// Clears the history.
    public mutating func clear() {
        turns.removeAll()
    }
}

// MARK: - Tools & Actions

/// Discrete tools available to the conversational dispatcher.
public enum ConversationTool: String, Sendable, Codable, CaseIterable {
    case navigateTo = "navigate_to"
    case stopNavigation = "stop_navigation"
    case dropMarker = "drop_marker"
    case queryScene = "query_scene"
    case queryStatus = "query_status"
    case queryHistory = "query_history"
    case setSetting = "set_setting"
    case setCaneSilenced = "set_cane_silenced"
}

/// Telemetry aspect requested in a status query.
public enum StatusAspect: String, Sendable, Codable {
    case all, battery, headphones, gps, route, haptics
}

/// Metric requested in a history query.
public enum HistoryMetric: String, Sendable, Codable {
    case steps, distanceWalked, hazardsEncountered, pastWaypoints, recentEvents
}

/// Concrete actions executed by the app model.
public enum ConversationAction: Sendable, Equatable {
    case speakImmediate(String)
    case startRoute(destination: String)
    case stopRoute
    case recordMarker(name: String)
    case inspectScene(question: String)
    case answerStatus(aspect: StatusAspect)
    case answerHistory(metric: HistoryMetric, windowSeconds: TimeInterval?)
    case updateSetting(option: String, enabled: Bool)
    case silenceCane(silenced: Bool)
}
