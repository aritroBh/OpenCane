//
//  HeadGate.swift
//  CaneKitLogic
//
//  Which lane, if any, holds a *head-height* obstacle this frame — the one question every
//  "Head height." consumer asks before it alarms (Step 52, docs/cue_design_v2.md §3.2).
//
//  Why: the first cane walk said "Head height, head height" for the whole route. Of the 503 head
//  cells under 1.5 m in that log, 481 were near in the torso band too (walls, doors, people — the
//  things a cane finds) and 0 could have been 1.4 m above the ground at all. Step 51 fixes the
//  second problem (metric bands + coverage); this file fixes the first: a head cell is a candidate
//  only when it carries the **overhang signature** — the torso cell of the same lane is at least
//  `overhangGap` farther, has no return, or cannot be seen. Things near in both bands go to the
//  torso logic. The signature fails safe: a torso dropout (glass, sunlight) or an uncovered
//  torso cell keeps the head warning. ⚠ The signature is ON by default (owner decision
//  2026-09-13, `CueRules.requireOverhangSignature`); it supersedes the earlier "walls still get
//  Head height, leave as is" note in AGENTS.md. `Settings.bool("overhangSignature")` is the valve.
//
//  Pure, Foundation-only, no state. Callers: `CueDecider.update` (the head zone's distance),
//  `AppModel.contextLine` ("Something at head height." for the scene describer) and the island
//  glance in `AppModel.handle` (`headNear`) — one rule, three readers, so the voice, the haptic
//  and the island can never disagree about what is at head height. `ios/scripts/cue_audit.py`
//  carries a Python mirror (`head_gate`) for offline replay of a trip log.
//  Tests: CueDeciderTests (`wallNearInBothBandsIsNotHead`, `hangingSignWithClearTorsoIsHead`,
//  `torsoHalfAMetreFartherIsHead`, `torsoNoDataFailsSafeToHead`, `overhangSignatureCanBeSwitchedOff`,
//  `headIgnoresLanesWithoutCoverage`, `torsoWithoutCoverageFailsSafeToHead`).
//

import Foundation

/// The head-height gate: nearest covered head cell under the enter distance that looks like an
/// overhang rather than a wall.
public enum HeadGate {
    /// The lane the decider should warn about and how far it is.
    public struct Candidate: Sendable, Equatable {
        /// 0 left, 1 centre, 2 right.
        public var lane: Int
        /// The head cell's depth, metres (finite, < the enter distance).
        public var distance: Float
        /// - Parameters: lane index and depth in metres.
        public init(lane: Int, distance: Float) {
            self.lane = lane
            self.distance = distance
        }
    }

    /// The nearest lane whose head cell is covered (`grid.headCoverage`), finite and closer than
    /// `enter`, and — when `overhangGap` is given — whose torso cell is uncovered, non-finite, or
    /// at least `overhangGap` farther than the head cell. `overhangGap == nil` switches the
    /// signature off (any covered head cell under `enter` qualifies).
    /// - Parameters:
    ///   - grid: this frame's lanes (after `NearHold`).
    ///   - enter: the head zone's entry distance, metres (`CueThresholds.head`, plus the hysteresis
    ///     while the zone is active).
    ///   - overhangGap: `CueThresholds.overhangGapM` (0.5 m) when the signature is required, else nil.
    /// - Returns: the nearest qualifying lane, or nil when nothing at head height is in range.
    public static func candidate(in grid: LaneGrid, enter: Float, overhangGap: Float?) -> Candidate? {
        var best: Candidate?
        for lane in 0..<min(3, grid.head.count) {
            guard lane < grid.headCoverage.count, grid.headCoverage[lane] else { continue }
            let h = grid.head[lane]
            guard h.isFinite, h < enter else { continue }
            if let gap = overhangGap {
                let torsoCovered = lane < grid.torsoCoverage.count ? grid.torsoCoverage[lane] : true
                let t = lane < grid.torso.count ? grid.torso[lane] : .infinity
                // Fail-safe: no torso data (dropout) or no torso view keeps the warning.
                let signature = !torsoCovered || !t.isFinite || t >= h + gap
                guard signature else { continue }
            }
            if best == nil || h < best!.distance {
                best = Candidate(lane: lane, distance: h)
            }
        }
        return best
    }
}
