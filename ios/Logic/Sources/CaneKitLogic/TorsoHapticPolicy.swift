//
//  TorsoHapticPolicy.swift
//  CaneKitLogic
//
//  What the cane does for a torso obstacle (centre / left / right lane) at each Cue detail level ×
//  place, layered over `CueDecider`. The decider still decides *which* lane is active and *when*
//  (hysteresis, priority, gates — its tests pin today's decisions untouched); this policy decides
//  whether that decision is rendered at the walker's level. Cue design v2, Step 41
//  (docs/cue_design_v2.md §3.3 and §4 row 9; docs/design.md §5.2 "by level").
//
//  Why: with obstacle names off (the default since Step 36) the three levels were indistinguishable
//  outdoors — `CueRules` gated only names and sign phrases, and the Settings caption said "Haptics
//  are the same at every level for now." The owner: "I'm not sure if it's actually making a
//  difference." Blind travellers are consistent that an aid must not repeat what the cane tip
//  already finds (research P1, P3, P7): the tip covers torso obstacles, so a calmer level taps for
//  them less, or not at all.
//
//  The rules (all numbers in `TorsoHapticThresholds`, metres / seconds):
//    · Head cue: rendered at every level, place and hold — the safety floor (AGENTS.md hard rule 8).
//      This file never returns anything but `.render(.head)` for it.
//    · Quiet: no torso haptics (the centre Geiger loop and the side taps are suppressed).
//    · Standard: centre lane = two onset taps and no loop — one tap when the centre distance is
//      < 1.5 m *and closing*, one strong triple when < 0.6 m (closing or not: a walker inching in
//      at under 0.1 m/s must still be told something is within reach — Muse review, Step 47);
//      each level once per approach, both re-armed after 1.5 s of clear (a decider `.stop`, or
//      the centre ceding to a side lane); no repeat while the distance holds. Side lanes: nothing.
//    · Detailed: today's loop and side taps, plus shoreline suppression — a side tap is dropped
//      while that side's distance has held within ±0.1 m for ≥ 2 s (the walker is trailing a wall
//      or hedge, not approaching anything).
//    · Indoors (any level) and a crossing settle (the walker standing at a curb, Standard and
//      Detailed): no torso haptics.
//    · "Closing" = the centre distance is ≥ 0.1 m less than it was ≥ 1 s ago, judged over trusted
//      frames only (the decider already freezes on untrusted, sweeping frames; a sweep's smeared
//      depth must not count as history either).
//    · A Geiger loop the walker is already feeling is stopped the moment a hold begins (a level or
//      place change mid-approach, reaching a crossing fence): the first held centre update comes
//      back as `.suppressed`, so the app calls `stopAll()`; later held updates return nil.
//
//  Pure: Foundation-only, no clock (the caller passes `now`, the report's AR timestamp, which must
//  not go backwards within one policy's life). Value type; not shared between actors.
//  Owner: `AppModel.torsoPolicy` (main actor) — `update` in `handle(_:)` right after
//  `decider.update`, with `rules: cueRules` and `crossingSettle: nav.isCrossingSettle`; `reset()`
//  wherever the decider is reset (background, "Both cameras") and in `applyCueRules` (a level or
//  place change). The app maps the action to `HapticPlayer` (`play`, `playCenterOnset(strong:)`,
//  `setApproach`, `stopAll`), the watch mirror, `CueSpeechPolicy` and the `cue` trip-log record
//  (`suppressed: <reason>` / `render: center_onset | center_strong`, read by `ios/scripts/cue_audit.py`).
//  Tests: `TorsoHapticPolicyTests.swift` (suite "Torso haptics by level") and
//  `CueProfileTests.defaultRulesRenderTodaysHaptics`.
//

import Foundation

/// Why a torso cue the decider fired was not rendered. ⚠ Raw values are the `suppressed` field of
/// the trip log's `cue` record and are counted by `ios/scripts/cue_audit.py` — never rename them
/// (`thresholdDefaultsAreTheDesign` pins the list).
public enum TorsoSuppressReason: String, Sendable, Equatable, CaseIterable {
    /// Cue detail Quiet: the cane tip covers torso obstacles.
    case quiet
    /// Place Indoors: no torso taps at any level (Step 36 indoor overrides).
    case indoors
    /// The walker is settling at a street crossing (`NavigationEngine.isCrossingSettle`).
    case crossingSettle = "crossing_settle"
    /// Standard renders no side taps.
    case standardSide = "standard_side"
    /// Standard: the centre lane is in range but no onset is due (not yet under 1.5 m, not
    /// closing, or this approach's onsets already fired). Logged once per decider fire, so the
    /// audit can see an approach that never tapped.
    case standardCenterHold = "standard_center_hold"
    /// Detailed: the side distance has held within ±0.1 m for ≥ 2 s — a wall or hedge being trailed.
    case shoreline
}

/// What the phone should render for one decider output at the walker's level. `AppModel.handle`
/// maps each case; nil from `update` means "nothing to do" (no decider output, or a held update).
public enum TorsoHapticAction: Sendable, Equatable {
    /// Render the cue exactly as the decider fired it (`HapticPlayer.play`): the head cue always,
    /// torso cues in Detailed.
    case render(HapticCue)
    /// Standard: one onset pattern for the centre lane (`HapticPlayer.playCenterOnset(strong:)`);
    /// `strong` = the triple under 0.6 m. `distance` (m, the report's centre reading) feeds the
    /// haptics-down speech fallback ("<distance> ahead.") and the trip log.
    case centerOnset(strong: Bool, distance: Float)
    /// Detailed: the centre loop is running and only its distance changed (`setApproach`).
    case updateCenter(distance: Float)
    /// The decider's `.stop`: stop any loop, end the speech episode. Passed through at every level.
    case stop
    /// The decider fired (or, for a loop that must stop, updated) a torso cue this level, place or
    /// moment does not render: stop the player, mirror and speak nothing, log the reason.
    case suppressed(HapticCue, reason: TorsoSuppressReason)
}

/// The numbers behind `TorsoHapticPolicy` (metres / seconds). Defaults are the approved design
/// (docs/cue_design_v2.md §3.3); [H] = research hypothesis until a mounted trip log tunes it.
/// Pinned by `thresholdDefaultsAreTheDesign`.
public struct TorsoHapticThresholds: Sendable, Equatable {
    /// Standard: the single onset tap fires once the centre distance is under this and closing.
    public var onsetNearM: Float = 1.5
    /// Standard: the strong triple fires once the centre distance is under this (closing or not).
    public var onsetStrongM: Float = 0.6
    /// "Closing": the centre distance must be at least this much less than `closingWindowS` ago.
    public var closingDeltaM: Float = 0.1
    /// How far back the closing comparison looks (the newest trusted sample at least this old).
    public var closingWindowS: TimeInterval = 1.0
    /// Standard: seconds of clear (decider `.stop`, or the centre ceding to a side lane) before
    /// both onsets re-arm for a new approach.
    public var rearmClearS: TimeInterval = 1.5
    /// Detailed shoreline: every side sample in the window must be within ± this of the current
    /// reading for the tap to be suppressed.
    public var shorelineBandM: Float = 0.1
    /// Detailed shoreline: the side distance must have held for at least this long.
    public var shorelineWindowS: TimeInterval = 2.0
    /// Creates the design defaults (1.5 / 0.6 / 0.1 m, 1.0 / 1.5 s, 0.1 m, 2.0 s).
    public init() {}
}

/// Level × place × moment → what to render for the decider's torso decisions. One per app,
/// stepped once per depth report right after `CueDecider.update`.
public struct TorsoHapticPolicy: Sendable, Equatable {

    /// One trusted lane reading: the report's AR timestamp and the lane distance (m; non-finite =
    /// no return, kept so a dropout breaks a shoreline and never counts as closing).
    private struct Sample: Sendable, Equatable {
        var t: TimeInterval
        var d: Float
    }

    /// The numbers; may be changed between updates.
    public var thresholds: TorsoHapticThresholds

    /// Recent trusted centre readings, oldest first (the closing history).
    private var centerSamples: [Sample] = []
    /// Recent trusted left-lane readings, oldest first (shoreline history).
    private var leftSamples: [Sample] = []
    /// Recent trusted right-lane readings, oldest first (shoreline history).
    private var rightSamples: [Sample] = []
    /// Standard: the 1.5 m onset has fired for the current approach.
    private var nearFired = false
    /// Standard: the 0.6 m strong onset has fired for the current approach.
    private var strongFired = false
    /// When the centre lane stopped being the decider's cue (a `.stop`, or a side fire); nil while
    /// the centre is active. The onsets re-arm once `now − centerClearSince ≥ rearmClearS`.
    private var centerClearSince: TimeInterval?
    /// A Geiger loop was rendered (`.render(.centerApproach)` / `.updateCenter`) and has not been
    /// stopped by a `.stop` or a `.suppressed` since — a hold must stop it explicitly.
    private var centerLoopRendered = false

    /// - Parameter thresholds: the numbers (default: the design).
    public init(thresholds: TorsoHapticThresholds = TorsoHapticThresholds()) {
        self.thresholds = thresholds
    }

    /// Forget every reading, arm both onsets and assume no loop is running. Called wherever the
    /// app resets `CueDecider` (background, "Both cameras") and on a level or place change
    /// (`applyCueRules`, which also stops the player). Keeps `thresholds`.
    /// Pinned by `resetForgetsHistoryAndArming`.
    public mutating func reset() {
        centerSamples.removeAll()
        leftSamples.removeAll()
        rightSamples.removeAll()
        nearFired = false
        strongFired = false
        centerClearSince = nil
        centerLoopRendered = false
    }

    /// Step the policy over one report and the decider's output for it.
    /// - Parameters:
    ///   - output: what `CueDecider.update` returned for `report` (nil = nothing new).
    ///   - report: the same report; trusted frames feed the closing / shoreline histories.
    ///   - rules: the walker's level × place (`AppModel.cueRules`).
    ///   - crossingSettle: the walker is settling at a street crossing (`NavigationEngine.isCrossingSettle`).
    ///   - now: seconds, the report's AR timestamp (the decider's clock; never wall time).
    /// - Returns: the action to render, or nil for nothing (no output, or a held loop update).
    /// Pinned by every test in `TorsoHapticPolicyTests.swift`.
    public mutating func update(_ output: CueOutput?, report: LaneReport, rules: CueRules,
                                crossingSettle: Bool, now: TimeInterval) -> TorsoHapticAction? {
        if report.depthAvailable, report.isTrusted { record(report, now: now) }
        guard let output else { return nil }
        // A point-blank hold (`NearHold`, a wall against the phone) renders at every level and
        // place, like the head cue: Quiet or Indoors must not turn a held cell back into silence
        // (Muse review, Step 48). Pinned by `pointBlankBypassesEveryTorsoHold`.
        if case .fire(let cue) = output, cue.kind != .head, report.grid.torsoHeld.contains(true) {
            centerLoopRendered = cue.kind == .center
            return .render(cue)
        }
        if case .updateCenter = output, report.grid.torsoHeld[1] {
            centerLoopRendered = true
            if case .updateCenter(let d) = output { return .updateCenter(distance: d) }
        }

        switch output {
        case .stop:
            centerLoopRendered = false
            if centerClearSince == nil { centerClearSince = now }
            return .stop

        case .fire(.head(let d, let onset)):
            // The safety floor: never gated, payload (distance, onset) passed through unchanged so
            // `CueSpeechPolicy` still knows an onset from a band re-fire (Step 52).
            return .render(.head(distance: d, onset: onset))

        // Every `HapticCue` case is named here on purpose (review, Step 47): a cue kind added later
        // must fail to compile, not fall into the centre logic by way of a catch-all.
        case .fire(.left):
            return side(.left, report: report, rules: rules, crossingSettle: crossingSettle, now: now)
        case .fire(.right):
            return side(.right, report: report, rules: rules, crossingSettle: crossingSettle, now: now)
        case .fire(.centerApproach(let d)):
            return center(deciderCue: .centerApproach(distance: d), isFire: true, report: report,
                          rules: rules, crossingSettle: crossingSettle, now: now)

        case .updateCenter(let d):
            return center(deciderCue: .centerApproach(distance: d), isFire: false, report: report,
                          rules: rules, crossingSettle: crossingSettle, now: now)
        }
    }

    // MARK: Side lanes (decision)

    /// A side lane is the decider's cue: the centre must be clear (it outranks the sides), so the
    /// re-arm clock starts; then the hold check, then the level's rule (Standard: never; Detailed:
    /// unless shorelining).
    private mutating func side(_ cue: HapticCue, report: LaneReport, rules: CueRules,
                               crossingSettle: Bool, now: TimeInterval) -> TorsoHapticAction {
        if centerClearSince == nil { centerClearSince = now }
        centerLoopRendered = false                       // the decider left the centre cue
        if let hold = holdReason(rules: rules, crossingSettle: crossingSettle) {
            return .suppressed(cue, reason: hold)
        }
        switch rules.level {
        case .quiet: return .suppressed(cue, reason: .quiet)       // unreachable: holdReason covers it
        case .standard: return .suppressed(cue, reason: .standardSide)
        case .detailed:
            let d = cue.kind == .left ? report.torso[0] : report.torso[2]
            let history = cue.kind == .left ? leftSamples : rightSamples
            return isShoreline(history, current: d, now: now) ? .suppressed(cue, reason: .shoreline) : .render(cue)
        }
    }

    // MARK: Centre lane

    /// The centre lane is the decider's cue (a fire or a loop update): re-arm bookkeeping, then the
    /// hold check, then the level's rule. `deciderCue` carries the decider's (floored) distance for
    /// `.render` / `.updateCenter` / `.suppressed`; the report's own centre reading drives the
    /// Standard onsets.
    private mutating func center(deciderCue: HapticCue, isFire: Bool, report: LaneReport, rules: CueRules,
                                 crossingSettle: Bool, now: TimeInterval) -> TorsoHapticAction? {
        if let since = centerClearSince {
            if now - since >= thresholds.rearmClearS {
                nearFired = false
                strongFired = false
            }
            centerClearSince = nil
        }
        if let hold = holdReason(rules: rules, crossingSettle: crossingSettle) {
            // Log the fire once; stop a loop the walker is feeling; say nothing for later updates.
            guard isFire || centerLoopRendered else { return nil }
            centerLoopRendered = false
            return .suppressed(deciderCue, reason: hold)
        }
        switch rules.level {
        case .quiet:                                     // unreachable: holdReason covers it
            centerLoopRendered = false
            return .suppressed(deciderCue, reason: .quiet)
        case .detailed:
            centerLoopRendered = true
            if isFire { return .render(deciderCue) }
            if case .centerApproach(let d) = deciderCue { return .updateCenter(distance: d) }
            return nil
        case .standard:
            // A loop left over from Detailed (level changed mid-approach) is stale: the onset
            // player stops it, and a hold reports it so the app stops it.
            let staleLoop = centerLoopRendered
            centerLoopRendered = false
            let d = report.torso[1]
            // The strong triple needs proximity only: at < 0.6 m the walker's next step is the
            // obstacle, however slowly they got there (`standardStrongTripleFiresOnASlowCreep`).
            // The carried distance is floored like the decider's (`CueThresholds.centerNear`),
            // so the spoken fallback stays inside the prefetched approach lines (Codex review).
            let floor = CueThresholds().centerNear
            if d.isFinite, d < thresholds.onsetStrongM, !strongFired {
                strongFired = true
                nearFired = true
                return .centerOnset(strong: true, distance: max(d, floor))
            }
            if d.isFinite, d < thresholds.onsetNearM, !nearFired, isClosing(d, now: now) {
                nearFired = true
                return .centerOnset(strong: false, distance: max(d, floor))
            }
            return (isFire || staleLoop) ? .suppressed(deciderCue, reason: .standardCenterHold) : nil
        }
    }

    /// Standard's closing test: the newest trusted centre sample at least `closingWindowS` old is
    /// finite and at least `closingDeltaM` farther than `d`. No history (a fresh start, a reset) or
    /// a non-finite reference (the obstacle stepped in from the side) is not closing.
    private func isClosing(_ d: Float, now: TimeInterval) -> Bool {
        guard d.isFinite,
              let ref = centerSamples.last(where: { now - $0.t >= thresholds.closingWindowS })?.d,
              ref.isFinite else { return false }
        return ref - d >= thresholds.closingDeltaM
    }

    // MARK: Side lanes

    /// Detailed's shoreline test: the history covers at least `shorelineWindowS` and every sample
    /// inside the window is finite and within ± `shorelineBandM` of `current`. A dropout or a
    /// change of more than the band anywhere in the window means the tap renders.
    private func isShoreline(_ history: [Sample], current d: Float, now: TimeInterval) -> Bool {
        guard d.isFinite, history.contains(where: { now - $0.t >= thresholds.shorelineWindowS }) else { return false }
        return history.allSatisfy { s in
            now - s.t > thresholds.shorelineWindowS || (s.d.isFinite && abs(s.d - d) <= thresholds.shorelineBandM)
        }
    }

    /// True while every torso cue is held (Quiet, Indoors, or a crossing settle) — `holdReason`
    /// as a Bool for the app: when a head cue fires under a hold, `AppModel.handle` stops a centre
    /// loop that may still be running (a head fire outranks the centre, so no centre update arrives
    /// to end it — Codex review, Step 47). Pinned by `torsoIsHeldNamesEveryHold`.
    public func torsoIsHeld(rules: CueRules, crossingSettle: Bool) -> Bool {
        holdReason(rules: rules, crossingSettle: crossingSettle) != nil
    }

    // MARK: Holds and history

    /// A reason every torso cue is held right now, or nil: Quiet, Indoors, or a crossing settle.
    /// Quiet and Indoors come first (they are the walker's standing choice), then the moment.
    private func holdReason(rules: CueRules, crossingSettle: Bool) -> TorsoSuppressReason? {
        if rules.level == .quiet { return .quiet }
        if rules.place == .indoors { return .indoors }
        if crossingSettle { return .crossingSettle }
        return nil
    }

    /// Append this trusted frame's three torso readings and drop samples older than the longest
    /// window plus half a second (the covering sample must survive the prune).
    private mutating func record(_ report: LaneReport, now: TimeInterval) {
        let keep = max(thresholds.closingWindowS, thresholds.shorelineWindowS) + 0.5
        func push(_ samples: inout [Sample], _ d: Float) {
            samples.append(Sample(t: now, d: d))
            // `removeAll`, not "drop up to the first kept": after a clock gap (an AR session that
            // paused without a reset) every old sample is stale, and a prune keyed on the first
            // kept index left them all in place — an ancient 2 m reading then served as the
            // closing reference for a false onset (OpenCode review, Step 47;
            // `staleHistoryIsPrunedAfterAGap`).
            samples.removeAll { now - $0.t > keep }
        }
        push(&leftSamples, report.torso[0])
        push(&centerSamples, report.torso[1])
        push(&rightSamples, report.torso[2])
    }
}
