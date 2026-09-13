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
//  (TurnSettle; built in `reached`, fed by `update(fix:)` / `update(heading:now:)`, cleared in
//  `refreshSettling` once live), `AppModel.straightWalk` (`autoRecenterIfWalkingStraight`) /
//  `AppModel.cueSpeech` (`speakCueIfNeeded`; a fresh value per route), and
//  `WatchModel.crown` (`crownMoved(delta:now:)`).
//  Isolation: the package has no default actor isolation, so these are nonisolated values; each
//  app owner holds its copy in a main-actor `var` (`if var s = settle { s.update(fix); settle = s }`).
//
//  Key invariants:
//    · All four are `Sendable` value types with `mutating` updates and no clock of their own:
//      the owner passes `now` / fix timestamps (seconds) and must write the mutated copy back.
//    · Units: distances metres, speeds m/s, angles degrees (bearings true), times seconds.
//    · TurnSettle: stationary or poor fixes never ratchet the closest approach or release by
//      distance; once `releaseAt` is set it never moves. At a crossing the beacon is silent
//      while settling ("Listen for traffic").
//    · CueSpeechPolicy: a head *onset* is always eligible to speak (subject only to the 4 s
//      limiter); within an episode "Head height." is spoken at most once more, under 0.6 m
//      (Step 52). The episode itself belongs to `CueDecider`.
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
    /// Metres of recede needed: max(minRecedeM, radius / 2). A 12 m turn fence needs 6 m, a 20 m
    /// fence 10 m — a bigger fence fires further before the corner, so "went round it" must be
    /// proven by a bigger margin.
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

    /// Opens a settle window at a just-reached waypoint (normal fence entry), or a window that is
    /// already released (`releasedAt`) for a manual Next or a passed-by advance.
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
    /// Order inside: the moving-time clock first (gap clamped to 0…5 s so a GPS outage cannot
    /// jump the 25 s cap), then the crossing curb check (a good fix below `minSpeed` — speed −1
    /// counts as standing — within `nearM + curbSlackM`), then the near / recede releases, which
    /// only good *moving* fixes may drive.
    /// - Parameter fix: the fix; `timestamp` is the clock for `releaseAt` and `movingSeconds`.
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
    /// Releases at once (no grace) when the heading is within `headingMatchDeg` of `nextBearing`;
    /// does nothing once released or when `nextBearing` is nil (`NavigationEngine` passes nil for
    /// a waypoint that is not a turn, so walking straight on never releases early).
    /// Caller: `NavigationEngine.update(heading:now:)`.
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
/// Used by `AppModel` to auto-recenter the head reference — AirPods and the front-camera face
/// tracker alike (never on a timer, never near
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

    /// Start over (route start, waypoint advance, settling, no head source, within 15 m of a
    /// crossing — `AppModel.autoRecenterIfWalkingStraight` and the route start / advance paths).
    public mutating func reset() {
        count = 0
        lastHeading = nil
        lastYaw = nil
    }

    /// Feed one GPS fix (with the head yaw at that moment). A fix that fails the speed, accuracy
    /// or heading gate restarts the count; a qualifying fix that is not steady or not still starts
    /// a new run at 1 (it is the first fix of the next run).
    /// Caller: `AppModel.autoRecenterIfWalkingStraight(_:)`, per fix while navigating.
    /// - Parameters:
    ///   - speed: ground speed, m/s (negative = invalid → restart).
    ///   - accuracy: horizontal accuracy, metres (negative = invalid → restart).
    ///   - heading: course / body heading, degrees true; nil restarts.
    ///   - headYaw: head yaw, degrees — `AppModel` passes `HeadYawSelector.choose` (HeadYawSources
    ///     .swift): the AirPods, else the front-camera face tracker, else 0.
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

/// Which obstacle cues are also spoken. "Head height." follows the decider's head episode
/// (Step 52): spoken on the **onset** fire (`HapticCue.head(distance:onset: true)`), subject to
/// one line per `headInterval` (4 s) across episodes; spoken **once more** in the same episode
/// only when a band re-fire brings the overhang under `headSecondLineBelowM` (0.6 m — about one
/// step). Every other head fire is haptic only. The decider decides where an episode starts and
/// ends (2 s of trusted clear), so this policy has no `cleared()` any more: a `.stop` inside an
/// episode (the zone flapping at its exit line) no longer makes the next fire "new" — that split
/// is what said "Head height." 8 times in 12 minutes on the first cane walk. Left / right / ahead
/// are spoken only when the phone cannot buzz (engine down or silenced), per kind at most every
/// `sideInterval`. The text is byte-identical to `AppModel.commonLines` (prefetched).
///
/// Pinned by `headHeightIsSpokenOncePerEpisode`, `headEpisodesAreRateLimitedAcrossEpisodes`,
/// `secondHeadLineNeedsUnderSixtyCentimetres`, `sideCuesAreSpokenOnlyWhenThePhoneCannotBuzz`,
/// `aBuzzedSideCueDoesNotSplitAHeadEpisode` (NavSupportTests) and `fixedCueLinesAreLeftToCommonLines`
/// (SpokenPhrasesTests).
///
/// Step 68 adds "Close." (`close(torsoCentreM:covered:held:trusted:now:)`): the owner asked for
/// half the words "but if something comes close, tell us — like when it turns into the red". It
/// follows the centre torso cell's red tile (`TileLevel.urgent`, < 0.7 m), once per red episode, at
/// `.safety` since the review round Steps 67–68 (`closeTier`; it was `.obstacle` and got dropped
/// behind the route intro), at every cue level (`closeAllowed`). Pinned by `closeIsASafetyLineAtEveryCueLevel`,
/// `closeIsSpokenOncePerRedEpisode`, `closeNeedsThreeSecondsOutOfTheRed`,
/// `closeIsRateLimitedToOneEveryFourSeconds`, `aPointBlankHoldNeverStartsClose`,
/// `sweepAndUncoveredFramesNeitherStartNorEndClose` (NavSupportTests).
public struct CueSpeechPolicy: Sendable, Equatable {
    /// Speech priority class of a returned line: `safety` ("Head height.") maps to the speech
    /// queue's highest priority, `obstacle` to the obstacle-name tier.
    public enum Tier: Sendable, Equatable { case safety, obstacle }

    /// Seconds: minimum gap between two spoken onset "Head height." lines, across episodes.
    public var headInterval: TimeInterval = 4
    /// Seconds: minimum gap between two spoken lines of the same side / ahead kind.
    public var sideInterval: TimeInterval = 4
    /// Metres: a band re-fire closer than this speaks "Head height." a second time (once per
    /// episode). Matches the decider's last re-fire band (`CueThresholds.headRefireBands`, 0.6 m).
    public var headSecondLineBelowM: Float = 0.6

    /// Last time (seconds) each cue kind was actually spoken.
    private var lastSpoken: [CueKind: TimeInterval] = [:]
    /// True once the current head episode has used its second line (reset by every onset).
    private var headSecondLineSpoken = false

    /// The close-obstacle line (Step 68). ⚠ In `RouteStatusLines.allSpokenLines` (prefetched).
    public static let closeText = "Close."
    /// The speech tier of `closeText`: `.safety` (review round Steps 67–68, Antigravity #3). At
    /// `.obstacle` it queued behind the 8–10 s route intro (`.nav`) and its 3 s TTL dropped it — an
    /// imminent-collision warning that never played. At `.safety` it cuts `.nav` / `.obstacle` /
    /// `.scene`; it never cuts "Head height." and "Head height." never cuts it (equal priority queues
    /// in order of arrival; "Close." is one word). Caller: `AppModel.handle`, mapped with the same
    /// rule as `speakCueIfNeeded`. Pinned by `closeIsASafetyLineAtEveryCueLevel`.
    public static let closeTier: Tier = .safety

    /// Whether "Close." may be spoken at all: while a route or an indoor step script guides, at
    /// EVERY cue level (review round Steps 67–68, Muse #2 — Quiet renders no torso haptic, so under
    /// Quiet "Close." is the only near-obstacle signal; it used to be gated off there).
    /// - Parameters:
    ///   - navigating: `NavigationEngine.isNavigating`.
    ///   - indoorActive: `IndoorGuide.isActive`.
    ///   - level: the cue level — deliberately not consulted (documents that Quiet is included).
    /// - Returns: true while guiding. Pinned by `closeIsASafetyLineAtEveryCueLevel`.
    public static func closeAllowed(navigating: Bool, indoorActive: Bool, level: CueLevel) -> Bool {
        navigating || indoorActive
    }
    /// Seconds the centre torso cell must stay out of the red before a new red episode may speak.
    public var closeClearSeconds: TimeInterval = 3
    /// Seconds: minimum gap between two "Close." lines.
    public var closeInterval: TimeInterval = 4
    /// True while in a red episode that has spoken.
    private var closeEpisode = false
    /// Start of the current out-of-the-red run inside an episode; nil otherwise.
    private var closeClearSince: TimeInterval?
    /// When "Close." was last spoken; nil before the first.
    private var lastCloseAt: TimeInterval?

    /// Creates a policy with the default 4 s / 4 s limiters and the 0.6 m second line.
    public init() {}

    /// Decide whether a fired haptic cue should also be spoken.
    /// - Parameters:
    ///   - cue: the cue `CueDecider` just fired (after `TorsoHapticPolicy`); for `.head` the
    ///     payload says onset or band re-fire and how far.
    ///   - phoneCannotBuzz: true when the haptic engine is unhealthy or silenced.
    ///   - now: seconds (the depth report's timestamp in the app).
    /// - Returns: the line and its tier, or nil to stay silent. `AppModel.speakCueIfNeeded` maps
    ///   `.safety` → `SpeechPriority.safety`, `.obstacle` → `.obstacle`, TTL 6 s.
    public mutating func line(for cue: HapticCue, phoneCannotBuzz: Bool, now: TimeInterval) -> (text: String, tier: Tier)? {
        let candidate: (String, Tier, TimeInterval)?
        switch cue {
        case .head(let d, let onset):
            if onset {
                headSecondLineSpoken = false
                candidate = ("Head height.", .safety, headInterval)
            } else if !headSecondLineSpoken, d.isFinite, d < headSecondLineBelowM {
                // The second line is bounded by the decider (one 0.6 m band per episode, ≥ 1.5 s
                // after the previous fire), not by the 4 s onset limiter: under 0.6 m the walker
                // is one step from the overhang and must hear it even if the onset line was 2 s ago.
                headSecondLineSpoken = true
                lastSpoken[.head] = now
                return ("Head height.", .safety)
            } else {
                candidate = nil
            }
        case .left:
            candidate = phoneCannotBuzz ? ("Left.", .obstacle, sideInterval) : nil
        case .right:
            candidate = phoneCannotBuzz ? ("Right.", .obstacle, sideInterval) : nil
        case .centerApproach(let d):
            // Built by `SpokenPhrases.approachLine`, which is also what the launch prefetch
            // enumerates, so this line is byte-identical to the mp3 already in the cache and
            // comes out in the natural voice instead of flipping to the system voice.
            candidate = phoneCannotBuzz ? (SpokenPhrases.approachLine(distance: d), .obstacle, sideInterval) : nil
        }
        guard let (text, tier, interval) = candidate else { return nil }
        if let last = lastSpoken[cue.kind], now - last < interval { return nil }
        lastSpoken[cue.kind] = now
        return (text, tier)
    }

    /// "Close." when the centre torso cell turns red (Step 68), fed every depth report while a
    /// route or an indoor script guides (`AppModel.handle`, not under Quiet cues).
    ///
    /// Red = `TileLevel.level(for:hasData:covered:) == .urgent` (< 0.7 m) — exactly the tile the
    /// walker sees go red. One line per red episode, and the episode ends only after
    /// `closeClearSeconds` (3 s) of trusted frames out of the red, so standing at a wall, or the
    /// reading flapping at 0.7 m, never repeats it; never two lines within `closeInterval` (4 s)
    /// — a red entry inside the limiter waits and speaks when it expires if still red.
    /// A `NearHold` substitution (`held`: point-blank after a near reading, or the 0.8 m cold start)
    /// may continue an episode but never start one: a phone switched on against a wall or put face
    /// down must not say "Close." (a real approach is measured red before the hold takes over).
    /// Sweep frames (`trusted` false) and a cell the camera cannot see (`covered` false) neither
    /// start nor end an episode.
    /// - Parameters:
    ///   - torsoCentreM: `LaneGrid.torso[1]`, metres (`.infinity` = clear).
    ///   - covered: `LaneGrid.torsoCoverage[1]`.
    ///   - held: `LaneGrid.torsoHeld[1]`.
    ///   - trusted: `LaneReport.isTrusted`.
    ///   - now: seconds (the report's AR timestamp).
    /// - Returns: `closeText`, or nil. The app speaks it at `closeTier` (`.safety`, review round Steps 67–68) with a 3 s TTL.
    public mutating func close(torsoCentreM: Float, covered: Bool, held: Bool, trusted: Bool,
                               now: TimeInterval) -> String? {
        guard trusted, covered, now.isFinite else { return nil }
        let red = TileLevel.level(for: torsoCentreM, hasData: true, covered: true) == .urgent
        if red {
            closeClearSince = nil
            guard !closeEpisode, !held else { return nil }
            if let last = lastCloseAt, now - last < closeInterval { return nil }
            closeEpisode = true
            lastCloseAt = now
            return Self.closeText
        }
        guard closeEpisode else { return nil }
        let since = closeClearSince ?? now
        closeClearSince = since
        if now - since >= closeClearSeconds {
            closeEpisode = false
            closeClearSince = nil
        }
        return nil
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

    /// Feed one Digital Crown callback. A gesture that completes inside the debounce is consumed
    /// (travel reset) rather than carried over, so a long spin fires once, not every 3 detents.
    /// Caller: `WatchModel.crownMoved(delta:now:)` → `send(.nextWaypoint)`.
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
