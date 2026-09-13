//
//  FallDetector.swift
//  CaneKitLogic
//
//  Decides that the cane (and the phone clamped to it) has fallen, from accelerometer magnitude
//  and tilt. Pure state machine: the app feeds it CoreMotion samples, it answers with a `Fall`.
//
//  The shape a real fall has, and why each stage is required:
//    1. **Free fall** — total acceleration collapses toward 0 g while falling. Required because
//       almost nothing else does this: a cane tapped hard, set down, or swung stays near 1 g.
//    2. **Impact** — a spike as it hits. Required because free fall alone is a drop the walker
//       may have caught.
//    3. **Rest, tilted** — the cane lies still and off-vertical afterwards. Required because a
//       cane that is upright and moving again two seconds later did not stay down, and the whole
//       point is to catch the walker who is on the ground next to it.
//
//  Dropping any one stage is what makes a fall detector cry wolf, and a family that learns to
//  ignore OpenCane's alerts is worse than no alerts.
//
//  ⚠ **These thresholds are educated guesses, not measurements.** Nothing in this file has been
//  validated against a real cane going over — AGENTS.md "evidence before claims" is not satisfied
//  here and the numbers must be re-derived from device logs (docs/todo.md). They are deliberately
//  conservative: every one of them errs toward missing a marginal fall rather than inventing one.
//
//  Owner: `FallWatcher` (app) feeds it `CMDeviceMotion` at 20 Hz and reports to `FamilyAlerts`.
//
//  Key invariants:
//    · Single-owner mutable struct, `nonisolated`, like `CueDecider`.
//    · `now` is the caller's monotonic seconds, never wall time, so replay and tests are exact.
//    · One `Fall` per episode: after firing, it re-arms only once the cane is upright again.
//  Tests: FallDetectorTests.swift.
//

import Foundation

/// A detected fall, with the evidence that produced it (so a trip log can be argued with).
public struct Fall: Sendable, Equatable {
    /// When the impact landed, in the caller's clock.
    public var at: TimeInterval
    /// Peak g seen at impact.
    public var impactG: Double
    /// Degrees off vertical once it came to rest. ~90° is flat on the ground.
    public var restTiltDegrees: Double
}

/// Free fall → impact → still and tilted. Feed it every motion sample.
public struct FallDetector {

    /// The tuning. ⚠ Guesses; see the file header.
    public struct Config: Sendable, Equatable {
        /// Total acceleration below this counts as falling. True free fall is 0 g; 0.6 leaves room
        /// for a cane that clips something on the way down.
        public var freeFallG: Double = 0.6
        /// Seconds of free fall required. 0.1 s ≈ a 5 cm drop — short enough for a cane going over
        /// from waist height, long enough to reject a single noisy sample.
        public var minFreeFallSeconds: TimeInterval = 0.1
        /// Peak g that counts as the impact.
        public var impactG: Double = 2.5
        /// The impact must follow the free fall within this, or the episode is abandoned.
        public var impactWindowSeconds: TimeInterval = 1.0
        /// After impact, the cane must stay within ±this of 1 g to count as "at rest".
        public var restBandG: Double = 0.25
        /// …for this long. Long enough that a bounce or a quick pick-up does not qualify.
        public var minRestSeconds: TimeInterval = 1.5
        /// …and be at least this far off vertical. A cane still upright did not fall over.
        public var minRestTiltDegrees: Double = 50
        /// Below this tilt the detector re-arms: the cane is upright again, so the episode is over.
        public var uprightTiltDegrees: Double = 30

        public init() {}
    }

    public var config: Config

    /// Where we are in the episode.
    private enum Phase: Equatable {
        case watching
        /// Free fall began at this time.
        case falling(since: TimeInterval)
        /// Impact seen: its time and peak g; waiting for the cane to settle.
        case settling(impactAt: TimeInterval, impactG: Double, stillSince: TimeInterval?)
        /// A fall was reported; nothing more until the cane is upright again.
        case reported
    }

    private var phase: Phase = .watching

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Forgets the episode in progress (route start / stop). Does not un-report a fall already
    /// sent — that went to the family and cannot be taken back.
    public mutating func reset() {
        phase = .watching
    }

    /// One motion sample.
    /// - Parameters:
    ///   - magnitudeG: total acceleration magnitude in g (gravity included, so ~1.0 at rest).
    ///   - tiltDegrees: angle of the phone's up-axis from vertical; 0 upright, 90 flat.
    ///   - now: caller's monotonic seconds.
    /// - Returns: the `Fall` exactly once per episode, otherwise nil.
    public mutating func update(magnitudeG: Double, tiltDegrees: Double,
                                now: TimeInterval) -> Fall? {
        guard magnitudeG.isFinite, tiltDegrees.isFinite else { return nil }

        switch phase {
        case .reported:
            // Re-arm only when the cane is upright again: otherwise a cane lying on the ground
            // would re-report every time it was nudged.
            if tiltDegrees <= config.uprightTiltDegrees { phase = .watching }
            return nil

        case .watching:
            if magnitudeG < config.freeFallG { phase = .falling(since: now) }
            return nil

        case .falling(let since):
            if magnitudeG >= config.impactG {
                // Only an impact that ends a long enough free fall counts.
                guard now - since >= config.minFreeFallSeconds else { phase = .watching; return nil }
                phase = .settling(impactAt: now, impactG: magnitudeG, stillSince: nil)
                return nil
            }
            // Back to normal gravity without an impact: the drop was caught, or it was noise.
            if magnitudeG >= config.freeFallG, now - since >= config.impactWindowSeconds {
                phase = .watching
            }
            return nil

        case .settling(let impactAt, let impactG, let stillSince):
            guard now - impactAt <= config.impactWindowSeconds + config.minRestSeconds * 3 else {
                phase = .watching                       // never settled: give up on this episode
                return nil
            }
            let still = abs(magnitudeG - 1.0) <= config.restBandG
            let tilted = tiltDegrees >= config.minRestTiltDegrees
            guard still, tilted else {
                // Moving again, or stood back up: not a fall that stayed down.
                phase = .settling(impactAt: impactAt, impactG: impactG, stillSince: nil)
                return nil
            }
            let start = stillSince ?? now
            if now - start >= config.minRestSeconds {
                phase = .reported
                return Fall(at: impactAt, impactG: impactG, restTiltDegrees: tiltDegrees)
            }
            phase = .settling(impactAt: impactAt, impactG: impactG, stillSince: start)
            return nil
        }
    }
}
