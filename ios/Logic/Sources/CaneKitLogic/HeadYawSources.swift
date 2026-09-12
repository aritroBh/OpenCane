//
//  HeadYawSources.swift
//  CaneKitLogic
//
//  Where the beacon's listener orientation comes from when the walker has no AirPods.
//
//  Purpose: the spatial beacon renders from `phone heading + head yaw`, and until now head yaw had
//  exactly one source — `CMHeadphoneMotionManager` on AirPods Pro. The owner wants the AirPods and
//  the Apple Watch to be *optional*, so the front (TrueDepth) camera becomes a second source:
//  `ARWorldTrackingConfiguration.userFaceTrackingEnabled` delivers an `ARFaceAnchor` alongside the
//  back camera's LiDAR depth, and the anchor's orientation is the walker's head direction. That
//  conversion, its smoothing and the choice between the two sources all have numbers in them, so
//  they live here with tests (AGENTS.md hard rule 3). Owners: `FaceHeadPose` (the app-side class
//  that feeds `ingest`), `AppModel.startTicker` (the selector), `AppModel.recenter`.
//
//  Geometry, stated once: the app runs `worldAlignment = .gravity`, so ARKit's world frame has
//  +Y up and a yaw origin fixed when the session started. `ARFaceAnchor.transform`'s third column
//  is the face's +Z axis, which points out of the face — i.e. the direction the walker is looking.
//  Projected onto the horizontal plane its yaw is `atan2(x, −z)`, measured clockwise from the
//  world's −Z, which makes **positive = turned to the walker's right**. That is the same sign
//  convention as `HeadPoseTracker.headYawDeg`, so the beacon needs no second code path.
//
//  Key invariants:
//    · Both sources are *relative*: the absolute yaw of a session's world frame (and of the
//      AirPods' frame) is arbitrary, so only the difference from a reference captured at
//      "Recenter" is ever used. `yawDeg` returns nil until a reference exists.
//    · A stale face is no face: with no anchor for `maxAge` the tracker reports nil, and the
//      selector falls back to 0 rather than steering the beacon with an old head pose.
//    · AirPods beat the camera whenever they have data: they sit on the head, they work in the
//      dark, and they do not depend on the walker's face being inside the front camera's cone.
//  Tests: HeadYawSourcesTests.swift.
//

import Foundation

// MARK: - Face anchor → yaw

/// Converts an `ARFaceAnchor`'s forward axis into a yaw in ARKit's gravity-aligned world frame.
/// Kept separate from the tracker so the trigonometry can be pinned on its own.
public enum FaceYawGeometry {

    /// Horizontal components under which the forward axis carries no usable yaw: a head tipped
    /// far enough back that +Z points almost straight up leaves `atan2` reading noise. 0.15 is
    /// ~8.6° of tilt away from vertical — well outside anything a walking head does.
    public static let minimumHorizontalMagnitude: Double = 0.15

    /// Yaw of the head's forward direction in the world frame, degrees, positive = to the
    /// walker's right of the world's −Z axis.
    /// - Parameters:
    ///   - forwardX: x component of `ARFaceAnchor.transform.columns.2` (the face's +Z axis).
    ///   - forwardZ: z component of the same column.
    /// - Returns: the yaw in (−180, 180], or nil when the axis is too close to vertical to have
    ///   a meaningful yaw (the caller then keeps the previous value and lets it go stale).
    public static func worldYawDegrees(forwardX: Double, forwardZ: Double) -> Double? {
        let magnitude = (forwardX * forwardX + forwardZ * forwardZ).squareRoot()
        guard magnitude >= minimumHorizontalMagnitude else { return nil }
        // atan2(x, −z): 0° along the world's −Z ("forward" at session start), +90° along +X.
        return atan2(forwardX, -forwardZ) * 180 / .pi
    }
}

// MARK: - Face yaw tracker

/// Turns a stream of raw world yaws from the front camera into a smoothed head yaw relative to a
/// recentred forward direction — the same quantity `HeadPoseTracker` produces from AirPods motion.
///
/// A value type with no clock of its own: the owner (`FaceHeadPose`) passes `now` in seconds and
/// writes the mutated copy back, exactly like `StraightWalkDetector`.
///
/// Why smoothing at all: the anchor updates at the camera's rate and the walker's head is on a
/// body that the cane sweep shakes, so the raw yaw jitters by a few degrees. The beacon turns that
/// jitter into a wobbling click. An exponential average with `smoothing` on the new sample settles
/// in ~5 frames (≈ 0.17 s at 30 fps) — fast enough that a real head turn is not laggy, slow enough
/// that the click holds still.
public struct FaceYawTracker: Sendable, Equatable {

    /// Weight of each new sample in the exponential average (0…1). 0.35 settles to within 10 % of
    /// a step in 6 frames (0.2 s at 30 fps): the beacon must follow a head turn, not lead it.
    public var smoothing: Double = 0.35
    /// Seconds without an anchor after which the yaw is reported as nil. 0.7 s spans ~21 dropped
    /// frames at 30 fps — long enough to ride out the walker glancing away, short enough that a
    /// head pose from a second ago never steers the beacon.
    public var maxAge: Double = 0.7
    /// Degrees: a single sample further than this from the smoothed value is treated as an
    /// anchor glitch and dropped. A real head turn exceeds 45° between two frames only at
    /// ~1350 °/s, which a neck cannot do; a re-acquired face often does.
    public var maxJump: Double = 45
    /// How many consecutive rejected samples are allowed before the tracker gives in and accepts
    /// the new value. Without this, a genuine fast turn that lands outside `maxJump` would keep
    /// the walker pinned to a stale direction forever.
    public var maxConsecutiveRejections: Int = 3

    /// Smoothed raw yaw in the world frame, degrees; nil before the first accepted sample.
    /// Exposed for the Hazards card's honest front-camera readout and the trip log.
    public private(set) var smoothedWorldYaw: Double?
    /// The world yaw that counts as "straight ahead"; nil until `recenter()` is called with data.
    public private(set) var referenceYaw: Double?
    /// `now` of the last accepted sample; drives `isFresh`.
    public private(set) var lastSampleTime: Double?
    /// Consecutive samples rejected by `maxJump` (reset on every accepted sample).
    private var rejections = 0

    /// Seconds between face-yaw hops from the AR session's delegate queue to the main actor.
    /// The anchor updates at the camera's rate (30 or 60 Hz) but the beacon is rendered by a
    /// 10 Hz ticker, so the relay intentionally caps hops at 15 Hz. ⚠ `DepthEngine`'s anchor
    /// relay throttles to this; pinned by
    /// `faceYawPublishIntervalMatchesTheDepthRate`.
    public static let publishInterval: Double = 1.0 / 15

    /// Creates a tracker with the default 0.35 / 0.7 s / 45° / 3 tuning.
    public init() {}

    /// Feed one anchor's world yaw.
    /// - Parameters:
    ///   - worldYawDeg: `FaceYawGeometry.worldYawDegrees`, degrees in the world frame.
    ///   - now: monotonic seconds (the app uses the ARKit frame clock, like the cue router).
    public mutating func ingest(worldYawDeg: Double, now: Double) {
        guard let smoothed = smoothedWorldYaw else {
            smoothedWorldYaw = worldYawDeg
            lastSampleTime = now
            rejections = 0
            return
        }
        let delta = GeoMath.wrap180(worldYawDeg - smoothed)
        if abs(delta) > maxJump, rejections < maxConsecutiveRejections {
            rejections += 1
            return
        }
        rejections = 0
        smoothedWorldYaw = GeoMath.wrap180(smoothed + smoothing * delta)
        lastSampleTime = now
    }

    /// True while the last accepted sample is younger than `maxAge`.
    /// - Parameter now: the same clock `ingest` is given.
    public func isFresh(now: Double) -> Bool {
        guard let lastSampleTime else { return false }
        return now - lastSampleTime <= maxAge
    }

    /// Head yaw relative to the recentred forward direction, degrees in (−180, 180], positive =
    /// turned to the walker's right. nil when there is no fresh face or no reference yet — the
    /// caller must then not steer the beacon from this source.
    /// - Parameter now: the same clock `ingest` is given.
    public func yawDeg(now: Double) -> Double? {
        guard isFresh(now: now), let smoothedWorldYaw, let referenceYaw else { return nil }
        return GeoMath.wrap180(smoothedWorldYaw - referenceYaw)
    }

    /// The walker's current head direction becomes "straight ahead" (the Recenter button, the
    /// watch Recenter command, and the auto-recenter when walking straight).
    /// With no smoothed sample the reference is cleared, so the next accepted sample can seed it.
    public mutating func recenter() {
        referenceYaw = smoothedWorldYaw
    }

    /// Seed the reference from the next accepted sample: used when face tracking starts, so the
    /// walker's pose at route start is forward even before they press Recenter.
    /// - Parameter now: the same clock `ingest` is given; a fresh sample seeds immediately.
    public mutating func recenterWhenReady(now: Double) {
        if isFresh(now: now), smoothedWorldYaw != nil {
            referenceYaw = smoothedWorldYaw
        } else {
            referenceYaw = nil
        }
    }

    /// Forget everything (face tracking turned off, route stopped, ARKit paused) so the UI and the
    /// beacon can never show a head pose from a previous walk.
    public mutating func reset() {
        smoothedWorldYaw = nil
        referenceYaw = nil
        lastSampleTime = nil
        rejections = 0
    }
}

// MARK: - Choosing a source

/// Which sensor the head yaw handed to the beacon came from. Written into the trip log and shown
/// on the Hazards card, so a walk recording says *why* the beacon behaved as it did.
public enum HeadYawSource: String, Sendable, Equatable {
    /// No usable head yaw: the beacon pans from the phone's compass alone (yaw 0).
    case none
    /// `CMHeadphoneMotionManager` on AirPods Pro.
    case airPods
    /// `ARFaceAnchor` from the front camera, running alongside LiDAR depth.
    case face
}

/// The head yaw to use and where it came from.
public struct HeadYawChoice: Sendable, Equatable {
    /// Degrees, positive = head turned to the walker's right of the recentred forward direction.
    /// Always finite; 0 when `source == .none`.
    public let degrees: Double
    /// Which sensor produced `degrees`.
    public let source: HeadYawSource

    public init(degrees: Double, source: HeadYawSource) {
        self.degrees = degrees
        self.source = source
    }
}

/// Picks between the AirPods and the front camera for every beacon render.
public enum HeadYawSelector {

    /// AirPods first, front camera second, zero last.
    ///
    /// AirPods win whenever they have a value: they are physically on the head, they work in the
    /// dark and in a crowd, and they do not need the walker's face inside the front camera's cone.
    /// The face is the fallback that makes the AirPods optional — and `nil` from both means the
    /// beacon renders from the compass alone, which is the behaviour that shipped before either
    /// source existed.
    /// - Parameters:
    ///   - airPodsYaw: `HeadPoseTracker.headYawDeg`, or nil when no AirPods motion is flowing.
    ///   - faceYaw: `FaceYawTracker.yawDeg(now:)`, or nil when there is no fresh face / reference.
    ///   - recenterPending: true between a waypoint advance and the next recenter. Both sources'
    ///     references then belong to the *previous* leg, and adding their yaw to the phone heading
    ///     would double-count the body turn (AGENTS.md: "the beacon ignores head yaw until the
    ///     first recenter after a turn"), so the yaw is forced to 0 while keeping the source name
    ///     for the log.
    public static func choose(airPodsYaw: Double?, faceYaw: Double?,
                              recenterPending: Bool) -> HeadYawChoice {
        let (value, source): (Double, HeadYawSource)
        if let airPodsYaw {
            (value, source) = (airPodsYaw, .airPods)
        } else if let faceYaw {
            (value, source) = (faceYaw, .face)
        } else {
            (value, source) = (0, .none)
        }
        guard value.isFinite else { return HeadYawChoice(degrees: 0, source: source) }
        return HeadYawChoice(degrees: recenterPending ? 0 : value, source: source)
    }
}
