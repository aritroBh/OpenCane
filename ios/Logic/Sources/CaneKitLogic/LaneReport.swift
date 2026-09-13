//
//  LaneReport.swift
//  CaneKitLogic
//
//  What the depth pipeline publishes, ~30 Hz normal / up to 60 Hz high-rate. Value type so it can cross actors.
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
//  Owners: built by `DepthFrameProcessor.session(_:didUpdate:)` (serial depth queue) and yielded
//  into a newest-only `AsyncStream`; `DepthEngine.ingest` publishes it on the main actor
//  (`DepthEngine.report`) and feeds `DepthReadiness`; `AppModel.handle(_:)` routes it to
//  `CueDecider`, `ObstacleNamer`, `GroundHazardPolicy`, `SceneContext` and the `lanes` trip-log
//  record (throttled to 2 Hz by `TripLogger.lanes`). `MountTilt` also drives the Settings → Mount
//  "Camera tilt" row; `TileLevel` colours `LaneGridView`; `PublishGate` is the processor's rate cap.
//  Tests: `tileLevels`, `mountTiltStatus`, `tiltSignIsDownPositive`,
//  `publishGateHitsFifteenHertzFromThirtyHertzFrames`, `groundHazardsNeedAMountLikeTilt` (all in
//  LaneMathTests.swift); `mountTiltStatusSaysTooSteepForHeadCover`, `tileNoCoverIsNotClear`,
//  `headCoverLimitFollowsTheGeometry` and the `HeadCoverNotice` cases (LaneGeometryTests.swift);
//  the report itself is exercised by CueDeciderTests and DepthReadinessTests.
//

import Foundation

/// ARKit mesh classification, mirrored here so the logic package stays free of ARKit.
/// Produced by the app's `MeshClassifier.nearestFace` (ARKit mesh faces along the centre ray).
public enum ObstacleClass: Int, Sendable, Codable, CaseIterable {
    // ⚠ Raw values must equal `ARMeshClassification`'s (0 none … 7 door); the app converts by raw value.
    case none = 0, wall, floor, ceiling, table, seat, window, door

    /// Spoken name, or nil for classes we never announce. Whether a speakable name is actually
    /// said is `CueRules.allowsName` (Detailed never says "wall", Step 36).
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
    /// False while the cane is being swept (|ω| ≥ `ProcessorSettings.sweepThreshold`, 0.6 rad/s):
    /// depth is smeared, cues freeze. Also one of `DepthReadiness`'s three same-frame facts.
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
    /// Nearest classified mesh face at the image centre, if any. Looked up every
    /// `meshEveryNthFrame`-th published frame (8) and re-attached in between, so it can be up to
    /// 7 reports old; nil while mesh classification is off (thermal).
    public var centerHit: MeshHit?
    /// Confirmed LiDAR ground hazard ahead (drop-off, hole, curb, low obstacle), if any.
    /// Set by `DepthFrameProcessor` from `GroundHazardDetector` (evaluated up to 10 Hz, confirmed over frames).
    public var groundHazard: GroundHazard?
    /// How far the camera looks below the horizon, degrees (positive = down), smoothed over
    /// ~0.5 s at the normal 30 Hz publish rate; nil before the first frame. See `MountTilt`.
    public var cameraTiltDownDeg: Float?
    /// ARKit's ambient light estimate for this frame, lux (`ARFrame.lightEstimate?.ambientIntensity`;
    /// ~1000 = a well-lit room per Apple's docs); nil when ARKit gave none (the simulator, light
    /// estimation off). Raw per frame — `LowLightPolicy` (Step 49) smooths and debounces it in
    /// `AppModel.handle(_:)`; nobody else should act on a single frame's value.
    public var ambientLux: Float?
    /// The camera pose and depth-map intrinsics the metric bands were cut with (Step 51); nil in
    /// rows mode (no pose yet). `AppModel.handle` logs a `depth_geometry` record once per distinct
    /// set of intrinsics so a trip log can be re-bucketed offline.
    public var geometry: LaneGeometry?

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
                cameraTiltDownDeg: Float? = nil,
                ambientLux: Float? = nil,
                geometry: LaneGeometry? = nil) {
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
        self.ambientLux = ambientLux
        self.geometry = geometry
    }

    /// Shortcut for `grid.head` (metres; 0 left, 1 centre, 2 right).
    public var head: [Float] { grid.head }
    /// Shortcut for `grid.torso` (metres; 0 left, 1 centre, 2 right).
    public var torso: [Float] { grid.torso }
}

/// The mount's camera aim. Since Step 51 the lane grid is gravity-corrected (`LaneGeometry`), so
/// the pitch is no longer a *correctness* requirement for the lanes — it is a *coverage* one: at
/// camera height 95 cm the top ray of the 67° portrait field of view stops reaching 140 cm at
/// 1.5 m once the camera looks more than `headCoverLimitDeg()` (≈ 19°) below the horizon, and
/// beyond that the head band is "NO COVER" (`LaneGrid.headCoverage`). The ground detector still
/// wants 0–15° (`groundAim`). Together they keep the hinge recommendation at a few degrees down
/// (hardware/mount/DESIGN.md §4): `aim` is that recommendation, kept for the docs and the hinge
/// scale, not read by the lane code. Pinned by `mountTiltStatus`, `headCoverLimitFollowsTheGeometry`.
public enum MountTilt {
    /// Degrees below the horizon the hinge should sit at: inside the ground detector's window
    /// with head cover to spare. A recommendation since Step 51, not a lane requirement.
    public static let aim: ClosedRange<Float> = 3...8

    /// Ground hazards (drop-offs, holes, curbs) are judged only when the camera looks 0-15 deg below
    /// the horizon, i.e. roughly the way the mount holds it. The real phone's false "Hole ahead"
    /// calls came at 10-57 deg with the phone held in the hand, pointed at desks and the floor.
    public static let groundAim: ClosedRange<Float> = 0...15
    /// True when a ground-hazard evaluation may run at this camera tilt (degrees below the horizon,
    /// + = down). `DepthFrameProcessor` passes 90 (unusable) before the first tilt estimate.
    /// Pinned by `groundHazardsNeedAMountLikeTilt`.
    public static func groundUsable(downDeg d: Float) -> Bool { groundAim.contains(d) }

    /// Camera angle below the horizon (degrees, positive = down) from the Y component of the
    /// camera transform's Z column in ARKit's gravity-aligned world (+Y up). The camera looks
    /// along −Z, so a camera pitched down θ has look.y = −sin θ and column2.y = +sin θ.
    /// Pinned by `tiltSignIsDownPositive` (Antigravity claimed it was inverted; it is not).
    public static func downDegrees(cameraZColumnY y: Float) -> Float {
        asin(max(-1, min(1, y))) * 180 / .pi
    }

    /// The steepest pitch (degrees below the horizon) at which the *top ray* of the portrait field
    /// of view still reaches `headMinHeightCm` at `coverageRangeCm` of **z-depth** (ARKit's
    /// `sceneDepth` is distance along the optical axis, as `GroundSampler` treats it) from a camera
    /// `cameraHeightCm` above the ground. The top ray gains `cos θ · tan h − sin θ` metres of height
    /// per metre of z-depth (θ pitch, h half FOV), so the limit solves
    /// `cos θ · tan h − sin θ = k`, `k = (headMin − camH) / range`:
    /// `θ = acos(k · cos h) − (90° − h)`. Defaults (`LaneConfig`'s 95 / 140 / 150 cm and the 256-px
    /// long axis of ARKit's depth map, half FOV ≈ 33.5°) → ≈ 19.0°. Documentation, the Mount card
    /// estimate without a grid and `cue_audit.py`'s cover verdict for rows-mode logs; the app itself
    /// uses the per-lane `headCoverage` flags, which need `minSamplesPerCell` rays in one lane and
    /// so fall off within a degree below this. (A first pass used `h − atan(k)`, the range-based
    /// formula, which gives 16.8° — wrong for z-depth; `headCoverLimitFollowsTheGeometry` pins
    /// the flag sweep against this function.)
    public static func headCoverLimitDeg(cameraHeightCm: Float = 95,
                                         headMinHeightCm: Float = 140,
                                         coverageRangeCm: Float = 150,
                                         halfFovDeg: Float = 33.5) -> Float {
        let k = (headMinHeightCm - cameraHeightCm) / coverageRangeCm
        let h = halfFovDeg * .pi / 180
        let arg = max(-1, min(1, k * cos(h)))
        return (acos(arg) - (.pi / 2 - h)) * 180 / .pi
    }

    /// One line for the Mount card and whether the aim is usable:
    /// "Camera tilt 5° down, good"; "Camera tilt 25° down: too steep for head-height cover"
    /// (ok false — the lanes still see torso height, the head band is NO COVER); "Camera tilt 2°
    /// up: tilt the phone down"; "Camera level: tilt the phone down" (the ground detector needs
    /// the ground in view). Since Step 51 a steep-but-covered pitch (12°) is good: the bands are
    /// metric, so pavement no longer reads as an obstacle at any pitch.
    /// - Parameters:
    ///   - d: degrees below the horizon (positive = down).
    ///   - headCover: `LaneGrid.headCoverage.contains(true)` for the live frame.
    /// Caller: `ContentView`'s `MountAimRow` (Settings → Mount). Pinned by `mountTiltStatus`,
    /// `mountTiltStatusSaysTooSteepForHeadCover`.
    public static func status(downDeg d: Float, headCover: Bool) -> (text: String, ok: Bool) {
        let n = Int(abs(d).rounded())
        // Judge the number that is shown: 0.3° reads "0°" and must be "level" (Muse camera review).
        if n == 0 { return ("Camera level: tilt the phone down", false) }
        if d < 0 { return ("Camera tilt \(n)° up: tilt the phone down", false) }
        if !headCover { return ("Camera tilt \(n)° down: too steep for head-height cover", false) }
        return ("Camera tilt \(n)° down, good", true)
    }

    /// `status(downDeg:headCover:)` with the cover estimated from the geometry alone (the shown
    /// angle against `headCoverLimitDeg()`): tests, docs and a caller without a live grid.
    public static func status(downDeg d: Float) -> (text: String, ok: Bool) {
        let shown = Float(Int(abs(d).rounded()))
        return status(downDeg: d, headCover: shown <= headCoverLimitDeg())
    }
}

/// The one spoken admission that head cover is missing (Step 51): "Camera too steep for
/// head-height cover. Torso obstacles only." — once per route, at `.nav`, after the head band has
/// been uncovered in every lane for `holdSeconds` of trusted metric frames. The hold keeps a
/// phone picked up to tap Start (a transient 45°) from triggering it; the once-per-route keeps it
/// from nagging while the walker decides. Owner: `AppModel.headCoverNotice` (`routeStarted()` in
/// `startRouteNow`, `update` per report in `handle`). ⚠ The line is in `AppModel.commonLines`
/// (prefetched; matched by bytes). Pinned by `headCoverNoticeSpeaksOncePerRouteAfterTheHold`,
/// `headCoverNoticeIgnoresRowsModeAndTransients`.
public struct HeadCoverNotice: Sendable, Equatable {
    /// The line the app speaks. ⚠ Byte-identical copy in `AppModel.commonLines`.
    public static let line = "Camera too steep for head-height cover. Torso obstacles only."
    /// Seconds the head band must stay uncovered (trusted, metric frames) before the line.
    public var holdSeconds: TimeInterval = 2.0
    /// When the current uncovered run began; nil while covered / untrusted / rows mode.
    private var uncoveredSince: TimeInterval?
    /// True once the line was spoken on this route.
    private var spoken = false

    /// A notice armed for a new route.
    public init() {}

    /// A new route: the line may be spoken again.
    public mutating func routeStarted() { uncoveredSince = nil; spoken = false }

    /// Feed one depth report while navigating.
    /// - Parameters:
    ///   - metric: `grid.bandMode == .metric` (rows mode has no coverage information).
    ///   - trusted: `LaneReport.isTrusted` (a sweep frame neither counts nor resets).
    ///   - headCovered: `grid.headCoverage.contains(true)`.
    ///   - now: seconds (the report's timestamp).
    /// - Returns: true exactly once per route, on the frame that completes the hold.
    public mutating func update(metric: Bool, trusted: Bool, headCovered: Bool, now: TimeInterval) -> Bool {
        guard !spoken else { return false }
        guard metric, trusted else { return false }
        guard !headCovered else { uncoveredSince = nil; return false }
        let since = uncoveredSince ?? now
        uncoveredSince = since
        guard now - since >= holdSeconds else { return false }
        spoken = true
        return true
    }
}

/// Tile colouring for the debug grid: green ≥ 2.0 m, yellow ≥ 1.2 m, red < 0.7 m (orange between),
/// or dark neutral for no coverage / no data.
public enum TileLevel: Sendable {
    // `clear` ≥ 2.0 m or nothing, `far` 1.2–2.0 m, `near` 0.7–1.2 m, `urgent` < 0.7 m,
    // `noData` before the first depth frame, `noCover` when the camera cannot see the band at
    // the head-cue distance (Step 51). Display only: cue thresholds live in `CueThresholds`.
    case clear, far, near, urgent, noData, noCover

    /// - Parameters:
    ///   - distance: cell depth, metres (`.infinity` = clear).
    ///   - hasData: false before the first depth frame / on non-LiDAR devices.
    ///   - covered: `LaneGrid.headCoverage` / `torsoCoverage` for the cell (default true): false
    ///     when the camera cannot see this band at the head-cue distance (Step 51).
    /// - Returns: `.noData` without data; else `.noCover` when uncovered (the tile says NO COVER,
    ///   never CLEAR — a band the camera cannot see is not known to be empty); `.clear` for
    ///   non-finite or ≥ 2.0 m; `.far` ≥ 1.2 m; `.near` ≥ 0.7 m; else `.urgent`. Pinned by
    ///   `tileLevels`, `tileNoCoverIsNotClear`.
    public static func level(for distance: Float, hasData: Bool, covered: Bool = true) -> TileLevel {
        guard hasData else { return .noData }
        guard covered else { return .noCover }
        guard distance.isFinite else { return .clear }
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
    /// Cap in Hz. `DepthFrameProcessor` rewrites it on every frame from `ProcessorSettings.maxRate`
    /// (30, or 60 with the high-frame-rate camera), so its initial 15 is never what runs.
    public var maxRate: Double
    /// Timestamp of the last published frame; −∞ so the first frame always publishes.
    private var last: TimeInterval = -.infinity
    /// A gate that has published nothing yet.
    public init(maxRate: Double) { self.maxRate = maxRate }

    /// True when a frame at `now` (seconds, ARKit frame clock) should be published; records it if so.
    /// Rule: `now − last ≥ 1/maxRate − 0.004`.
    public mutating func shouldPublish(at now: TimeInterval) -> Bool {
        guard now - last >= 1.0 / maxRate - 0.004 else { return false }
        last = now
        return true
    }
}
