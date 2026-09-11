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
public struct TurnSettle: Sendable, Equatable {

    public struct Config: Sendable, Equatable {
        public var nearM: Double = 6
        public var minRecedeM: Double = 6
        public var graceSeconds: TimeInterval = 4
        public var maxMovingSeconds: TimeInterval = 25
        public var headingMatchDeg: Double = 30
        public var minSpeed: Double = 0.5
        public var maxAccuracy: Double = 20
        /// Extra metres beyond `nearM` that still count as "at the curb" for a crossing.
        public var curbSlackM: Double = 4
        public init() {}
    }

    public let anchor: Coordinate
    /// Bearing the beacon keeps while settling (nil = nothing to hold → live bearing).
    public let heldBearing: Double?
    /// Bearing of the new leg (heading-based release). nil = no heading release.
    public let nextBearing: Double?
    public let isCrossing: Bool
    public let config: Config
    /// Metres of recede needed: max(minRecedeM, radius / 2).
    public let recedeM: Double

    public private(set) var minDistance: Double
    public private(set) var releaseAt: TimeInterval?
    public private(set) var movingSeconds: TimeInterval = 0
    private var recedeHits = 0
    private var stoppedHits = 0
    private var lastTime: TimeInterval?

    /// - Parameters:
    ///   - releasedAt: non-nil for a manual or passed-by advance — the user is already past the
    ///     corner, so the new leg is live immediately.
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
    public func isLive(at now: TimeInterval) -> Bool {
        if let r = releaseAt, now >= r { return true }
        return movingSeconds >= config.maxMovingSeconds
    }

    /// The bearing to expose while settling. nil = silence the beacon.
    public func bearing(live: Double?, at now: TimeInterval) -> Double? {
        if isLive(at: now) { return live }
        if isCrossing { return nil }                 // "Listen for traffic": no clicks over it
        return heldBearing ?? live
    }

    /// Feed every GPS fix. Returns `isLive` after the update.
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
    public mutating func update(heading: Double, now: TimeInterval) {
        guard releaseAt == nil, let next = nextBearing else { return }
        if abs(GeoMath.wrap180(heading - next)) < config.headingMatchDeg { releaseAt = now }
    }
}

// MARK: - StraightWalkDetector

/// "Walking straight" = `requiredFixes` consecutive fixes (the first one counts) at walking speed
/// with a good accuracy, a steady course and a still head. Any miss restarts the count.
public struct StraightWalkDetector: Sendable, Equatable {
    /// Cane users walk ~0.6–1.0 m/s; 0.9 excluded slow walkers from auto-recenter entirely.
    public var minSpeed: Double = 0.6
    public var maxAccuracy: Double = 20
    public var maxCourseDelta: Double = 15
    public var maxYawDelta: Double = 8
    public var requiredFixes: Int = 3

    public private(set) var count = 0
    private var lastHeading: Double?
    private var lastYaw: Double?

    public init() {}

    public mutating func reset() {
        count = 0
        lastHeading = nil
        lastYaw = nil
    }

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
public struct CueSpeechPolicy: Sendable, Equatable {
    public enum Tier: Sendable, Equatable { case safety, obstacle }

    public var headInterval: TimeInterval = 4
    public var sideInterval: TimeInterval = 4

    private var lastSpoken: [CueKind: TimeInterval] = [:]
    private var episodeKind: CueKind = .clear

    public init() {}

    /// The decider reported `.stop` (nothing in range): the next head cue is a new episode.
    public mutating func cleared() { episodeKind = .clear }

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
public struct CrownAccumulator: Sendable, Equatable {
    public var detents: Double = 3
    public var window: TimeInterval = 1
    public var debounce: TimeInterval = 0.8

    private var windowStart: TimeInterval?
    private var travel: Double = 0
    private var lastFire: TimeInterval = -.infinity

    public init() {}

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
