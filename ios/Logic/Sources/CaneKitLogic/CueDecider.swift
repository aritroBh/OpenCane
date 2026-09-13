//
//  CueDecider.swift
//  CaneKitLogic
//
//  LaneReport → haptic cue with hysteresis and rate limiting. The player (Core Haptics on the
//  phone, WKInterfaceDevice on the watch) is elsewhere; this only decides *what* and *when*.
//
//  Rules (spec): centre torso lane → continuous approach cue whose rate scales with 1/distance
//  from 2.0 m to 0.5 m; left lane = 2 taps; right lane = 3 taps; head row = double sharp hit.
//  Hysteresis 0.15 m; min 400 ms between cue changes; never repeat the same side cue inside 1 s.
//  Frames that are not trusted (cane sweeping) freeze the state and emit nothing.
//
//  The head cue is an *episode* (Step 52, docs/cue_design_v2.md §3.2): the first cane walk got
//  137 head cues and 8 "Head height." lines in 12 minutes because the haptic re-fired at 1 Hz
//  and the speech episode ended on any single clear frame. Now:
//    · the head distance comes from `HeadGate.candidate` — a covered head cell under `head`
//      whose torso cell is ≥ `overhangGapM` farther, non-finite or uncovered (the overhang
//      signature, ON by default; `requireOverhangSignature` is the valve);
//    · the **onset** fires at once — never held by the old 1 s repeat floor (only the 400 ms
//      change gate applies, as for every cue); it starts a `HeadEpisode`;
//    · inside the episode the haptic re-fires only when the distance crosses a closer band
//      (`headRefireBands` 1.0 m, 0.6 m — each once), ≥ `headRefireMinGap` (1.5 s) apart; a jump
//      across both bands fires once; there is no time-based re-fire;
//    · the zone still clears with the 0.15 m hysteresis (→ `.stop`, as before), but the episode
//      ends `headClearSeconds` (2 s) after the zone cleared on a trusted frame; a sweep (untrusted
//      frame) freezes state but neither ends nor restarts that clock (a cane sweeps every second —
//      restarting it held episodes open all walk, review 2026-09-13); a re-entry inside the live
//      episode is silent unless a closer band is crossed;
//    · a quiet head episode (no onset, no band to cross) does not own the hand: the next cue
//      (centre loop, sides) plays under it, and a band crossing takes over again;
//    · the payload `HapticCue.head(distance:onset:)` tells `CueSpeechPolicy` whether this fire is
//      the onset ("Head height.") or a band re-fire (spoken once more only under 0.6 m).
//
//  Purpose: the haptic grammar of the obstacle channel. `AppModel` feeds every `LaneReport`
//  (~30 Hz normal / up to 60 Hz high-rate) with the report's timestamp and routes the `CueOutput` to `HapticPlayer`, the
//  watch mirror and `CueSpeechPolicy`.
//  Owner: `AppModel.decider` (main actor) — `update` in `handle(_:)` with `now: report.timestamp`
//  (ARKit clock, never wall time); `reset()` when the app goes to the background and when "Both
//  cameras" pauses ARKit; `thresholds.head` is rewritten by `AppModel.applyCueRules` from
//  `CueRules.headEnterM` (1.5 m outdoors, 1.2 m indoors, Step 36).
//
//  Key invariants:
//    · Priority head > centre > left > right.
//    · Distances in metres, times in seconds (caller-supplied; the decider never reads a clock).
//    · The 1 s per-cue floor applies to left / right, also when the cue returns after a change or
//      a clear; the continuous centre loop and the head episode (its own rule above) are exempt.
//    · `CueKind` raw values are wire format (they travel to the watch in `PhoneToWatch`); the
//      head payload never leaves the phone.
//    · `CueDecider` is not Sendable: exactly one actor owns and drives it.
//  Tests: CueDeciderTests.swift (26 tests); StressTests.swift (Step 66: the seeded lane-stream
//  property test and the regressions `headOnsetFiresAfterAGatedHandoffAndALongSweep`,
//  `noHeadOnsetOnANonFiniteDistance` — an onset needs a finite distance, and an onset while `active`
//  is a stale `.head` still fires).
//

import Foundation

/// A cue the haptic player should render. `HapticPlayer` owns the patterns; the watch gets the
/// `kind` only (`PhoneToWatch.obstacle`).
public enum HapticCue: Sendable, Equatable {
    /// Continuous Geiger-style pulses for the centre torso lane; `distance` in metres, already
    /// floored at `CueThresholds.centerNear`. Rate from `GeigerRate.hertz`.
    case centerApproach(distance: Float)
    /// Left torso lane: 2 taps.
    case left
    /// Right torso lane: 3 taps.
    case right
    /// Head band, any lane: double sharp hit (never suppressed). `distance` is the gated head
    /// distance in metres; `onset` is true for the first fire of an episode ("Head height." is
    /// spoken), false for a band re-fire (spoken once more only under 0.6 m, `CueSpeechPolicy`).
    /// `HapticPlayer` renders the same pattern either way; the watch and the log see `kind`.
    case head(distance: Float, onset: Bool)

    /// The cue's kind, without the payload (for rate limiting, `CueSpeechPolicy`, the trip
    /// log's `cue` field and the watch).
    public var kind: CueKind {
        switch self {
        case .centerApproach: return .center
        case .left: return .left
        case .right: return .right
        case .head: return .head
        }
    }
}

/// Cue identity without payload; `clear` = nothing active. Raw values are wire format
/// (phone → watch `PhoneToWatch.obstacle`) and appear in trip logs.
public enum CueKind: String, Sendable, Codable, Hashable, CaseIterable {
    // ⚠ Renaming a case breaks an installed watch app (phone and watch update separately) and
    // trip-log readers that match these strings (the `cue` field; `ios/scripts/cue_audit.py`).
    case clear, center, left, right, head
}

/// What the player should do after one `update`. `AppModel.handle(_:)` maps `fire` to a pattern
/// (+ watch mirror + maybe speech), `updateCenter` to `HapticPlayer.setApproach(distance:)` and
/// `stop` to `HapticPlayer.stopAll()` (a stop no longer ends the head speech episode: the
/// decider's `HeadEpisode` does, after 2 s of trusted clear).
public enum CueOutput: Sendable, Equatable {
    /// Start (or re-fire) a cue.
    case fire(HapticCue)
    /// Centre approach still active; only the distance changed.
    case updateCenter(distance: Float)
    /// Active cue ended; stop any continuous pattern.
    case stop
}

/// Zone distances (metres) and timing gates (seconds) for `CueDecider`. Defaults are the spec.
/// Pinned by `hysteresisHoldsUntilPlusFifteenCentimetres`, `cueChangeNeeds400ms`,
/// `sameDiscreteCueRepeatsAtMostOncePerSecond`, `centerDistanceIsClampedToNearFloor`.
public struct CueThresholds: Sendable, Equatable {
    /// Head row (any lane) closer than this → head cue.
    public var head: Float = 1.5
    /// Torso centre lane closer than this → approach cue.
    public var center: Float = 2.0
    /// Rate scaling floor for the approach cue: the reported centre distance is `max(centerNear, d)`,
    /// so `GeigerRate` tops out at 8 Hz instead of racing on a LiDAR reading of a few cm.
    public var centerNear: Float = 0.5
    /// Torso left / right lanes closer than this → side cue.
    public var side: Float = 1.2
    /// Extra distance an obstacle must recede before a zone clears (m): a reading hovering at the
    /// threshold would otherwise toggle the cue every frame.
    public var hysteresis: Float = 0.15
    /// Minimum time between cue *changes* (s), so two lanes flickering cannot become a buzz storm.
    public var minChangeInterval: TimeInterval = 0.4
    /// Minimum time before the same discrete cue (left/right/head) fires again.
    public var repeatInterval: TimeInterval = 1.0
    /// Hold time (seconds) when LiDAR returns drop out (non-finite) after being in near/urgent (< 0.7m) range.
    /// Prevents point-blank saturation from clearing cues while pressed against a wall.
    public var nearDropoutHoldSeconds: TimeInterval = 1.5
    /// Overhang signature (Step 52): a head cell counts only when its torso cell is at least this
    /// much farther (metres), non-finite or uncovered. `HeadGate.candidate`.
    public var overhangGapM: Float = 0.5
    /// Whether the overhang signature is required. ON by default (owner decision 2026-09-13;
    /// pushed from `CueRules.requireOverhangSignature` by `AppModel.applyCueRules`). Off = any
    /// covered head cell under `head` is a head cue, as before Step 52.
    public var requireOverhangSignature = true
    /// Head distances (metres, descending) whose crossing re-fires the head haptic inside an
    /// episode, each once. No time-based re-fire.
    public var headRefireBands: [Float] = [1.0, 0.6]
    /// Minimum seconds between two head fires (onset → band, band → band).
    public var headRefireMinGap: TimeInterval = 1.5
    /// Seconds of continuous *trusted* clear (head zone inactive) that end a head episode. A
    /// sweep frame restarts the clock.
    public var headClearSeconds: TimeInterval = 2.0

    /// Creates the spec thresholds (1.5 / 2.0 / 0.5 / 1.2 / 0.15 m, 0.4 / 1.0 / 1.5 s; head
    /// episode: signature on, 0.5 m gap, bands 1.0 / 0.6 m, 1.5 s, 2 s clear).
    public init() {}
}

/// Geiger-counter rate for the approach cue: 2 Hz at 2.0 m, 8 Hz at 0.5 m. Caller:
/// `HapticPlayer`'s approach loop (re-read every pulse, so the rate follows `updateCenter`).
public enum GeigerRate {
    /// - Parameters:
    ///   - distance: centre-lane distance, metres.
    ///   - t: thresholds (currently unused; the 4 / d curve and 2–8 Hz clamp are fixed).
    /// - Returns: pulse rate in Hz = clamp(4 / distance, 2, 8); 2 Hz for non-finite or ≤ 0.
    /// Pinned by `geigerRateScalesWithInverseDistance`.
    public static func hertz(distance: Float, thresholds t: CueThresholds = CueThresholds()) -> Double {
        guard distance.isFinite, distance > 0 else { return 2 }
        let hz = 4.0 / Double(distance)
        return min(8, max(2, hz))
    }
}

/// LaneReport → at most one haptic instruction per frame, with hysteresis and rate limits.
/// Not Sendable on purpose: owned and driven by one actor (main in the app).
public final class CueDecider {

    /// Zone distances and timing gates; may be changed between updates.
    public var thresholds: CueThresholds

    /// The cue kind currently playing (`.clear` = none).
    public private(set) var active: CueKind = .clear
    /// Time (seconds, the caller's clock) of the last change of `active`; −∞ initially so the first
    /// cue is never held by `minChangeInterval`.
    public private(set) var lastChange: TimeInterval = -.infinity
    /// Last fire time (seconds) per kind, for the 1 s repeat floor.
    private var lastFired: [CueKind: TimeInterval] = [:]
    /// Hysteresis state per zone: true once entered, until it recedes past enter + hysteresis.
    private var zoneActive: [CueKind: Bool] = [.head: false, .center: false, .left: false, .right: false]
    /// Most recent finite distance reading per zone, to hold value across point-blank dropouts.
    private var lastNearDistance: [CueKind: Float] = [:]
    /// Monotonic timestamp of the most recent finite distance reading per zone.
    private var lastNearTime: [CueKind: TimeInterval] = [:]
    /// One head-height episode (Step 52): from the onset fire until `headClearSeconds` of trusted
    /// clear. Private state; `headEpisodeActive` is the public view.
    private struct HeadEpisode {
        /// When the onset fired.
        var startedAt: TimeInterval
        /// When the head haptic last fired (onset or band), for `headRefireMinGap`.
        var lastFireAt: TimeInterval
        /// How many of `headRefireBands` have been consumed (the onset consumes every band the
        /// onset distance was already inside).
        var bandsFired: Int
        /// When the current run of trusted clear frames began; nil while the zone is active.
        var clearSince: TimeInterval?
    }
    /// The live head episode, or nil.
    private var headEpisode: HeadEpisode?
    /// True between a head onset and the end of its episode (2 s of trusted clear). The app
    /// reads it only for the log; the speech policy learns it from the `onset` payload.
    public var headEpisodeActive: Bool { headEpisode != nil }

    /// - Parameter thresholds: zone distances and gates (default: the spec values).
    public init(thresholds: CueThresholds = CueThresholds()) {
        self.thresholds = thresholds
    }

    /// Forget everything (active cue, gates, zones). The app calls it when it goes to the
    /// background and depth pauses, and when "Both cameras" pauses ARKit; it keeps `thresholds`.
    /// The caller must also stop the player (`haptics.stopAll()`): reset emits no `.stop`.
    public func reset() {
        active = .clear
        lastChange = -.infinity
        lastFired.removeAll()
        lastNearDistance.removeAll()
        lastNearTime.removeAll()
        headEpisode = nil
        for k in zoneActive.keys { zoneActive[k] = false }
    }

    /// Feed one report. Returns what the player should do, or nil for "nothing new".
    /// - Parameters:
    ///   - r: the latest depth report (untrusted / no-depth reports freeze all state).
    ///   - now: seconds (the report's timestamp in the app). Must not go backwards within one
    ///     decider's life, or the gates compare against the future and hold cues.
    /// - Returns: `.fire`, `.updateCenter`, `.stop`, or nil (nothing new, or held by a gate).
    /// Pinned by every test in CueDeciderTests.swift.
    public func update(_ r: LaneReport, now: TimeInterval) -> CueOutput? {
        guard r.depthAvailable else { return nil }
        // Freeze while sweeping. A sweep neither ends nor restarts the head episode's clear clock
        // (review 2026-09-13, Antigravity + OpenCode): a cane sweeps every second, so restarting the
        // clock on every smeared frame kept an episode open for the rest of the walk and turned the
        // next real overhang's onset — its "Head height." — into a silent re-entry.
        guard r.isTrusted else { return nil }

        // The head distance is the gate's answer, not `min(head)`: covered cells only, and with
        // the signature on, only cells whose torso is clear enough to be an overhang. The active
        // zone keeps its hysteresis by letting the gate see up to `enter + hysteresis`.
        let headEnter = zoneActive[.head]! ? thresholds.head + thresholds.hysteresis : thresholds.head
        let headD = HeadGate.candidate(in: r.grid, enter: headEnter,
                                       overhangGap: thresholds.requireOverhangSignature ? thresholds.overhangGapM : nil)?
            .distance ?? .infinity
        let centerD = r.torso[1]
        let leftD = r.torso[0]
        let rightD = r.torso[2]

        updateZone(.head, distance: headD, enter: thresholds.head, now: now)
        updateZone(.center, distance: centerD, enter: thresholds.center, now: now)
        updateZone(.left, distance: leftD, enter: thresholds.side, now: now)
        updateZone(.right, distance: rightD, enter: thresholds.side, now: now)

        // Episode clock: active zone → not clearing; inactive with a live episode → the clear
        // run starts (or continues) and ends the episode after `headClearSeconds`. Checked before
        // the cue is chosen so a return after ≥ 2 s of clear is a new onset.
        if var ep = headEpisode {
            if zoneActive[.head]! {
                if let since = ep.clearSince, now - since >= thresholds.headClearSeconds {
                    headEpisode = nil                     // came back after the episode ended
                } else {
                    ep.clearSince = nil
                    headEpisode = ep
                }
            } else {
                let since = ep.clearSince ?? now
                if now - since >= thresholds.headClearSeconds {
                    headEpisode = nil
                } else {
                    ep.clearSince = since
                    headEpisode = ep
                }
            }
        }

        let effCenterD = centerD.isFinite ? centerD : (lastNearDistance[.center] ?? thresholds.centerNear)

        // Priority: head > centre > left > right — but only while the head cue has something to
        // say. Inside a live episode with no closer band to cross, the head zone is quiet and the
        // next cue plays (review 2026-09-13, OpenCode: the old branch `.stop`ped the centre loop and
        // left the walker with no proximity feedback until a band was crossed).
        // An onset needs a finite gated distance on *this* frame (Step 66, `noHeadOnsetOnANonFiniteDistance`):
        // the point-blank dropout latch may keep the zone (and a live episode) alive across a blind
        // frame, but it must never start a new "Head height." for a cell `HeadGate` rejects now
        // (uncovered, or near in both bands = a wall). A real saturation is finite here: `NearHold`
        // substitutes 0.1 m for a blind cell after a near reading.
        let headSpeaks = zoneActive[.head]!
            && ((headEpisode == nil && headD.isFinite) || bandWouldFire(distance: headD, now: now))
        let desired: HapticCue? =
            headSpeaks ? .head(distance: headD, onset: headEpisode == nil) :
            zoneActive[.center]! ? .centerApproach(distance: max(thresholds.centerNear, effCenterD)) :
            zoneActive[.left]! ? .left :
            zoneActive[.right]! ? .right : nil

        guard let desired else {
            // A quiet head episode with nothing else to play holds the head zone (a discrete tap:
            // no `.stop` that could cut its second transient); a different cue still running under
            // it — the centre loop whose zone just cleared — is stopped once.
            if zoneActive[.head]! {
                guard active != .head else { return nil }
                let wasPlaying = active != .clear
                active = .head
                lastChange = now
                return wasPlaying ? .stop : nil
            }
            if active != .clear {
                active = .clear
                lastChange = now
                return .stop
            }
            return nil
        }

        // A head onset while `active` is still `.head` from an episode that has since ended (Step 66,
        // `headOnsetFiresAfterAGatedHandoffAndALongSweep`): the change gate held the hand-off to another
        // cue, a sweep outlasted the 2 s clock, and the "same cue still active" branch below would treat
        // the returning overhang as a band re-fire with no episode — silent until the zone cleared.
        let onsetWhileHeadActive: Bool
        if case .head(_, true) = desired { onsetWhileHeadActive = active == .head } else { onsetWhileHeadActive = false }
        if desired.kind != active || onsetWhileHeadActive {
            guard now - lastChange >= thresholds.minChangeInterval else { return nil }
            if case .head(let d, let onset) = desired {
                // A head onset is never held by a repeat floor (hard rule 8): it fires the moment
                // the 400 ms change gate allows. A re-entry inside a live episode takes the zone
                // over silently unless it crosses a closer band.
                if onset {
                    active = .head
                    lastChange = now
                    headEpisode = HeadEpisode(startedAt: now, lastFireAt: now,
                                              bandsFired: bandsInside(d), clearSince: nil)
                    return .fire(desired)
                }
                if let fire = bandRefire(distance: d, now: now) {
                    active = .head
                    lastChange = now
                    return fire
                }
                if active != .clear {
                    // Don't leave the previous cue (e.g. the centre loop) running under the head zone.
                    active = .clear
                    lastChange = now
                    return .stop
                }
                active = .head
                lastChange = now
                return nil
            }
            // The per-cue 1 s floor also applies when a side cue *returns* after a change or a
            // clear (doorway edge flickering left↔right). The centre approach loop is continuous
            // and exempt.
            if desired.kind != .center,
               now - (lastFired[desired.kind] ?? -.infinity) < thresholds.repeatInterval {
                if active != .clear {
                    // Don't leave the previous cue (e.g. the centre loop) running while we wait.
                    active = .clear
                    lastChange = now
                    return .stop
                }
                return nil
            }
            active = desired.kind
            lastChange = now
            lastFired[desired.kind] = now
            return .fire(desired)
        }

        // Same cue still active.
        switch desired {
        case .centerApproach(let d):
            return .updateCenter(distance: d)
        case .left, .right:
            let last = lastFired[desired.kind] ?? -.infinity
            guard now - last >= thresholds.repeatInterval else { return nil }
            lastFired[desired.kind] = now
            return .fire(desired)
        case .head(let d, _):
            return bandRefire(distance: d, now: now)
        }
    }

    /// True when `bandRefire` would fire for `d` now (same three conditions, nothing consumed).
    private func bandWouldFire(distance d: Float, now: TimeInterval) -> Bool {
        guard let ep = headEpisode, ep.bandsFired < thresholds.headRefireBands.count else { return false }
        return d < thresholds.headRefireBands[ep.bandsFired] && now - ep.lastFireAt >= thresholds.headRefireMinGap
    }

    /// How many of `headRefireBands` a head distance is already inside (bands are descending).
    private func bandsInside(_ d: Float) -> Int {
        thresholds.headRefireBands.filter { d <= $0 }.count
    }

    /// Inside a live episode: fire `.head(distance:onset: false)` when `d` has crossed the next
    /// unconsumed band and ≥ `headRefireMinGap` has passed since the last fire; consumes every band
    /// `d` is inside (a jump from 1.2 m to 0.5 m fires once). A crossing held back by the gap is
    /// remembered — the band stays unconsumed until it fires. Nil otherwise.
    private func bandRefire(distance d: Float, now: TimeInterval) -> CueOutput? {
        guard var ep = headEpisode, ep.bandsFired < thresholds.headRefireBands.count else { return nil }
        guard d < thresholds.headRefireBands[ep.bandsFired] else { return nil }
        guard now - ep.lastFireAt >= thresholds.headRefireMinGap else { return nil }
        ep.bandsFired = max(ep.bandsFired + 1, bandsInside(d))
        ep.lastFireAt = now
        headEpisode = ep
        return .fire(.head(distance: d, onset: false))
    }

    /// Hysteresis for one zone: enters when `d < enter`, clears when `d > enter + hysteresis`
    /// or when a non-finite dropout exceeds `nearDropoutHoldSeconds` after urgent proximity (< 0.7m).
    /// (The head *episode* outlives the zone by `headClearSeconds`; that is `update`'s clock, not
    /// this function's.)
    /// - Parameters:
    ///   - kind: which zone.
    ///   - d: the zone's distance this frame, metres.
    ///   - enter: the zone's entry threshold, metres.
    ///   - now: seconds (the report's timestamp).
    private func updateZone(_ kind: CueKind, distance d: Float, enter: Float, now: TimeInterval) {
        let isOn = zoneActive[kind] ?? false
        if isOn {
            if d.isFinite {
                if d > enter + thresholds.hysteresis {
                    zoneActive[kind] = false
                } else {
                    lastNearDistance[kind] = d
                    lastNearTime[kind] = now
                }
            } else {
                // Non-finite (dropout/saturation). If this zone was recently in urgent/near proximity (< 0.7m),
                // do not release immediately; point-blank walls saturate LiDAR. Hold the active zone.
                let lastT = lastNearTime[kind] ?? -.infinity
                let lastD = lastNearDistance[kind] ?? .infinity
                if lastD < thresholds.centerNear + 0.2, now - lastT <= thresholds.nearDropoutHoldSeconds {
                    // Latched active: obstacle is point-blank against the sensor
                } else {
                    zoneActive[kind] = false
                }
            }
        } else if d < enter {
            zoneActive[kind] = true
            lastNearDistance[kind] = d
            lastNearTime[kind] = now
        }
    }
}
