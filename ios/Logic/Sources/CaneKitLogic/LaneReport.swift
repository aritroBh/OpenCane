//
//  LaneReport.swift
//  CaneKitLogic
//
//  What the depth pipeline publishes, ~15 Hz. Value type so it can cross actors.
//

import Foundation

/// ARKit mesh classification, mirrored here so the logic package stays free of ARKit.
public enum ObstacleClass: Int, Sendable, Codable, CaseIterable {
    case none = 0, wall, floor, ceiling, table, seat, window, door

    /// Spoken name, or nil for classes we never announce.
    public var spokenName: String? {
        switch self {
        case .wall: return "wall"
        case .table: return "table"
        case .seat: return "seat"
        case .window: return "window"
        case .door: return "door"
        case .none, .floor, .ceiling: return nil
        }
    }
}

public struct MeshHit: Sendable, Equatable {
    public var classification: ObstacleClass
    public var distance: Float
    public init(classification: ObstacleClass, distance: Float) {
        self.classification = classification
        self.distance = distance
    }
}

public struct LaneReport: Sendable, Equatable {
    public var grid: LaneGrid
    /// False while the cane is being swept (|ω| ≥ threshold): depth is smeared, cues freeze.
    public var isTrusted: Bool
    /// |rotation rate| rad/s, for the debug footer.
    public var rotationRate: Float
    public var timestamp: TimeInterval
    /// False until the first depth frame (or on non-LiDAR devices).
    public var depthAvailable: Bool
    /// Nearest classified mesh face at the image centre, if any.
    public var centerHit: MeshHit?

    public init(grid: LaneGrid = .empty,
                isTrusted: Bool = true,
                rotationRate: Float = 0,
                timestamp: TimeInterval = 0,
                depthAvailable: Bool = false,
                centerHit: MeshHit? = nil) {
        self.grid = grid
        self.isTrusted = isTrusted
        self.rotationRate = rotationRate
        self.timestamp = timestamp
        self.depthAvailable = depthAvailable
        self.centerHit = centerHit
    }

    public var head: [Float] { grid.head }
    public var torso: [Float] { grid.torso }
}

/// Tile colouring for the debug grid: green ≥ 2.0 m, yellow ≥ 1.2 m, red < 0.7 m (orange between).
public enum TileLevel: Sendable {
    case clear, far, near, urgent, noData

    public static func level(for distance: Float, hasData: Bool) -> TileLevel {
        guard hasData, distance.isFinite else { return hasData ? .clear : .noData }
        if distance < 0.7 { return .urgent }
        if distance < 1.2 { return .near }
        if distance < 2.0 { return .far }
        return .clear
    }
}
