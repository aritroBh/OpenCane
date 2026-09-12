//
//  HeadNodDetector.swift
//  CaneKitLogic
//
//  The AirPods "double nod to talk" gesture: two quick down-up nods of the head start voice
//  input, so a walker with both hands busy (cane + dog / rail / door) can ask OpenCane a question
//  without the phone, the watch or Siri.
//
//  Purpose: keep the gesture's numbers (degrees, seconds) out of `HeadPoseTracker` so they can be
//  pinned by `swift test` (AGENTS.md hard rule 3). The app feeds `CMHeadphoneMotionManager`'s
//  attitude pitch at its native rate and starts listening when `update` returns true. Owner (Step 3
//  of the nod plan): `HeadPoseTracker` → `AppModel.startVoiceInput()`, behind the off-by-default
//  "Nod to talk" hands-free option.
//
//  Key invariants:
//    · `Sendable` value type, `mutating` updates, no clock of its own: the owner passes `now`
//      (seconds, any monotonic clock) and writes the mutated copy back.
//    · Fires **exactly once** per double nod, on the sample that completes the second nod, then
//      stays silent for `refractorySeconds`; nods completed inside the refractory are dropped and
//      never seed a new pair.
//    · A nod is timed from the moment the head *leaves* its resting pitch, so a slow tilt with a
//      fast return, or a fast tilt with a long hold, never counts (`aLargeSlowTiltIsSilent`).
//    · ⚠ Every number below is an **untuned placeholder** from the plan, not a measurement.
//      Nothing here has been walked on the cane; AGENTS.md says "unknown, need to measure"
//      outranks a plausible number, so treat them as such and re-measure from `head_nod` trip-log
//      events before trusting them. Tests: HeadNodDetectorTests.swift.
//

import Foundation

/// Detects a double head nod from a stream of pitch samples.
///
/// The detector tracks pitch **turning points** with a small hysteresis band: a running extreme
/// becomes a turning point once the pitch has reversed by `turnBandDeg`. A nod is a turning point
/// A (rest), a turning point B at least `minAmplitudeDeg` away, and a return of at least
/// `minAmplitudeDeg` back from B, all within `maxNodSeconds` of the head leaving A. A double nod is
/// two consecutive, non-overlapping nods whose completions are within `pairWindowSeconds`.
///
/// ponytail: direction-agnostic on purpose. The sign of `CMAttitude.pitch` for "chin down" on AirPods
/// has not been measured on device, so a nod may be down-up **or** up-down here. Once the sign is
/// measured, tightening to down-first is a one-line `down < 0` check in `update`.
///
/// Pinned by `singleNodIsSilent`, `doubleNodFiresOnceOnTheSecondNod`, `nodsTooFarApartAreSilent`,
/// `walkingSwayIsSilent`, `aLargeSlowTiltIsSilent`, `refractoryHoldsAfterAFire`,
/// `resetClearsAPendingFirstNod`.
public struct HeadNodDetector: Sendable, Equatable {
    /// Degrees: peak-to-trough pitch a nod's down *and* up halves must each cover.
    /// ⚠ Untuned placeholder (plan value); walking sway measured so far is ≈ ±5°.
    public static let minAmplitudeDeg: Double = 15
    /// Seconds from the head leaving rest to the return completing; slower is a look, not a nod.
    /// ⚠ Untuned placeholder (plan value).
    public static let maxNodSeconds: TimeInterval = 0.8
    /// Seconds between the completions of the two nods of a pair.
    /// ⚠ Untuned placeholder (plan value).
    public static let pairWindowSeconds: TimeInterval = 2.5
    /// Seconds after a fire during which completed nods are dropped.
    /// ⚠ Untuned placeholder (plan value).
    public static let refractorySeconds: TimeInterval = 3
    /// Degrees of reversal that turns a running extreme into a turning point (sensor-noise gate).
    /// ⚠ Untuned placeholder: AirPods pitch noise at rest has not been measured.
    public static let turnBandDeg: Double = 3

    /// A pitch sample the detector remembers: a running extreme or a turning point.
    private struct Point: Sendable, Equatable {
        var pitch: Double
        var time: TimeInterval
    }

    /// Running extreme in the current direction; nil until the first sample. Its `time` is
    /// refreshed while the pitch rests within `turnBandDeg` of it, so a turning point carries the
    /// moment the head *left* it.
    private var extreme: Point?
    /// +1 pitch rising, −1 falling, 0 before the first departure from the first sample.
    private var direction: Double = 0
    /// Most recent turning point (B, the nod's far end while the head returns).
    private var lastTurn: Point?
    /// The turning point before `lastTurn` (A, the rest pitch the nod left).
    private var previousTurn: Point?
    /// Completion time of a first nod waiting for its partner.
    private var firstNodEnd: TimeInterval?
    /// Time of the last fire; −∞ so the first double nod is never in refractory.
    private var lastFire: TimeInterval = -.infinity

    /// Creates a detector with the placeholder tuning above.
    public init() {}

    /// Forget everything (AirPods disconnected, route stopped, feature switched off).
    public mutating func reset() {
        extreme = nil
        direction = 0
        lastTurn = nil
        previousTurn = nil
        firstNodEnd = nil
        lastFire = -.infinity
    }

    /// Feed one head-pitch sample.
    /// - Parameters:
    ///   - pitchDeg: head pitch, degrees (either sign convention; see the ponytail note).
    ///   - now: seconds, monotonic, same clock for every sample.
    /// - Returns: true exactly once per double nod, on the sample completing the second nod.
    @discardableResult
    public mutating func update(pitchDeg pitch: Double, now: TimeInterval) -> Bool {
        guard let e = extreme else {
            extreme = Point(pitch: pitch, time: now)
            return false
        }
        // 1. Track extrema. Moving on in the current direction extends the extreme; resting within
        //    the band refreshes its time; reversing by the band closes it as a turning point.
        if direction != 0, (pitch - e.pitch) * direction >= 0 {
            extreme = Point(pitch: pitch, time: now)
        } else if abs(pitch - e.pitch) < Self.turnBandDeg {
            extreme?.time = now
        } else {
            previousTurn = lastTurn
            lastTurn = e
            direction = pitch > e.pitch ? 1 : -1
            extreme = Point(pitch: pitch, time: now)
        }
        // 2. A nod = A → B ≥ amplitude, back ≥ amplitude from B, all within maxNodSeconds of leaving A.
        guard let a = previousTurn, let b = lastTurn, let x = extreme else { return false }
        let away = b.pitch - a.pitch
        let back = (b.pitch - x.pitch) * (away > 0 ? 1 : -1)
        guard abs(away) >= Self.minAmplitudeDeg, back >= Self.minAmplitudeDeg,
              now - a.time <= Self.maxNodSeconds else { return false }
        // Consumed: the next nod must start at the next turning point (no A-B-C / B-C-D overlap).
        previousTurn = nil
        lastTurn = nil
        return nodCompleted(at: now)
    }

    /// Pairs completed nods and applies the refractory.
    private mutating func nodCompleted(at now: TimeInterval) -> Bool {
        guard now - lastFire >= Self.refractorySeconds else { return false }
        if let first = firstNodEnd, now - first <= Self.pairWindowSeconds {
            firstNodEnd = nil
            lastFire = now
            return true
        }
        firstNodEnd = now
        return false
    }
}
