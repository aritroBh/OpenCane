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

import Foundation

public enum HapticCue: Sendable, Equatable {
    case centerApproach(distance: Float)
    case left
    case right
    case head

    public var kind: CueKind {
        switch self {
        case .centerApproach: return .center
        case .left: return .left
        case .right: return .right
        case .head: return .head
        }
    }
}

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
    public init() {}
}

/// Geiger-counter rate for the approach cue: 2 Hz at 2.0 m, 8 Hz at 0.5 m.
public enum GeigerRate {
    public static func hertz(distance: Float, thresholds t: CueThresholds = CueThresholds()) -> Double {
        guard distance.isFinite, distance > 0 else { return 2 }
        let hz = 4.0 / Double(distance)
        return min(8, max(2, hz))
    }
}

/// Not Sendable on purpose: owned and driven by one actor (main in the app).
public final class CueDecider {

    public var thresholds: CueThresholds

    public private(set) var active: CueKind = .clear
    public private(set) var lastChange: TimeInterval = -.infinity
    private var lastFired: [CueKind: TimeInterval] = [:]
    private var zoneActive: [CueKind: Bool] = [.head: false, .center: false, .left: false, .right: false]

    public init(thresholds: CueThresholds = CueThresholds()) {
        self.thresholds = thresholds
    }

    public func reset() {
        active = .clear
        lastChange = -.infinity
        lastFired.removeAll()
        for k in zoneActive.keys { zoneActive[k] = false }
    }

    /// Feed one report. Returns what the player should do, or nil for "nothing new".
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

    private func updateZone(_ kind: CueKind, distance d: Float, enter: Float) {
        let isOn = zoneActive[kind] ?? false
        if isOn {
            if d > enter + thresholds.hysteresis { zoneActive[kind] = false }
        } else if d < enter {
            zoneActive[kind] = true
        }
    }
}
