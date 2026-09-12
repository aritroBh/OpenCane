//
//  LaneReport.swift
//  CaneKitLogic
//
//  What the depth pipeline publishes, ~15 Hz. Value type so it can cross actors.
//
//  Purpose: the single value `DepthEngine` hands to `AppModel` per depth frame — the lane grid,
//  whether the frame is trustworthy (cane not sweeping), and the classified mesh face at the
//  image centre for obstacle names. Also the colour rule for the debug lane grid.
//
//  Key invariants:
//    · All distances in metres; `rotationRate` in rad/s; `timestamp` in seconds on ARKit's
//      monotonic clock (the `now` `CueDecider` receives).
//    · `ObstacleClass` raw values mirror `ARMeshClassification` (order must stay in sync).
//    · `depthAvailable == false` or `isTrusted == false` → `CueDecider` emits nothing.
//  Tests: `tileLevels` (LaneMathTests.swift); the report itself is exercised by CueDeciderTests.
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

/// A classified mesh face found along the centre ray.
public struct MeshHit: Sendable, Equatable {
    /// What the face is (ARKit classification).
    public var classification: ObstacleClass
    /// Distance from the camera to the face, metres.
    public var distance: Float
    /// Creates a hit from its classification and distance (metres).
    public init(classification: ObstacleClass, distance: Float) {
        self.classification = classification
        self.distance = distance
    }
}

/// One depth frame's worth of obstacle information, as published by the depth pipeline.
public struct LaneReport: Sendable, Equatable {
    /// Per-lane head / torso depths (metres) from `LaneMath`.
    public var grid: LaneGrid
    /// False while the cane is being swept (|ω| ≥ threshold): depth is smeared, cues freeze.
    public var isTrusted: Bool
    /// |rotation rate| rad/s (logged as `omega` in the trip log).
    public var rotationRate: Float
    /// Frame time, seconds (ARKit's monotonic clock).
    public var timestamp: TimeInterval
    /// False until the first depth frame (or on non-LiDAR devices).
    public var depthAvailable: Bool
    /// True when the ARKit frame that produced this report had `.normal` camera tracking.
    /// This is kept as a value in the report because the AR session's tracking delegate callback
    /// is delivered separately from the frame callback; route-start readiness must judge the exact
    /// frame carrying the depth map, not a possibly stale main-actor status string.
    public var trackingNormal: Bool
    /// Monotonic sequence of published reports in the depth session. The app uses this to detect
    /// a `bufferingNewest(1)` delivery gap and conservatively restart the consecutive run rather
    /// than treating reports on either side of a dropped frame as adjacent.
    public var frameSequence: Int
    /// Nearest classified mesh face at the image centre, if any.
    public var centerHit: MeshHit?
    /// Confirmed LiDAR ground hazard ahead (drop-off, hole, curb, low obstacle), if any.
    /// Set by `DepthFrameProcessor` from `GroundHazardDetector` (evaluated up to ~7 Hz, confirmed over frames).
    public var groundHazard: GroundHazard?
    /// How far the camera looks below the horizon, degrees (positive = down), smoothed over
    /// ~1 s of trusted frames; nil before the first frame. See `MountTilt`.
    public var cameraTiltDownDeg: Float?

    /// Every parameter defaults to the "no depth yet" state (empty grid, trusted, no data).
    public init(grid: LaneGrid = .empty,
                isTrusted: Bool = true,
                rotationRate: Float = 0,
                timestamp: TimeInterval = 0,
                depthAvailable: Bool = false,
                trackingNormal: Bool = false,
                frameSequence: Int = 0,
                centerHit: MeshHit? = nil,
                groundHazard: GroundHazard? = nil,
                cameraTiltDownDeg: Float? = nil) {
        self.grid = grid
        self.isTrusted = isTrusted
        self.rotationRate = rotationRate
        self.timestamp = timestamp
        self.depthAvailable = depthAvailable
        self.trackingNormal = trackingNormal
        self.frameSequence = frameSequence
        self.centerHit = centerHit
        self.groundHazard = groundHazard
        self.cameraTiltDownDeg = cameraTiltDownDeg
    }

    /// Shortcut for `grid.head` (metres; 0 left, 1 centre, 2 right).
    public var head: [Float] { grid.head }
    /// Shortcut for `grid.torso` (metres; 0 left, 1 centre, 2 right).
    public var torso: [Float] { grid.torso }
}

/// The mount's camera aim. The lane grid skips a fixed bottom fraction of the image as ground
/// (`LaneConfig.groundSkipFraction`, no gravity correction), so the phone must look only a little
/// below the horizon: at ~10° down the torso lanes already read bare pavement near 2 m (the
/// centre-approach threshold) and the cane buzzes on an empty sidewalk; at 0° or above the ground
/// detector loses its 0.8–1.5 m ground reference. hardware/mount/DESIGN.md and pitch_model.py
/// derive the 3–8° window. Pinned by `mountTiltWindow`.
public enum MountTilt {
    /// Degrees below the horizon that work with the current lane grid.
    public static let aim: ClosedRange<Float> = 3...8

    /// Ground hazards (drop-offs, holes, curbs) are judged only when the camera looks 0-15 deg below
    /// the horizon, i.e. roughly the way the mount holds it. The real phone's false "Hole ahead"
    /// calls came at 10-57 deg with the phone held in the hand, pointed at desks and the floor.
    public static let groundAim: ClosedRange<Float> = 0...15
    public static func groundUsable(downDeg d: Float) -> Bool { groundAim.contains(d) }

    /// Camera angle below the horizon (degrees, positive = down) from the Y component of the
    /// camera transform's Z column in ARKit's gravity-aligned world (+Y up). The camera looks
    /// along −Z, so a camera pitched down θ has look.y = −sin θ and column2.y = +sin θ.
    /// Pinned by `tiltSignIsDownPositive` (Antigravity claimed it was inverted; it is not).
    public static func downDegrees(cameraZColumnY y: Float) -> Float {
        asin(max(-1, min(1, y))) * 180 / .pi
    }

    /// One line for the Mount card and whether the aim is inside `aim`:
    /// "Camera tilt 5° down, good", "Camera tilt 12° down: tilt the phone up",
    /// "Camera tilt 2° up: tilt the phone down", "Camera level: tilt the phone down".
    public static func status(downDeg d: Float) -> (text: String, ok: Bool) {
        let n = Int(abs(d).rounded())
        // Judge the number that is shown: 2.6° reads "3°" and must be "good", not "tilt down"
        // (Muse camera review).
        let shown = Float(d < 0 ? -n : n)
        if n == 0 { return ("Camera level: tilt the phone down", false) }
        let dir = d < 0 ? "up" : "down"
        if aim.contains(shown) { return ("Camera tilt \(n)° \(dir), good", true) }
        return (shown > aim.upperBound ? "Camera tilt \(n)° \(dir): tilt the phone up"
                                   : "Camera tilt \(n)° \(dir): tilt the phone down", false)
    }
}

/// Tile colouring for the debug grid: green ≥ 2.0 m, yellow ≥ 1.2 m, red < 0.7 m (orange between).
public enum TileLevel: Sendable {
    case clear, far, near, urgent, noData

    /// - Parameters:
    ///   - distance: cell depth, metres (`.infinity` = clear).
    ///   - hasData: false before the first depth frame / on non-LiDAR devices.
    /// - Returns: `.noData` without data; `.clear` for non-finite or ≥ 2.0 m; `.far` ≥ 1.2 m;
    ///   `.near` ≥ 0.7 m; else `.urgent`. Pinned by `tileLevels`.
    public static func level(for distance: Float, hasData: Bool) -> TileLevel {
        guard hasData, distance.isFinite else { return hasData ? .clear : .noData }
        if distance < 0.7 { return .urgent }
        if distance < 1.2 { return .near }
        if distance < 2.0 { return .far }
        return .clear
    }
}

/// Publish-rate cap for depth reports. ARKit delivers frames every 1/30 s (or 1/60 s); a plain
/// `now − last ≥ 1/15` check fails by floating-point hair on the second 33.3 ms frame (66.66 ms <
/// 66.67 ms) and waits for the third, so a 15 Hz cap ran at exactly 10 Hz on the real iPhone
/// (first device run, 2026-09-11). A small tolerance (a quarter of a 60 Hz frame) fixes it.
/// Pinned by `publishGateHitsFifteenHertzFromThirtyHertzFrames`.
public struct PublishGate: Sendable {
    public var maxRate: Double
    private var last: TimeInterval = -.infinity
    public init(maxRate: Double) { self.maxRate = maxRate }

    /// True when a frame at `now` (seconds) should be published; records it if so.
    public mutating func shouldPublish(at now: TimeInterval) -> Bool {
        guard now - last >= 1.0 / maxRate - 0.004 else { return false }
        last = now
        return true
    }
}
