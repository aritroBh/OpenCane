//
//  CueDecider.swift
//  CaneKitLogic
//
//  LaneReport → haptic cue with hysteresis and rate limiting. The player (Core Haptics on the
//  phone, WKInterfaceDevice on the watch) is elsewhere; this only decides *what* and *when*.
//
//  Rules (spec): centre torso lane → continuous approach cue whose rate scales with 1/distance
//  from 2.0 m to 0.5 m; left lane = 2 taps; right lane = 3 taps; head row = double sharp hit.
//  Hysteresis 0.15 m; min 400 ms between cue changes; never repeat the same cue inside 1 s.
//  Frames that are not trusted (cane sweeping) freeze the state and emit nothing.
//
//  Purpose: the haptic grammar of the obstacle channel. `AppModel` feeds every `LaneReport`
//  (~30 Hz normal / up to 60 Hz high-rate) with the report's timestamp and routes the `CueOutput` to `HapticPlayer`, the
//  watch mirror and `CueSpeechPolicy`.
//
//  Key invariants:
//    · Priority head > centre > left > right.
//    · Distances in metres, times in seconds (caller-supplied; the decider never reads a clock).
//    · The 1 s per-cue floor also applies when a discrete cue returns after a change or a
//      clear; only the continuous centre loop is exempt.
//    · `CueKind` raw values are wire format (they travel to the watch in `PhoneToWatch`).
//    · `CueDecider` is not Sendable: exactly one actor owns and drives it.
//  Tests: CueDeciderTests.swift (14 tests).
//

import Foundation

/// A cue the haptic player should render.
public enum HapticCue: Sendable, Equatable {
    /// Continuous Geiger-style pulses for the centre torso lane; `distance` in metres, already
    /// floored at `CueThresholds.centerNear`. Rate from `GeigerRate.hertz`.
    case centerApproach(distance: Float)
    /// Left torso lane: 2 taps.
    case left
    /// Right torso lane: 3 taps.
    case right
    /// Head row, any lane: double sharp hit (never suppressed; spoken once per episode).
    case head

    /// The cue's kind, without the distance payload (for rate limiting and the watch).
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
    case clear, center, left, right, head
}

/// What the player should do after one `update`.
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
    /// Rate scaling floor for the approach cue.
    public var centerNear: Float = 0.5
    /// Torso left / right lanes closer than this → side cue.
    public var side: Float = 1.2
    /// Extra distance an obstacle must recede before a zone clears.
    public var hysteresis: Float = 0.15
    /// Minimum time between cue *changes*.
    public var minChangeInterval: TimeInterval = 0.4
    /// Minimum time before the same discrete cue (left/right/head) fires again.
    public var repeatInterval: TimeInterval = 1.0
    /// Creates the spec thresholds (1.5 / 2.0 / 0.5 / 1.2 / 0.15 m, 0.4 / 1.0 s).
    public init() {}
}

/// Geiger-counter rate for the approach cue: 2 Hz at 2.0 m, 8 Hz at 0.5 m.
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

/// Not Sendable on purpose: owned and driven by one actor (main in the app).
public final class CueDecider {

    /// Zone distances and timing gates; may be changed between updates.
    public var thresholds: CueThresholds

    /// The cue kind currently playing (`.clear` = none).
    public private(set) var active: CueKind = .clear
    /// Time (seconds) of the last change of `active`; −∞ initially.
    public private(set) var lastChange: TimeInterval = -.infinity
    /// Last fire time (seconds) per kind, for the 1 s repeat floor.
    private var lastFired: [CueKind: TimeInterval] = [:]
    /// Hysteresis state per zone: true once entered, until it recedes past enter + hysteresis.
    private var zoneActive: [CueKind: Bool] = [.head: false, .center: false, .left: false, .right: false]

    /// - Parameter thresholds: zone distances and gates (default: the spec values).
    public init(thresholds: CueThresholds = CueThresholds()) {
        self.thresholds = thresholds
    }

    /// Forget everything (active cue, gates, zones). The app calls it when it goes to the
    /// background and depth pauses.
    public func reset() {
        active = .clear
        lastChange = -.infinity
        lastFired.removeAll()
        for k in zoneActive.keys { zoneActive[k] = false }
    }

    /// Feed one report. Returns what the player should do, or nil for "nothing new".
    /// - Parameters:
    ///   - r: the latest depth report (untrusted / no-depth reports freeze all state).
    ///   - now: seconds (the report's timestamp in the app).
    /// Pinned by every test in CueDeciderTests.swift.
    public func update(_ r: LaneReport, now: TimeInterval) -> CueOutput? {
        guard r.depthAvailable, r.isTrusted else { return nil }   // freeze while sweeping

        let headMin = min(r.head[0], r.head[1], r.head[2])
        let centerD = r.torso[1]
        let leftD = r.torso[0]
        let rightD = r.torso[2]

        updateZone(.head, distance: headMin, enter: thresholds.head)
        updateZone(.center, distance: centerD, enter: thresholds.center)
        updateZone(.left, distance: leftD, enter: thresholds.side)
        updateZone(.right, distance: rightD, enter: thresholds.side)

        // Priority: head > centre > left > right.
        let desired: HapticCue? =
            zoneActive[.head]! ? .head :
            zoneActive[.center]! ? .centerApproach(distance: max(thresholds.centerNear, centerD)) :
            zoneActive[.left]! ? .left :
            zoneActive[.right]! ? .right : nil

        guard let desired else {
            if active != .clear {
                active = .clear
                lastChange = now
                return .stop
            }
            return nil
        }

        if desired.kind != active {
            guard now - lastChange >= thresholds.minChangeInterval else { return nil }
            // The per-cue 1 s floor also applies when a discrete cue *returns* after a change or a
            // clear (doorway edge flickering left↔right, a sign flapping across the head exit line).
            // The centre approach loop is continuous and exempt.
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
        case .left, .right, .head:
            let last = lastFired[desired.kind] ?? -.infinity
            guard now - last >= thresholds.repeatInterval else { return nil }
            lastFired[desired.kind] = now
            return .fire(desired)
        }
    }

    /// Hysteresis for one zone: enters when `d < enter`, clears only when `d > enter + hysteresis`.
    /// - Parameters:
    ///   - kind: which zone.
    ///   - d: the zone's distance this frame, metres.
    ///   - enter: the zone's entry threshold, metres.
    private func updateZone(_ kind: CueKind, distance d: Float, enter: Float) {
        let isOn = zoneActive[kind] ?? false
        if isOn {
            if d > enter + thresholds.hysteresis { zoneActive[kind] = false }
        } else if d < enter {
            zoneActive[kind] = true
        }
    }
}
