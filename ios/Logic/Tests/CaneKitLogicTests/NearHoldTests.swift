//
//  NearHoldTests.swift
//  CaneKitLogicTests
//
//  Pins NearHold.swift (Step 48): a lane cell that goes blind (0 / NaN / ≤ 5 cm samples) right
//  after a near reading is a point-blank obstacle, not a clear path; a blind cell with no near
//  history stays clear; any measurement or a real clear releases the hold. Distances metres.
//
//  Breaks these catch: the teammate's photo — six green CLEAR tiles with the phone against a wall
//  — and the opposite failure, a STOP painted over the sky or a long corridor nobody walked up to.
//

import CaneKitLogic
import Foundation
import Testing

/// A grid with one interesting cell (torso centre) and everything else at 4 m, fully measured.
private func grid(torsoCentre: Float, blind: Float = 0) -> LaneGrid {
    LaneGrid(head: [4, 4, 4], torso: [4, torsoCentre, 4], centerDepth: 4,
             headBlind: [0, 0, 0], torsoBlind: [0, blind, 0])
}

@Suite("Near hold")
struct NearHoldTests {

    @Test("a blind cell right after a near reading is point-blank, flagged as held")
    func blindAfterNearReadingIsPointBlank() {
        var hold = NearHold()
        _ = hold.apply(grid(torsoCentre: 0.9))
        _ = hold.apply(grid(torsoCentre: 0.4))                 // the walker reaches the wall
        let held = hold.apply(grid(torsoCentre: .infinity, blind: 0.9))   // LiDAR saturates
        #expect(held.torso[1] == 0.1)
        #expect(held.torsoHeld[1])
        #expect(held.torso[0] == 4 && !held.torsoHeld[0])      // neighbours untouched
        #expect(TileLevel.level(for: held.torso[1], hasData: true) == .urgent)
    }

    @Test("a blind cell with no near history stays clear (sky, a long corridor)")
    func blindWithoutNearHistoryStaysClear() {
        var hold = NearHold()
        let g = hold.apply(grid(torsoCentre: .infinity, blind: 1.0))
        #expect(g.torso[1] == .infinity)
        #expect(!g.torsoHeld[1])
    }

    @Test("a far reading before the blind frame does not arm the hold")
    func farReadingDoesNotArm() {
        var hold = NearHold()
        _ = hold.apply(grid(torsoCentre: 2.0))
        let g = hold.apply(grid(torsoCentre: .infinity, blind: 1.0))
        #expect(g.torso[1] == .infinity)
    }

    @Test("any measurement releases the hold and becomes the new memory")
    func anyMeasurementReleasesTheHold() {
        var hold = NearHold()
        _ = hold.apply(grid(torsoCentre: 0.3))
        #expect(hold.apply(grid(torsoCentre: .infinity, blind: 0.8)).torsoHeld[1])
        let back = hold.apply(grid(torsoCentre: 1.5))          // the walker steps back
        #expect(back.torso[1] == 1.5 && !back.torsoHeld[1])
        // 1.5 m is not near, so a later blind frame is not held.
        #expect(!hold.apply(grid(torsoCentre: .infinity, blind: 0.8)).torsoHeld[1])
    }

    @Test("a blind share under the threshold is a real clear and disarms the cell")
    func blindShareUnderThresholdReleases() {
        var hold = NearHold()
        _ = hold.apply(grid(torsoCentre: 0.3))
        let clear = hold.apply(grid(torsoCentre: .infinity, blind: 0.2))   // too few samples, not blind
        #expect(clear.torso[1] == .infinity && !clear.torsoHeld[1])
        // Disarmed: even a fully blind frame now stays clear until something near is measured.
        #expect(!hold.apply(grid(torsoCentre: .infinity, blind: 1.0)).torsoHeld[1])
    }

    @Test("switched on against a wall: most cells blind, no history → NEAR caution, never silence")
    func allBlindWithNoHistoryIsCaution() {
        var hold = NearHold()
        let g = hold.apply(LaneGrid(head: [.infinity, .infinity, .infinity], torso: [.infinity, .infinity, 4],
                                    centerDepth: .infinity, headBlind: [1, 1, 0.95], torsoBlind: [0.9, 1, 0]))
        #expect(g.head == [0.8, 0.8, 0.8] && g.torso[0] == 0.8 && g.torso[1] == 0.8)
        #expect(g.torso[2] == 4 && !g.torsoHeld[2])
        #expect(TileLevel.level(for: 0.8, hasData: true) == .near)    // orange, not STOP
        // The first real measurement ends the cold start and starts normal history.
        let next = hold.apply(grid(torsoCentre: 0.3))
        #expect(next.torso[1] == 0.3 && !next.torsoHeld[1])
    }

    @Test("a head-only blind (a tilt up at the sky) is not a cold start")
    func headOnlyBlindIsNotAColdStart() {
        var hold = NearHold()
        let g = hold.apply(LaneGrid(head: [.infinity, .infinity, .infinity], torso: [3, 3, 3],
                                    centerDepth: 3, headBlind: [1, 1, 1], torsoBlind: [0, 0, 0]))
        #expect(g.head == [.infinity, .infinity, .infinity] && !g.headHeld.contains(true))
    }

    /// Step 51: at the cane's natural 45° the head band is uncovered (`.infinity`, blind 0, flag
    /// false), so only the three torso cells can be blind. The cold start needs
    /// `min(coldStartMinCells, covered cells)` = 3 of them; counting all six would ask for 4 of 3
    /// and a phone switched on against a wall on the cane would never show caution. An uncovered
    /// cell never counts, even if it reports blind.
    @Test("cold start counts only covered cells (45° mount: three torso cells are enough)")
    func coldStartCountsOnlyCoveredCells() {
        var hold = NearHold()
        let steep = LaneGrid(head: [.infinity, .infinity, .infinity], torso: [.infinity, .infinity, .infinity],
                             centerDepth: .infinity, headBlind: [0, 0, 0], torsoBlind: [1, 1, 0.9],
                             headCoverage: [false, false, false], bandMode: .metric)
        let g = hold.apply(steep)
        #expect(g.torso == [0.8, 0.8, 0.8] && g.torsoHeld == [true, true, true])
        #expect(g.head == [.infinity, .infinity, .infinity] && !g.headHeld.contains(true))
        #expect(g.headCoverage == [false, false, false])            // flags pass through

        // The same three blind torso cells with the head band covered (and clear) are 3 of 6:
        // today's rule, no cold start.
        var covered = NearHold()
        let flat = covered.apply(LaneGrid(head: [.infinity, .infinity, .infinity], torso: [.infinity, .infinity, .infinity],
                                          centerDepth: .infinity, headBlind: [0, 0, 0], torsoBlind: [1, 1, 0.9]))
        #expect(!flat.torsoHeld.contains(true))

        // Uncovered cells reporting blind do not count toward the cold start.
        var ghost = NearHold()
        let g2 = ghost.apply(LaneGrid(head: [.infinity, .infinity, .infinity], torso: [.infinity, 3, 3],
                                      centerDepth: 3, headBlind: [1, 1, 1], torsoBlind: [1, 0, 0],
                                      headCoverage: [false, false, false], bandMode: .metric))
        #expect(!g2.torsoHeld.contains(true) && !g2.headHeld.contains(true))
    }

    @Test("a sweep (untrusted frame) disarms every cell")
    func aSweepDisarmsEveryCell() {
        var hold = NearHold()
        _ = hold.apply(grid(torsoCentre: 0.3))
        _ = hold.apply(grid(torsoCentre: .infinity, blind: 1.0), trusted: false)   // swinging
        #expect(!hold.apply(grid(torsoCentre: .infinity, blind: 1.0)).torsoHeld[1])
    }

    @Test("reset forgets the near history")
    func resetForgetsHistory() {
        var hold = NearHold()
        _ = hold.apply(grid(torsoCentre: 0.3))
        hold.reset()
        #expect(!hold.apply(grid(torsoCentre: .infinity, blind: 1.0)).torsoHeld[1])
    }

    @Test("defaults are the design: 50 % blind, armed under 0.6 m, reports 0.1 m")
    func defaultsAreTheDesign() {
        let c = NearHoldConfig()
        #expect(c.blindFraction == 0.5)
        #expect(c.armBelowM == 0.6)
        #expect(c.pointBlankM == 0.1)
        #expect(c.pointBlankM < CueThresholds().centerNear)   // held = urgent, never "near"
        #expect(c.coldStartMinCells == 4 && c.coldStartBlindFraction == 0.8 && c.coldStartM == 0.8)
        #expect(c.coldStartM >= CueThresholds().centerNear)    // cold start = near, never urgent
    }
}
