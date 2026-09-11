//
//  NavSupport.swift
//  CaneKitLogic
//
//  Small pure state machines the app's engines lean on. Each one used to live inline in an
//  app-target class where nothing could test it; the Step 10 review found real walk bugs in all
//  of them, so they now live here with tests (NavSupportTests.swift).
//
//    TurnSettle            when a reached waypoint's new leg may drive the beacon / veer cues
//    StraightWalkDetector  when the user is demonstrably walking straight (AirPods auto-recenter)
//    CueSpeechPolicy       which obstacle cues are also spoken, and how often
//    CrownAccumulator      watch Digital Crown → "next waypoint" gesture
//
//  Purpose: keep every numeric walking rule (metres, seconds, degrees, m/s) out of the
//  MainActor app classes so it can be pinned by `swift test`. Owners: `NavigationEngine.settle`
//  (TurnSettle), `AppModel.straightWalk` / `AppModel.cueSpeech`, `WatchModel.crown`.
//
//  Key invariants:
//    · All four are `Sendable` value types with `mutating` updates and no clock of their own:
//      the owner passes `now` / fix timestamps (seconds) and must write the mutated copy back.
//    · Units: distances metres, speeds m/s, angles degrees (bearings true), times seconds.
//    · TurnSettle: stationary or poor fixes never ratchet the closest approach or release by
//      distance; once `releaseAt` is set it never moves. At a crossing the beacon is silent
//      while settling ("Listen for traffic").
//    · CueSpeechPolicy: a *new* head-height episode is always eligible to speak (subject only
//      to the 4 s limiter); "Head height." is never repeated every second.
//    · CrownAccumulator: the window is anchored at the first detent, never slid.
//

import Foundation

// MARK: - TurnSettle

/// A waypoint fence is entered up to `radius_m` before the actual corner, so the new leg must not
/// drive veer cues or the beacon until the user has really turned. The settle window holds the
/// previous leg's bearing (or silences the beacon at a crossing, where the user must listen for
/// traffic) and releases when any of these is true:
///   · the user is within `nearM` of the corner (good, moving fix), then `graceSeconds` later;
///   · the fix has receded `recedeM` past the closest approach on **two consecutive** good moving
///     fixes (they went round the corner), then `graceSeconds` later;
///   · the gyro-gated body heading is within `headingMatchDeg` of the new leg (they turned);
///   · at a crossing: two consecutive stationary fixes (they reached the curb) — release at once;
///   · `maxMovingSeconds` of *moving* time have passed (GPS never got close under trees).
/// Stationary or poor fixes never ratchet the closest approach and never release by distance:
/// a fix wandering at a curb is not a turn.
///
/// Pinned by the nine settle tests in NavSupportTests.swift plus
/// `aPauseShortOfTheCurbDoesNotReleaseACrossing`.
public struct TurnSettle: Sendable, Equatable {

    /// Release tunables. Defaults are the walk-tested values; `NavigationEngine` uses them as-is.
    public struct Config: Sendable, Equatable {
        /// Metres: a good moving fix this close to the corner releases after `graceSeconds`.
        public var nearM: Double = 6
        /// Metres: floor for `recedeM` (= max(minRecedeM, radius / 2)).
        public var minRecedeM: Double = 6
        /// Seconds between a near / recede trigger and the actual release.
        public var graceSeconds: TimeInterval = 4
        /// Seconds of *moving* time (between good moving fixes) after which the leg goes live anyway.
        public var maxMovingSeconds: TimeInterval = 25
        /// Degrees: body heading within this of `nextBearing` releases immediately.
        public var headingMatchDeg: Double = 30
        /// m/s: "moving" means `speed > minSpeed`; "stationary" (curb) means `speed < minSpeed`.
        public var minSpeed: Double = 0.5
        /// Metres: "good" fix means `0 ≤ accuracy ≤ maxAccuracy`.
        public var maxAccuracy: Double = 20
        /// Extra metres beyond `nearM` that still count as "at the curb" for a crossing.
        public var curbSlackM: Double = 4
        /// Creates the default configuration (6 m / 6 m / 4 s / 25 s / 30° / 0.5 m/s / 20 m / 4 m).
        public init() {}
    }

    /// The reached waypoint (the corner) that distances are measured from.
    public let anchor: Coordinate
    /// Bearing the beacon keeps while settling (nil = nothing to hold → live bearing).
    public let heldBearing: Double?
    /// Bearing of the new leg (heading-based release). nil = no heading release.
    public let nextBearing: Double?
    /// True when the reached waypoint is a street crossing: the beacon is silent while settling
    /// and two stationary fixes at the curb release it.
    public let isCrossing: Bool
    /// The tunables this instance was created with.
    public let config: Config
    /// Metres of recede needed: max(minRecedeM, radius / 2).
    public let recedeM: Double

    /// Closest good moving approach to `anchor` so far, metres (starts at `startDistance`).
    public private(set) var minDistance: Double
    /// When the new leg goes live (seconds); nil until a release rule fires. Never moves once set.
    public private(set) var releaseAt: TimeInterval?
    /// Accumulated seconds between consecutive good moving fixes (each gap clamped to 0…5 s).
    public private(set) var movingSeconds: TimeInterval = 0
    /// Consecutive good moving fixes at ≥ `minDistance + recedeM`.
    private var recedeHits = 0
    /// Consecutive stationary good fixes within `nearM + curbSlackM` of a crossing.
    private var stoppedHits = 0
    /// Timestamp of the previous fix, for `movingSeconds`.
    private var lastTime: TimeInterval?

    /// - Parameters:
    ///   - anchor: the reached waypoint's coordinate.
    ///   - radiusM: that waypoint's fence radius, metres (sets `recedeM`).
    ///   - heldBearing: previous leg's bearing, degrees true, held while settling (nil → live).
    ///   - nextBearing: new leg's bearing, degrees true (nil disables the heading release).
    ///   - isCrossing: the waypoint is a street crossing (silent beacon, curb release).
    ///   - startDistance: metres from the last fix to the anchor when the fence fired (∞ if none).
    ///   - releasedAt: non-nil for a manual or passed-by advance — the user is already past the
    ///     corner, so the new leg is live immediately.
    ///   - config: release tunables.
    public init(anchor: Coordinate, radiusM: Double, heldBearing: Double?, nextBearing: Double?,
                isCrossing: Bool, startDistance: Double, releasedAt: TimeInterval? = nil,
                config: Config = Config()) {
        self.anchor = anchor
        self.heldBearing = heldBearing
        self.nextBearing = nextBearing
        self.isCrossing = isCrossing
        self.config = config
        self.recedeM = max(config.minRecedeM, radiusM / 2)
        self.minDistance = startDistance
        self.releaseAt = releasedAt
    }

    /// True once the new leg drives the beacon and veer cues.
    /// - Parameter now: seconds, same clock as the fixes.
    /// Pinned by `settleHoldsThePreviousLegUntilNearTheCornerPlusGrace`, `settleCapCountsMovingTimeOnly`.
    public func isLive(at now: TimeInterval) -> Bool {
        if let r = releaseAt, now >= r { return true }
        return movingSeconds >= config.maxMovingSeconds
    }

    /// The bearing to expose while settling. nil = silence the beacon.
    /// - Parameters:
    ///   - live: the tracker's current target bearing, degrees true (nil = none).
    ///   - now: seconds.
    /// - Returns: `live` once live; nil at a crossing while settling; else `heldBearing ?? live`.
    /// Pinned by `crossingSilencesTheBeaconAndReleasesAtTheCurb`, `noHeldBearingFallsBackToLive`.
    public func bearing(live: Double?, at now: TimeInterval) -> Double? {
        if isLive(at: now) { return live }
        if isCrossing { return nil }                 // "Listen for traffic": no clicks over it
        return heldBearing ?? live
    }

    /// Feed every GPS fix. Returns `isLive` after the update.
    /// Pinned by `settleDoesNotReleaseOnOneJitteryFix`, `settleReleasesAfterTwoConsecutiveRecedingFixes`,
    /// `stationaryOrPoorFixesNeverReleaseByDistance`, `aPauseShortOfTheCurbDoesNotReleaseACrossing`.
    @discardableResult
    public mutating func update(_ fix: GeoFix) -> Bool {
        let now = fix.timestamp
        let dt = lastTime.map { max(0, min(5, now - $0)) } ?? 0
        lastTime = now
        let good = fix.accuracy >= 0 && fix.accuracy <= config.maxAccuracy
        let moving = fix.speed > config.minSpeed
        if good && moving { movingSeconds += dt }

        if isCrossing, releaseAt == nil {
            // "At the curb" = standing (speed -1 counts) *close to the corner*: a pause 10 m short
            // of the street (shoe, obstacle) must not end the silence before the crossing.
            let d = GeoMath.distanceMeters(fix.coordinate, anchor)
            let atCurb = fix.speed < config.minSpeed && good && d <= config.nearM + config.curbSlackM
            stoppedHits = atCurb ? stoppedHits + 1 : 0
            if stoppedHits >= 2 { releaseAt = now }
        }
        guard good, moving, releaseAt == nil else { return isLive(at: now) }

        let d = GeoMath.distanceMeters(fix.coordinate, anchor)
        if d <= config.nearM {
            releaseAt = now + config.graceSeconds
        } else {
            minDistance = min(minDistance, d)
            recedeHits = d >= minDistance + recedeM ? recedeHits + 1 : 0
            if recedeHits >= 2 { releaseAt = now + config.graceSeconds }
        }
        return isLive(at: now)
    }

    /// Feed the gyro-gated body heading (the phone is on the cane, so a head turn never counts).
    /// - Parameters:
    ///   - heading: body heading, degrees true.
    ///   - now: seconds.
    /// Pinned by `turningTheBodyReleasesImmediately`.
    public mutating func update(heading: Double, now: TimeInterval) {
        guard releaseAt == nil, let next = nextBearing else { return }
        if abs(GeoMath.wrap180(heading - next)) < config.headingMatchDeg { releaseAt = now }
    }
}

// MARK: - StraightWalkDetector

/// "Walking straight" = `requiredFixes` consecutive fixes (the first one counts) at walking speed
/// with a good accuracy, a steady course and a still head. Any miss restarts the count.
///
/// Used by `AppModel` to auto-recenter the AirPods head reference (never on a timer, never near
/// a crossing — those gates live in the app). Pinned by
/// `straightWalkNeedsThreeSteadyFixesCountingTheFirst`, `straightWalkRestartsOnATurnAStopOrAHeadTurn`.
public struct StraightWalkDetector: Sendable, Equatable {
    /// Cane users walk ~0.6–1.0 m/s; 0.9 excluded slow walkers from auto-recenter entirely.
    public var minSpeed: Double = 0.6
    /// Metres: fixes worse than this (or invalid, < 0) restart the count.
    public var maxAccuracy: Double = 20
    /// Degrees: course change between consecutive fixes that still counts as "steady".
    public var maxCourseDelta: Double = 15
    /// Degrees: head-yaw change between consecutive fixes that still counts as "still"
    /// (plain difference, not wrapped).
    public var maxYawDelta: Double = 8
    /// Consecutive qualifying fixes (including the first) needed to report a straight stretch.
    public var requiredFixes: Int = 3

    /// Qualifying fixes in the current run.
    public private(set) var count = 0
    /// Course of the previous qualifying fix, degrees true.
    private var lastHeading: Double?
    /// Head yaw of the previous qualifying fix, degrees.
    private var lastYaw: Double?

    /// Creates a detector with the default 0.6 m/s / 20 m / 15° / 8° / 3-fix tuning.
    public init() {}

    /// Start over (route start, waypoint advance, settling, AirPods disconnected).
    public mutating func reset() {
        count = 0
        lastHeading = nil
        lastYaw = nil
    }

    /// - Parameters:
    ///   - speed: ground speed, m/s (negative = invalid → restart).
    ///   - accuracy: horizontal accuracy, metres (negative = invalid → restart).
    ///   - heading: course / body heading, degrees true; nil restarts.
    ///   - headYaw: AirPods head yaw, degrees (0 when unknown).
    /// - Returns: true on the fix that completes a straight stretch (then starts over).
    public mutating func update(speed: Double, accuracy: Double, heading: Double?, headYaw: Double) -> Bool {
        guard speed > minSpeed, accuracy >= 0, accuracy <= maxAccuracy, let heading else {
            reset()
            return false
        }
        let steady = lastHeading.map { abs(GeoMath.wrap180(heading - $0)) < maxCourseDelta } ?? true
        let still = lastYaw.map { abs(headYaw - $0) < maxYawDelta } ?? true
        lastHeading = heading
        lastYaw = headYaw
        count = (steady && still) ? count + 1 : 1
        guard count >= requiredFixes else { return false }
        reset()
        return true
    }
}

// MARK: - CueSpeechPolicy

/// Which obstacle cues are also spoken. Head height is spoken once per *episode* (the haptic keeps
/// re-firing at 1 Hz; re-speaking every few seconds would cut a crossing instruction to pieces),
/// with at most one "Head height." per `headInterval` across episodes. Left / right / ahead are
/// spoken only when the phone cannot buzz (engine down or silenced), per kind at most every
/// `sideInterval`.
///
/// Pinned by `headHeightIsSpokenOncePerEpisode`, `headEpisodesAreRateLimitedAcrossEpisodes`,
/// `sideCuesAreSpokenOnlyWhenThePhoneCannotBuzz`, `aBuzzedSideCueDoesNotSplitAHeadEpisode`.
public struct CueSpeechPolicy: Sendable, Equatable {
    /// Speech priority class of a returned line: `safety` ("Head height.") maps to the speech
    /// queue's highest priority, `obstacle` to the obstacle-name tier.
    public enum Tier: Sendable, Equatable { case safety, obstacle }

    /// Seconds: minimum gap between two spoken "Head height." lines, across episodes.
    public var headInterval: TimeInterval = 4
    /// Seconds: minimum gap between two spoken lines of the same side / ahead kind.
    public var sideInterval: TimeInterval = 4

    /// Last time (seconds) each cue kind was actually spoken.
    private var lastSpoken: [CueKind: TimeInterval] = [:]
    /// Kind of the current episode; `.clear` after `cleared()`.
    private var episodeKind: CueKind = .clear

    /// Creates a policy with the default 4 s / 4 s limiters.
    public init() {}

    /// The decider reported `.stop` (nothing in range): the next head cue is a new episode.
    public mutating func cleared() { episodeKind = .clear }

    /// Decide whether a fired haptic cue should also be spoken.
    /// - Parameters:
    ///   - cue: the cue `CueDecider` just fired.
    ///   - phoneCannotBuzz: true when the haptic engine is unhealthy or silenced.
    ///   - now: seconds (the depth report's timestamp in the app).
    /// - Returns: the line and its tier, or nil to stay silent.
    public mutating func line(for cue: HapticCue, phoneCannotBuzz: Bool, now: TimeInterval) -> (text: String, tier: Tier)? {
        let newEpisode = episodeKind != cue.kind
        // Only a head cue, or a side cue that is actually spoken, moves the episode: a silent
        // (buzzed) side cue between two head re-fires must not make the second one "new".
        if case .head = cue { episodeKind = .head }
        let candidate: (String, Tier, TimeInterval)?
        switch cue {
        case .head:
            candidate = newEpisode ? ("Head height.", .safety, headInterval) : nil
        case .left:
            candidate = phoneCannotBuzz ? ("Left.", .obstacle, sideInterval) : nil
        case .right:
            candidate = phoneCannotBuzz ? ("Right.", .obstacle, sideInterval) : nil
        case .centerApproach(let d):
            candidate = phoneCannotBuzz ? ("Ahead, \(SpokenDistance.phrase(d)).", .obstacle, sideInterval) : nil
        }
        guard let (text, tier, interval) = candidate else { return nil }
        episodeKind = cue.kind
        if let last = lastSpoken[cue.kind], now - last < interval { return nil }
        lastSpoken[cue.kind] = now
        return (text, tier)
    }
}

// MARK: - CrownAccumulator

/// Digital Crown "next waypoint": `detents` of travel (either direction) within `window` seconds
/// of the first movement, then `debounce` seconds before another. The window is anchored at the
/// first detent, so a cuff brushing the crown once per arm swing never adds up.
///
/// Pinned by `crownFiresOnThreeDetentsWithinASecond`, `crownIgnoresARhythmicSleeve`,
/// `crownDebouncesBackToBackGestures`.
public struct CrownAccumulator: Sendable, Equatable {
    /// Crown travel (detents, absolute, either direction) that completes the gesture.
    public var detents: Double = 3
    /// Seconds from the first detent within which `detents` must accumulate.
    public var window: TimeInterval = 1
    /// Seconds after a fire during which a completed gesture is consumed without firing.
    public var debounce: TimeInterval = 0.8

    /// Time (seconds) of the first detent of the open window; nil when no window is open.
    private var windowStart: TimeInterval?
    /// Absolute detents accumulated in the open window.
    private var travel: Double = 0
    /// Time (seconds) of the last fire; −∞ so the first gesture is never debounced.
    private var lastFire: TimeInterval = -.infinity

    /// Creates an accumulator with the default 3 detents / 1 s / 0.8 s tuning.
    public init() {}

    /// - Parameters:
    ///   - delta: crown rotation since the last call, in detents (sign ignored).
    ///   - now: seconds (the watch passes `Date().timeIntervalSinceReferenceDate`).
    /// - Returns: true when this movement completes the gesture.
    public mutating func move(delta: Double, now: TimeInterval) -> Bool {
        if let start = windowStart, now - start > window {
            windowStart = nil
            travel = 0
        }
        if windowStart == nil { windowStart = now }
        travel += abs(delta)
        guard travel >= detents else { return false }
        windowStart = nil
        travel = 0
        guard now - lastFire >= debounce else { return false }
        lastFire = now
        return true
    }
}
