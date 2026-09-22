//
//  GeoMath.swift
//  CaneKitLogic
//
//  Great-circle distance / bearing, angle wrapping, off-course detection and waypoint geofences.
//  Foundation only; the app adapts CLLocation → GeoFix.
//
//  Purpose: everything the navigation engine needs to turn a stream of GPS fixes into "you
//  reached waypoint N", "veer left / right" and "the beacon should point at X°". The app's
//  `NavigationEngine` owns one `GeofenceTracker` and one `OffCourseDetector` per route and feeds
//  them from `LocationService`; these types never read a clock or a sensor themselves.
//
//  Key invariants:
//    · Units: distances and accuracies in metres, speeds in m/s, angles in degrees, bearings
//      clockwise from TRUE north in [0, 360), times in seconds (always caller-supplied).
//    · Signed bearing error = target − heading wrapped to (−180, 180]; positive = turn right.
//    · Negative `accuracy` or `speed` on a `GeoFix` means "invalid" (CoreLocation reports −1)
//      and never satisfies a gate.
//    · `OffCourseDetector` and `GeofenceTracker` are deliberately NOT Sendable: one actor
//      (MainActor in the app) owns and drives each instance.
//    · Arrival is irreversible (it stops the beacon and the Live Activity), so the last
//      waypoint needs `distance + accuracy ≤ radius` on `arrivalHits` consecutive fixes. The
//      whole reported uncertainty must fit inside the fence; a half-radius margin allowed
//      correlated GPS error to finish a walk tens of metres before the door (StressTests).
//    · An `OffCourseDetector` episode is evidence, not samples: moments with nothing to judge
//      are reported as `gated(at:)` and only a hole longer than `maxEvidenceGap` (2 s) drops the
//      episode — jitter must not silence a veer warning, a GPS gap must not fire one. A moment
//      muted because the *situation* changed (a corner, a curved leg) ends the episode instead.
//  Tests: GeoMathTests.swift (26 tests).
//

import Foundation

/// A WGS-84 latitude / longitude pair in degrees. The package's CoreLocation-free stand-in for
/// `CLLocationCoordinate2D`; also the JSON-free coordinate used by `Waypoint.coordinate`.
public struct Coordinate: Sendable, Equatable, Codable {
    /// Degrees north (negative = south).
    public var latitude: Double
    /// Degrees east (negative = west; UIUC is ≈ −88.22).
    public var longitude: Double
    /// Creates a coordinate from degrees latitude / longitude.
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// One GPS fix, already stripped of CoreLocation types.
public struct GeoFix: Sendable, Equatable {
    /// Where the fix says the user is.
    public var coordinate: Coordinate
    /// Horizontal accuracy in metres (negative = invalid).
    public var accuracy: Double
    /// Ground speed in m/s (negative = invalid).
    public var speed: Double
    /// Seconds; the app passes `CLLocation.timestamp.timeIntervalSinceReferenceDate`. Drives
    /// `TurnSettle`'s moving-time cap and the `now` the navigation engine hands the detectors.
    public var timestamp: TimeInterval
    /// - Parameters:
    ///   - coordinate: position of the fix.
    ///   - accuracy: horizontal accuracy, metres; negative = invalid.
    ///   - speed: ground speed, m/s; negative = invalid (CoreLocation's −1 when standing still).
    ///   - timestamp: seconds (reference-date clock in the app).
    public init(coordinate: Coordinate, accuracy: Double, speed: Double, timestamp: TimeInterval) {
        self.coordinate = coordinate
        self.accuracy = accuracy
        self.speed = speed
        self.timestamp = timestamp
    }
}

/// Spherical-earth geometry helpers. Accurate to well under a metre at campus scale, which is
/// far below GPS noise. Pinned by `isrToCifIsAboutSevenHundredMetres`, `cardinalBearings`,
/// `wrapping`.
public enum GeoMath {
    /// Mean earth radius in metres (IUGG), used by the haversine formula.
    static let earthRadius = 6_371_000.0

    /// Great-circle (haversine) distance between two coordinates.
    /// - Parameters:
    ///   - a: first point.
    ///   - b: second point.
    /// - Returns: distance in metres (≥ 0). `min(1, √h)` guards `asin` against rounding > 1.
    /// Pinned by `isrToCifIsAboutSevenHundredMetres`.
    public static func distanceMeters(_ a: Coordinate, _ b: Coordinate) -> Double {
        let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180
        let dφ = (b.latitude - a.latitude) * .pi / 180
        let dλ = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial bearing from `a` to `b`, degrees clockwise from true north in [0, 360).
    /// Pinned by `cardinalBearings` (N/E/S/W within 0.5°).
    public static func bearingDegrees(from a: Coordinate, to b: Coordinate) -> Double {
        let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180
        let dλ = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(dλ)
        return wrap360(atan2(y, x) * 180 / .pi)
    }

    /// Wrap to [0, 360).
    /// - Parameter deg: any angle in degrees.
    /// - Returns: the equivalent angle in [0, 360). Pinned by `wrapping`.
    public static func wrap360(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }

    /// Wrap to (-180, 180]. Positive = target is clockwise (to the right) of heading.
    /// Note `wrap180(180) == 180` and `wrap180(360) == 0`. Pinned by `wrapping`.
    public static func wrap180(_ deg: Double) -> Double {
        var d = wrap360(deg)
        if d > 180 { d -= 360 }
        return d
    }

    /// Signed error from `heading` to `target` in (-180, 180].
    /// - Parameters:
    ///   - target: bearing the user should walk, degrees true.
    ///   - heading: bearing the user is walking (body / course), degrees true.
    /// - Returns: degrees; positive = the target is to the right (turn / veer right).
    /// Pinned by `wrapping` (`bearingError(target: 10, heading: 350) == 20`).
    public static func bearingError(target: Double, heading: Double) -> Double {
        wrap180(target - heading)
    }
}

/// A turn / veer direction. `OffCourseDetector` output; `NavigationEngine` speaks it as
/// "Veer left." / "Veer right." and taps it on the watch as `.turnLeft` / `.turnRight`.
public enum Turn: String, Sendable, Codable, Equatable {
    // `left` = the target bearing is counter-clockwise of the heading (negative error), `right` =
    // clockwise (positive error).
    case left, right
}

/// Off-bearing > `threshold` continuously for `hold` seconds → one veer cue, then `cooldown`.
///
/// Not Sendable on purpose: owned and driven by `NavigationEngine` on the main actor (it calls
/// `update` with the veer error, `gated(at:)` for holes, `endEpisode()` when the situation changes
/// or after a cue, `reset()` at route start, when a turn settles and at every waypoint). After a
/// cue fires, `offSince` restarts, so a further full `hold` is needed before the next one.
///
/// "Continuously" is about the *evidence*, not the samples: the caller cannot judge every moment
/// (a poor or stale fix, no smoothed course yet, no target bearing) and reports those as
/// `gated(at:)`.
/// A hole up to `maxEvidenceGap` long is GPS jitter and the hold survives it — otherwise a walker
/// drifting off course under intermittent GPS could never reach `hold` and would never be warned.
/// A longer hole is a GPS *gap*: the history is dropped, so the first fix back cannot fire a veer
/// from what the walker was doing before the gap. A moment muted because the walking *situation*
/// changed (a turn settling, a curved leg, the zone beside a waypoint, or the walker standing
/// still — a measurement, not a missing one) is not a hole at all: the caller ends the episode
/// for those.
/// Pinned by `offCourseNeedsThreeSecondsThenCoolsDown`, `offCourseResetsWhenBackOnBearing`,
/// `gatedMomentsInsideGoodTrackingKeepTheHold`, `aGpsGapForgetsTheHoldSoThereIsNoInstantVeer`,
/// `onlyHolesLongerThanTwoSecondsForgetTheHold`, `aStopMidDriftRestartsTheHold`,
/// `endEpisodeRequiresAFullHoldAgain`.
public final class OffCourseDetector {
    /// Degrees of |bearing error| above which the user counts as off course (default 25°).
    public var threshold: Double = 25
    /// Seconds the error must stay above `threshold` before a cue (default 3 s).
    public var hold: TimeInterval = 3
    /// Minimum seconds between two veer cues (default 10 s).
    public var cooldown: TimeInterval = 10
    /// Longest hole in the evidence an episode survives (default 2 s).
    ///
    /// An episode is `hold` seconds of *continuous* off-course evidence, but the moments that
    /// carry it come from GPS and some cannot be judged at all (see `gated(at:)`). This is where
    /// the line between "jitter" and "gap" sits: judged moments up to `maxEvidenceGap` apart are
    /// one episode; a longer hole drops the history, so the first judged moment after it starts a
    /// fresh `hold`.
    ///
    /// 2 s. The two hard constraints only bound it to the open range (1 s, 3 s):
    ///   · **above one beat.** Judgeable moments arrive with the GPS fixes — while walking the
    ///     heading *is* the GPS course (`LocationService`), so the two share a cadence of about
    ///     one a second: measured on the e2e `wrong_turn` replay, 280 fixes, median 1.0 s apart,
    ///     278 of the 279 gaps at or under 1.2 s. A tolerance at or below 1 s bridges nothing.
    ///   · **below `hold`.** At 3 s or more a cue could rest on two judged moments `hold` apart
    ///     with nothing in between, and "3 s continuously off course" would stop being true.
    ///     Any value under 3 s forces every cue onto at least three judged moments.
    /// 2 s is the low end of that range: exactly one missed beat. The low end is the right end
    /// here because the recurring harm on this route has always been the *false* veer — a blind
    /// walker told to change direction when they should not — which is why TurnSettle, the
    /// `CourseSmoother` and the corner-fence reset all exist. A wider tolerance buys jitter
    /// immunity by letting more of a "continuous" episode go unobserved (at 2 s a cue is at worst
    /// 2 s of its 3 s episode unobserved; at 2.5 s, 2.5 s of 3 s). The two failure costs are also
    /// not symmetric: too strict merely *delays* a warning — the hold restarts and the next 3 s
    /// of evidence earns the cue — while the behaviour this replaces (ending the episode on every
    /// unjudgeable moment) *silenced* it outright.
    /// Considered and rejected:
    ///   · **5 s**, the age at which the engine stops judging a fix at all: far above `hold`, and
    ///     a judged fix may itself be nearly 5 s stale, so 5 + 5 s of position uncertainty could
    ///     sit inside one "continuous" 3 s episode.
    ///   · **2.5 s** (Muse review of this fix: one missed beat *plus* scheduling jitter can
    ///     measure 2.1–2.3 s, and 2.5 s still keeps the three-moment guarantee). The reasoning is
    ///     sound but its premise is unmeasured: the only cadence evidence available is the
    ///     simulator replay, whose gaps are bimodal (278 at ≤ 1.2 s, one at 6.7 s) with nothing
    ///     in the 2–2.5 s band, and `simctl` is metronomic in a way CoreLocation is not.
    ///     Widening on a guess, in the direction this route's history says is dangerous, is not a
    ///     trade to make blind. ⚠ Device follow-up: log real fix gaps on a walk; if
    ///     one-missed-beat holes really land above 2 s, raise this (never to 3 s or more) and put
    ///     the measurement in the commit.
    public var maxEvidenceGap: TimeInterval = 2

    /// Start of the current off-course episode (seconds), nil while on bearing.
    private var offSince: TimeInterval?
    /// Time of the last emitted cue (seconds); −∞ so the first cue is never blocked.
    private var lastCue: TimeInterval = -.infinity
    /// Time of the last *judged* moment (`update(error:now:)`), nil before the first one.
    /// Only judged moments count: a gap is measured between two pieces of real evidence,
    /// whether the caller kept reporting gated moments through it or went silent.
    private var lastJudged: TimeInterval?

    /// Creates a detector with the default 25° / 3 s / 10 s tuning.
    public init() {}

    /// Forget the current episode and the cooldown (route start / stop, turn settled).
    public func reset() {
        offSince = nil
        lastCue = -.infinity
        lastJudged = nil
    }

    /// End the current episode but keep the cooldown: the next off-course stretch needs a full
    /// `hold` again. Called when the course history is reset after a cue (Claude review workflow:
    /// otherwise the first smoothed course after the refill could fire at once), and by the caller
    /// whenever the walking *situation* changes rather than the evidence running out.
    ///
    /// Deliberately leaves `lastJudged` alone: it is the timestamp of the last real evidence, and
    /// ending an episode does not make that evidence not have happened. Clearing it would change
    /// nothing either way — with `offSince` already nil, the next judged moment starts a fresh
    /// episode whether or not `forgetEpisodeIfEvidenceIsStale` fires first — so the field keeps
    /// its single meaning (raised as a fragility in the Muse review; kept, with this note).
    public func endEpisode() {
        offSince = nil
    }

    /// A moment with no *evidence* about the leg being walked — the fix is poor or stale, its
    /// speed is unknown, or there is no smoothed course or target bearing yet: the episode keeps
    /// running unless the hole is already longer than `maxEvidenceGap`, in which case its history
    /// is dropped.
    ///
    /// A fix that positively reports the walker *standing* is not one of these: that is a
    /// measurement, and it ends the episode (see `aStopMidDriftRestartsTheHold`).
    ///
    /// Why not simply end the episode: intermittent GPS produces single unjudgeable moments all
    /// the time, and ending the episode on the first one meant a walker who was genuinely off
    /// course under jittery GPS could never accumulate `hold` seconds and was never warned —
    /// silence at exactly the moment the warning matters most.
    ///
    /// Only for holes in the evidence about *the same situation*. When the situation itself
    /// changes — a turn is still settling, the leg is curved, the walker is in the zone beside
    /// the current waypoint — the earlier error was about a different leg, so the caller must use
    /// `endEpisode()` (or `reset()`) instead and let nothing bridge it — otherwise a pre-turn
    /// drift plus a post-turn drift could add up to one cue. The same goes for a moment whose fix
    /// is too poor to locate the walker: the caller must not conclude "beside the waypoint" from
    /// it and end the episode, it must report the hole here (`NavigationEngine.update(heading:)`
    /// guard order).
    /// - Parameter now: seconds, the caller's clock — the same one it passes to
    ///   `update(error:now:)`, or the comparison is meaningless.
    public func gated(at now: TimeInterval) {
        forgetEpisodeIfEvidenceIsStale(now)
    }

    /// - Parameter error: signed bearing error (target − heading), degrees.
    /// - Parameter now: seconds; any clock, as long as `gated(at:)` gets the same one (the app
    ///   passes wall clock — `NavigationEngine` keeps fix timestamps on that clock too). A clock
    ///   that jumps backwards can only delay a cue, never bring one forward.
    /// - Returns: the direction to veer, once per episode.
    public func update(error: Double, now: TimeInterval) -> Turn? {
        // A hole longer than `maxEvidenceGap` since the last judged moment — the caller went
        // silent, or reported only gated moments — is a GPS gap, not jitter: the pre-gap history
        // says nothing about where the walker is pointing now, so it must not fire on this first
        // moment back (commit a7a5fa6: "no instant veer after a GPS gap").
        forgetEpisodeIfEvidenceIsStale(now)
        lastJudged = now
        guard abs(error) > threshold else {
            offSince = nil
            return nil
        }
        if offSince == nil { offSince = now }
        guard now - offSince! >= hold, now - lastCue >= cooldown else { return nil }
        lastCue = now
        offSince = now          // require another full hold before the next cue
        return error > 0 ? .right : .left
    }

    /// Drops the episode when the last judged moment is more than `maxEvidenceGap` old.
    ///
    /// Called from both entry points. Note what that does and does not buy: `gated(at:)` never
    /// moves `lastJudged`, and `update(error:now:)` runs this same check before it reads
    /// `offSince`, so on a forward-moving clock the call from `gated(at:)` changes no output —
    /// whatever it would drop, the next judged moment drops anyway. It is kept because it makes
    /// the rule hold on the state itself rather than only at the moment it is read (a clock that
    /// steps backwards, or a future caller that inspects the detector between fixes). The
    /// behaviour that is actually observable — and pinned by the tests — is the caller's choice
    /// of `gated(at:)` over `endEpisode()`, not this call (adversarial review, finding 4).
    private func forgetEpisodeIfEvidenceIsStale(_ now: TimeInterval) {
        guard let last = lastJudged, now - last > maxEvidenceGap else { return }
        offSince = nil
    }
}

/// What `GeofenceTracker.update` reports. Only one event kind today; kept an enum so the
/// navigation engine's `switch` stays exhaustive if more are added.
public enum NavEvent: Sendable, Equatable {
    /// The fence of `waypoint` (at `index`) was entered. `skipped` lists any earlier waypoints the
    /// tracker had to jump over to get there (their fences were missed, e.g. under bad GPS).
    /// `passedBy` is true when the waypoint was never entered but the user clearly walked past it.
    case reached(index: Int, waypoint: Waypoint, isLast: Bool, skipped: [Waypoint] = [], passedBy: Bool = false)
}

/// Walks a waypoint list: enter-once geofences with GPS quality gating.
///
/// Robustness rules (a single missed fence must never strand the route):
///   · **Skip-ahead** — every gated fix is tested against the current waypoint *and* the next
///     `lookahead` ones; entering a later fence advances past the missed ones (reported in
///     `skipped`).
///   · **Passed-by** — if the user came within `passedByFactor × radius` of the current waypoint
///     and the distance has then grown by a full radius over `passedByFixes` consecutive fixes,
///     the waypoint counts as reached (`passedBy: true`). Never applied to the last waypoint.
///   · **Arrival** (last waypoint) is exempt from the speed gate (people stop at the door) but
///     must be *plausibly* inside the fence — `distance + accuracy ≤ radius` — on
///     `arrivalHits` consecutive fixes, so one 30 m blob 45 m short of the door cannot end the
///     route (arrival stops the beacon and the Live Activity; there is no way back).
///
/// Not Sendable on purpose: created per route and driven by `NavigationEngine` on the main actor.
/// Pinned by the geofence tests in GeoMathTests.swift (gating, arrival streak, skip-ahead,
/// look-ahead arrival, passed-by, leg-bearing).
/// Owner: `NavigationEngine` (created in `start(_:)`, fed in `update(fix:)`, `advance()` on
/// Next, `targetBearing` / `isNearCurrent` for the beacon and the veer gate).
public final class GeofenceTracker {
    /// The route's waypoints in walking order (fixed for the tracker's lifetime).
    public private(set) var waypoints: [Waypoint]
    /// Index of the waypoint currently being approached; `waypoints.count` once finished.
    public private(set) var index: Int = 0
    /// Ignore fixes worse than this (metres) for intermediate waypoints. `NavigationEngine.start`
    /// overwrites it with its `veerMaxAccuracy` (also 20), so "GPS weak" and the fences agree.
    public var maxAccuracy: Double = 20
    /// Ignore fixes slower than this (m/s) for intermediate waypoints (standing still near a fence).
    /// The comparison is strict: `speed > minSpeed` passes (pinned by
    /// `invalidSpeedOrAccuracyDoesNotPassIntermediateGate`).
    public var minSpeed: Double = 0.5
    /// Arrival needs a valid fix no worse than this (metres); a 50 m blob must not end the route.
    public var maxArrivalAccuracy: Double = 30
    /// Consecutive plausible in-fence fixes needed for arrival.
    public var arrivalHits: Int = 2
    /// Consecutive plausible in-fence arrival fixes seen so far (reset on a judged miss / advance;
    /// a fix too poor to judge leaves it alone — `aGatedOutFixDoesNotBreakTheArrivalStreak`).
    private var arrivalStreak = 0
    /// How many waypoints beyond the current one a fix may claim.
    public var lookahead: Int = 2
    /// "Near" for passed-by detection = this many radii from the waypoint.
    public var passedByFactor: Double = 2
    /// Consecutive receding fixes needed before a near-miss counts as passed.
    public var passedByFixes: Int = 3

    /// Closest gated approach to the current waypoint (metres) since it became current.
    private var minDistance: Double = .infinity
    /// Distance (metres) of the previous gated fix to the current waypoint; nil after an advance.
    private var lastDistance: Double?
    /// Consecutive gated fixes that did not get closer (1 m jitter tolerance); reset whenever a fix
    /// sets a new closest approach (`passedByResetsRecedingStreakDuringSlowApproach`).
    private var recedingFixes = 0

    /// - Parameter waypoints: the route in walking order; the last one is the arrival fence.
    public init(waypoints: [Waypoint]) {
        self.waypoints = waypoints
    }

    /// The waypoint being approached, or nil once the route is finished.
    public var current: Waypoint? { index < waypoints.count ? waypoints[index] : nil }
    /// True after the arrival waypoint was reached (or everything was skipped manually).
    public var isFinished: Bool { index >= waypoints.count }

    /// Manual "next" (watch crown / Action button). Returns the waypoint skipped past.
    /// Resets passed-by state and the arrival streak. Pinned by `manualAdvanceSkipsWaypoint`,
    /// `passedByStateResetsAfterAdvance`.
    @discardableResult
    public func advance() -> Waypoint? {
        guard let wp = current else { return nil }
        moveTo(index + 1)
        return wp
    }

    /// Make `newIndex` current and clear all per-waypoint state (passed-by and arrival streak).
    private func moveTo(_ newIndex: Int) {
        index = newIndex
        minDistance = .infinity
        lastDistance = nil
        recedingFixes = 0
        arrivalStreak = 0
    }

    /// GPS quality gate. Intermediate waypoints: `0 ≤ accuracy ≤ maxAccuracy` m and
    /// `speed > minSpeed` m/s. The last waypoint: only `0 ≤ accuracy ≤ maxArrivalAccuracy` m.
    /// - Returns: true when the fix may be used for fences / passed-by at that waypoint.
    private func gatePasses(_ fix: GeoFix, forLast isLast: Bool) -> Bool {
        // Invalid (negative) accuracy or speed never satisfies the gate: CoreLocation reports
        // speed -1 exactly when it cannot compute one, typically while standing still.
        if isLast { return fix.accuracy >= 0 && fix.accuracy <= maxArrivalAccuracy }
        if fix.accuracy < 0 || fix.accuracy > maxAccuracy { return false }
        if fix.speed < 0 || fix.speed <= minSpeed { return false }
        return true
    }

    /// Feed one GPS fix.
    /// - Parameter fix: the latest fix (any quality; gating happens here).
    /// - Returns: `.reached` when a fence was entered (nearest index wins, earlier missed
    ///   waypoints in `skipped`) or the current waypoint was passed by; nil otherwise and always
    ///   nil once finished.
    public func update(_ fix: GeoFix) -> NavEvent? {
        guard current != nil else { return nil }
        let lastIndex = waypoints.count - 1

        // 1. Fence entry: current waypoint first, then the look-ahead ones (nearest index wins).
        let upper = min(lastIndex, index + lookahead)
        var arrivalCandidate = false
        var arrivalEvaluated = false
        for i in index...upper {
            let wp = waypoints[i]
            let isLast = i == lastIndex
            guard gatePasses(fix, forLast: isLast) else { continue }
            if isLast { arrivalEvaluated = true }
            let d = GeoMath.distanceMeters(fix.coordinate, wp.coordinate)
            if isLast {
                // Arrival is irreversible. Require the entire reported horizontal-accuracy
                // radius to fit inside the fence, not just half of it: correlated GPS error can
                // keep two optimistic fixes on the same wrong side of the door.
                guard d + fix.accuracy <= wp.radiusM else { continue }
                arrivalCandidate = true
                arrivalStreak += 1
                guard arrivalStreak >= arrivalHits else { continue }
            } else if d > wp.radiusM {
                continue
            }
            let skipped = Array(waypoints[index..<i])
            moveTo(i + 1)
            return .reached(index: i, waypoint: wp, isLast: isLast, skipped: skipped)
        }
        // Reset only on a fix that was good enough to judge: a 40 m blob between two good in-fence
        // fixes at the door must not starve arrival.
        if arrivalEvaluated && !arrivalCandidate { arrivalStreak = 0 }

        // 2. Passed-by: only intermediate waypoints, only on gated fixes.
        let isLast = index == lastIndex
        guard !isLast, gatePasses(fix, forLast: false), let wp = current else { return nil }
        let d = GeoMath.distanceMeters(fix.coordinate, wp.coordinate)
        minDistance = min(minDistance, d)
        // "Receding" tolerates 1 m of GPS jitter so one wobbly fix does not restart the count,
        // but approaching the waypoint (d <= minDistance) must always reset the count.
        if d <= minDistance {
            recedingFixes = 0
        } else if let last = lastDistance, d > last - 1 {
            recedingFixes += 1
        } else {
            recedingFixes = 0
        }
        lastDistance = d
        if minDistance <= wp.radiusM * passedByFactor,
           d >= minDistance + wp.radiusM,
           recedingFixes >= passedByFixes {
            let i = index
            moveTo(i + 1)
            return .reached(index: i, waypoint: wp, isLast: false, skipped: [], passedBy: true)
        }
        return nil
    }

    /// Bearing the user should walk right now: live bearing to the current waypoint when the fix is
    /// good, otherwise the previous waypoint's recorded `bearing_next_deg`. Inside the passed-by
    /// arming zone (`passedByFactor × radius`) the recorded leg bearing wins too: next to a
    /// waypoint the live bearing swings wildly with a few metres of offset, and after a missed
    /// fence it would point *back* at the waypoint behind the user.
    /// - Parameters:
    ///   - fix: the latest fix.
    ///   - maxLiveAccuracy: metres; fixes worse than this fall back to the recorded leg bearing.
    /// - Returns: degrees true in [0, 360), or nil once finished. Pinned by
    ///   `targetBearingUsesTheLegNearTheWaypoint`, `targetBearingFallsBackToRecordedWhenFixIsPoor`.
    public func targetBearing(from fix: GeoFix, maxLiveAccuracy: Double = 20) -> Double? {
        guard let wp = current else { return nil }
        let leg = index > 0 ? waypoints[index - 1].bearingNextDeg : nil
        let d = GeoMath.distanceMeters(fix.coordinate, wp.coordinate)
        if let leg, d <= wp.radiusM * passedByFactor { return leg }
        if fix.accuracy >= 0 && fix.accuracy <= maxLiveAccuracy {
            return GeoMath.bearingDegrees(from: fix.coordinate, to: wp.coordinate)
        }
        return leg ?? GeoMath.bearingDegrees(from: fix.coordinate, to: wp.coordinate)
    }

    /// True when the fix is inside the zone where passed-by may fire (veer cues are muted there).
    /// Always false for the last waypoint and once finished. Pinned by
    /// `targetBearingUsesTheLegNearTheWaypoint`.
    public func isNearCurrent(_ fix: GeoFix) -> Bool {
        guard let wp = current, index < waypoints.count - 1 else { return false }
        return GeoMath.distanceMeters(fix.coordinate, wp.coordinate) <= wp.radiusM * passedByFactor
    }
}
