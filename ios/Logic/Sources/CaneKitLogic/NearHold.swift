//
//  NearHold.swift
//  CaneKitLogic
//
//  Tells "nothing there" from "too close to read". Inside roughly 10 cm the iPhone LiDAR does not
//  return a low-confidence distance (Step 38 handles that band down to 5 cm) — it returns 0 or NaN.
//  `LaneMath` counts those as *blind* samples and reports the blind fraction per cell; a cell that
//  is mostly blind has no distance, so it came back `.infinity`, and `.infinity` renders CLEAR in
//  green with silence. A teammate's photo (Sat 2026-09-12, 22:44: phone against a wall, six green
//  CLEAR tiles, "Depth OK") is the bug; `pointBlankLowConfidenceObstacleIsDetected` never covered
//  it because its samples were finite.
//
//  Rule (Step 48): a cell that reads `.infinity` while ≥ `blindFraction` of its samples were blind,
//  and whose last *measured* distance was under `armBelowM`, is a point-blank obstacle — report
//  `pointBlankM` (0.1 m: below `CueThresholds.centerNear`, so tiles say STOP and the decider fires
//  urgent) and flag the cell as held. The hold releases the moment the cell measures anything
//  again (any distance) or its blind fraction falls under the threshold (a real no-return clear).
//  A single cell never arms without a prior near reading: a truly empty view (sky, a long
//  corridor) that happens to be blind stays clear, because nobody walked up to it. The one case
//  with no history — the phone switched on already against a wall (launch, pocket, relocalisation)
//  — is the **cold start** rule (Muse review): when at least `coldStartMinCells` (4) of the six
//  cells are `.infinity` with a blind share ≥ `coldStartBlindFraction` (0.8) and none has history,
//  those cells report `coldStartM` (0.8 m: NEAR, not STOP — the Geiger runs, the tiles go orange,
//  nothing is silent) until any cell measures. A head-only blind (a tilt up at the sky) is not
//  four cells, so it stays clear. Untrusted frames (the cane sweeping, `LaneReport.isTrusted`
//  false) disarm every cell: history from before a swing describes another view (Muse F1).
//  Evidence for tuning: `lanes {head_blind, torso_blind, held}` in the trip log.
//
//  Pure, Foundation-only, value type. Owner: `DepthFrameProcessor.nearHold` (queue-only), applied
//  to every `LaneGrid` right after `LaneMath.computeLanes` and before the report is published, so
//  the tiles, `CueDecider`, the watch and the Live Activity all see the held distance. Reset at
//  depth-session boundaries only (`DepthFrameProcessor.resetNearHold`, called from
//  `dropLatestImage`, which every session re-run and pause goes through) — never by a transient
//  frame without depth, which is exactly when a wall is being pressed (Muse F4).
//  Tests: `NearHoldTests.swift` (suite "Near hold").
//

import Foundation

/// The numbers behind `NearHold`. Pinned by `NearHoldTests.defaultsAreTheDesign`.
public struct NearHoldConfig: Sendable, Equatable {
    /// A cell whose blind share is at least this is "too close to read", not empty.
    public var blindFraction: Float = 0.5
    /// The last measured distance must have been under this for a blind cell to be held: the
    /// walker was already at the wall. Above `LaneConfig.closeOverrideThreshold` (0.35) on purpose
    /// — a normal step brings a 0.5 m reading straight into the blind zone.
    public var armBelowM: Float = 0.6
    /// The distance a held cell reports: point-blank, under `CueThresholds.centerNear` (0.5 m).
    public var pointBlankM: Float = 0.1
    /// Cold start: this many of the six cells blind with no history at all → caution.
    public var coldStartMinCells = 4
    /// Cold start: a cell counts only when at least this blind (a wall against the lens is ~1.0).
    public var coldStartBlindFraction: Float = 0.8
    /// What a cold-start cell reports: NEAR (Geiger, orange tile), never STOP — the walker may be
    /// looking at the sky through a phone that has not measured anything yet.
    public var coldStartM: Float = 0.8
    /// Creates the design defaults (0.5 / 0.6 m / 0.1 m; cold start 4 cells / 0.8 / 0.8 m).
    public init() {}
}

/// Per-cell memory of the last measured distance, and the hold decision. Six cells: head then
/// torso, left / centre / right.
public struct NearHold: Sendable, Equatable {
    /// The numbers; may be changed between frames.
    public var config: NearHoldConfig
    /// Last finite distance each cell measured (head 0…2, torso 3…5); nil before the first.
    private var lastMeasured: [Float?] = Array(repeating: nil, count: 6)

    /// - Parameter config: the numbers (default: the design).
    public init(config: NearHoldConfig = NearHoldConfig()) { self.config = config }

    /// Forget every cell (a depth session reset, "Both cameras"). Keeps `config`.
    public mutating func reset() { lastMeasured = Array(repeating: nil, count: 6) }

    /// Apply the rule to one frame's grid: returns the grid with blind-after-near cells replaced
    /// by `pointBlankM` (or cold-start cells by `coldStartM`) and flagged in `headHeld` /
    /// `torsoHeld`; remembers every measured cell.
    /// - Parameters:
    ///   - grid: the grid `LaneMath.computeLanes` produced for this frame.
    ///   - trusted: `LaneReport.isTrusted` — false while the cane sweeps: every cell is disarmed
    ///     and nothing is held (the history belongs to another view).
    /// Pinned by `blindAfterNearReadingIsPointBlank`, `blindWithoutNearHistoryStaysClear`,
    /// `anyMeasurementReleasesTheHold`, `blindShareUnderThresholdReleases`, `farReadingDoesNotArm`,
    /// `allBlindWithNoHistoryIsCaution`, `headOnlyBlindIsNotAColdStart`, `aSweepDisarmsEveryCell`.
    public mutating func apply(_ grid: LaneGrid, trusted: Bool = true) -> LaneGrid {
        var out = grid
        if !trusted {
            lastMeasured = Array(repeating: nil, count: 6)
            return out
        }
        // Cold start: no cell has history and most of the covered frame is blind → caution, not silence.
        let noHistory = lastMeasured.allSatisfy { $0 == nil }
        if noHistory {
            var blindCells: [(Int, Int)] = []
            for band in 0..<2 {
                for lane in 0..<3 {
                    let covered = band == 0 ? grid.headCoverage[lane] : grid.torsoCoverage[lane]
                    guard covered else { continue }
                    let value = band == 0 ? grid.head[lane] : grid.torso[lane]
                    let blind = band == 0 ? grid.headBlind[lane] : grid.torsoBlind[lane]
                    if !value.isFinite, blind >= config.coldStartBlindFraction { blindCells.append((band, lane)) }
                }
            }
            let coveredCells = grid.headCoverage.filter { $0 }.count + grid.torsoCoverage.filter { $0 }.count
            let needed = min(config.coldStartMinCells, coveredCells)
            if needed > 0, blindCells.count >= needed {
                for (band, lane) in blindCells {
                    if band == 0 { out.head[lane] = config.coldStartM; out.headHeld[lane] = true }
                    else { out.torso[lane] = config.coldStartM; out.torsoHeld[lane] = true }
                }
                return out                                   // history stays empty: any measurement ends it
            }
        }
        for band in 0..<2 {
            for lane in 0..<3 {
                let covered = band == 0 ? grid.headCoverage[lane] : grid.torsoCoverage[lane]
                guard covered else { continue }
                let i = band * 3 + lane
                let value = band == 0 ? grid.head[lane] : grid.torso[lane]
                let blind = band == 0 ? grid.headBlind[lane] : grid.torsoBlind[lane]
                if value.isFinite {
                    lastMeasured[i] = value                      // measured: remember, never hold
                    continue
                }
                let armed = (lastMeasured[i] ?? .infinity) < config.armBelowM
                let hold = armed && blind >= config.blindFraction
                if hold {
                    if band == 0 { out.head[lane] = config.pointBlankM; out.headHeld[lane] = true }
                    else { out.torso[lane] = config.pointBlankM; out.torsoHeld[lane] = true }
                } else if blind < config.blindFraction {
                    lastMeasured[i] = nil                        // a real clear disarms the cell
                }
            }
        }
        return out
    }
}
