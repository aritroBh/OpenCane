//
//  IndoorRouteTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins IndoorRoute.swift (Step 62) — the indoor step script a blind walker follows from a
//  room to the building's exit door before the outdoor GPS route takes over: its file schema and
//  validation (`IndoorScript`), the pedometer-driven step machine (`IndoorProgress`), the GPS
//  handover gate (`IndoorHandover`) and the recording mode a sighted teammate walks once
//  (`IndoorRecorder`).
//
//  Breaks these catch: a step that advances only after the full count (the walker's stride is
//  shorter than the recorder's, so the turn is announced after it); drift, where every early advance
//  shortens the next step; a landmark said twice or never; a pedometer jump read out as a paragraph;
//  steps counted after the exit restarting the script; a handover on one indoor multipath fix, or a
//  handover that never comes after "I'm outside"; a recorder that makes a new step out of a head
//  turn or cane jitter, calls a U-turn "left", or loses a landmark.
//  Callers of the pinned code: `IndoorGuide` (app, Step 62 — `IndoorProgress`, `IndoorHandover`,
//  `IndoorScript.load`), the Settings "Record indoor route" card (`IndoorRecorder`).
//  Pure Foundation, runs on Linux CI too. Mutating calls are hoisted out of `#expect` / `#require`
//  into `_hoistedN` locals (Package.swift: a mutating call inside the macro does not compile).
//
//  Key fixtures:
//    · `script()` — three steps: 10 steps with a landmark (advance at 9, landmark at 7), 20 steps
//      turning right (advance at 10 + 17 = 27), 6 steps turning left with a landmark (landmark at
//      30 + 5 = 35, exit at 30 + 6 = 36).
//    · `fourLegs()` — four plain 10-step legs for the jump tests.
//    · `exitPoint` — route_isr_cif.json WP1 (the ISR south vestibule), radius 25 m; `north(m)` moves
//      a point by exact metres so every handover distance is exact.
//    · `Trace` — a synthetic recording walk: a yaw sample every 0.5 s and a pedometer update every
//      two steps (0.5 s per step), like CMDeviceMotion + CMPedometer on the phone.
//

import Foundation
import Testing
@testable import CaneKitLogic

// MARK: - Fixtures

private let s0 = "Walk straight about 10 steps."
private let lm0 = "The lab is on your left."
private let s1 = "Turn right. Walk about 20 steps."
private let s2 = "Turn left. Walk about 6 steps."
private let lm2 = "The front doors are ahead."
private let exitLine = "You are at the ISR front doors. Go outside and wait a moment for GPS."

/// route_isr_cif.json WP1, the handover point.
private let exitPoint = Coordinate(latitude: 40.10949, longitude: -88.22135)

/// `exitPoint` moved `m` metres north (negative = south).
private func north(_ m: Double) -> Coordinate {
    Coordinate(latitude: exitPoint.latitude + m / 111_195, longitude: exitPoint.longitude)
}

private func script(walked: Bool = true, steps: [IndoorStep]? = nil) -> IndoorScript {
    IndoorScript(id: "isr_lab_to_front_doors", name: "ISR lab to the front doors",
                 fromAliases: ["ISR", "the lab"], outdoorPlaceID: "isr", walked: walked,
                 recordedAt: walked ? "2026-09-13" : nil, strideM: nil,
                 steps: steps ?? [
                    IndoorStep(say: s0, steps: 10, turn: .none, landmark: lm0),
                    IndoorStep(say: s1, steps: 20, turn: .right),
                    IndoorStep(say: s2, steps: 6, turn: .left, landmark: lm2),
                 ],
                 exit: IndoorExit(say: exitLine, lat: exitPoint.latitude, lon: exitPoint.longitude, radiusM: 25))
}

/// Four plain 10-step legs (no landmarks): advances at 9, 19, 29, exit at 39 (nominal boundaries 10, 20, 30).
private func fourLegs() -> IndoorScript {
    script(steps: (1...4).map { IndoorStep(say: "Leg \($0).", steps: 10) })
}

private func says(_ events: [IndoorEvent]) -> [String] {
    events.compactMap { if case .say(let s) = $0 { return s } else { return nil } }
}

// MARK: - IndoorScript

/// The numbers the script and the machine are built on.
@Test func indoorNumbersArePinned() {
    #expect(IndoorScript.defaultStrideM == 0.7)
    #expect(IndoorScript.defaultRadiusM == 25)
    #expect(IndoorScript.radiusRangeM == 10...60)
    #expect(IndoorScript.maxSayCharacters == 140)
    #expect(IndoorProgress.advanceFraction == 0.85)
    #expect(IndoorProgress.landmarkFraction == 0.7)
    #expect(IndoorProgress.maxJumpLines == 2)
    #expect(IndoorProgress.notWalkedLine
            == "Draft route. Use your cane.")
}

/// A hand-written draft may leave out `turn` (→ none), `steps`, `landmark` and the exit radius (→ 25).
@Test func indoorScriptDecodesWithDefaults() throws {
    let json = """
    {"id": "d", "name": "Draft", "fromAliases": ["ISR"], "outdoorPlaceID": "isr", "walked": false,
     "steps": [{"say": "Walk down the corridor.", "steps": 12}, {"say": "Go through the doors."}],
     "exit": {"say": "You are at the doors.", "lat": 40.10949, "lon": -88.22135}}
    """
    let s = try IndoorScript.load(from: Data(json.utf8))
    #expect(s.steps[0].turn == .none && s.steps[0].steps == 12 && s.steps[0].landmark == nil)
    #expect(s.steps[1].steps == nil)
    #expect(s.exit.radiusM == 25)
    #expect(s.recordedAt == nil && s.strideM == nil)
    #expect(s.stride == 0.7)
    #expect(s.validate().isEmpty)
    // Round trip through the encoder the recorder saves with.
    #expect(try IndoorScript.load(from: JSONEncoder().encode(s)) == s)
}

/// Validation names every problem: empty steps, a non-positive count, a radius outside 10–60 m,
/// a line over 140 characters, no aliases. The edges (10, 60, 140) are allowed.
@Test func indoorScriptValidationCatchesBadScripts() {
    #expect(script().validate().isEmpty)

    var empty = script(); empty.steps = []
    #expect(empty.validate().count == 1)

    var zero = script(); zero.steps[1].steps = 0
    #expect(zero.validate().count == 1)
    var negative = script(); negative.steps[1].steps = -3
    #expect(negative.validate().count == 1)

    for (r, ok) in [(9.9, false), (10.0, true), (60.0, true), (60.1, false)] {
        var s = script(); s.exit.radiusM = r
        #expect(s.validate().isEmpty == ok, "radius \(r)")
    }

    var long = script(); long.steps[0].say = String(repeating: "a", count: 141)
    #expect(long.validate().count == 1)
    var edge = script(); edge.steps[0].say = String(repeating: "a", count: 140)
    #expect(edge.validate().isEmpty)
    var longLandmark = script(); longLandmark.steps[0].landmark = String(repeating: "a", count: 141)
    #expect(longLandmark.validate().count == 1)
    var longExit = script(); longExit.exit.say = String(repeating: "a", count: 141)
    #expect(longExit.validate().count == 1)

    var noAliases = script(); noAliases.fromAliases = []
    #expect(noAliases.validate().count == 1)
    var blankAlias = script(); blankAlias.fromAliases = ["  "]
    #expect(blankAlias.validate().count == 1)
}

/// The bundled ISR draft (ios/CaneKit/Resources/indoor_isr.json) decodes and validates, says it has
/// not been walked, and hands over at its outdoor place's entrance (route_isr_cif.json WP1).
@Test func shippedIndoorDraftIsValid() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("../CaneKit/Resources/indoor_isr.json").standardized
    let s = try IndoorScript.load(from: Data(contentsOf: url))
    #expect(s.validate() == [])
    #expect(!s.walked)
    let place = try #require(CampusPlaces.place(id: s.outdoorPlaceID))
    #expect(s.exit.coordinate == place.coordinate)
    #expect(s.exit.radiusM == 25)
}

// MARK: - IndoorProgress

/// Start says step 0; a draft says the not-walked caveat first. Start happens once.
@Test func indoorStartSaysTheFirstStepAndTheCaveatOnADraft() {
    var walked = IndoorProgress(script: script())
    let _hoisted1 = walked.start()
    #expect(_hoisted1 == [.say(s0)])
    let _hoisted2 = walked.start()
    #expect(_hoisted2 == [])
    #expect(walked.index == 0 && !walked.atExit)

    var draft = IndoorProgress(script: script(walked: false))
    let _hoisted3 = draft.start()
    #expect(_hoisted3 == [.say(IndoorProgress.notWalkedLine), .say(s0)])

    // update / next before start() start first.
    var implicit = IndoorProgress(script: script(walked: false))
    let _hoisted4 = implicit.update(stepsWalked: 0)
    #expect(_hoisted4 == [.say(IndoorProgress.notWalkedLine), .say(s0)])
}

/// 10 steps: the landmark at 7 (0.7·10), the advance at 9 (ceil 0.85·10 = 9) — before the full
/// count, because the walker's stride varies and the next line carries the turn.
@Test func indoorStepAdvancesAt85PercentAndTheLandmarkAt70() {
    var p = IndoorProgress(script: script())
    _ = p.start()
    let _hoisted5 = p.update(stepsWalked: 6)
    #expect(_hoisted5 == [])
    let _hoisted6 = p.update(stepsWalked: 7)
    #expect(_hoisted6 == [.say(lm0)])
    let _hoisted7 = p.update(stepsWalked: 7)
    #expect(_hoisted7 == [])
    let _hoisted8 = p.update(stepsWalked: 8)
    #expect(_hoisted8 == [])
    let _hoisted9 = p.update(stepsWalked: 9)
    #expect(_hoisted9 == [.advanced(1), .say(s1)])
    #expect(p.index == 1)
    #expect(p.currentSay == s1)
}

/// A 6-step leg: landmark at ≥ 4.2 → 5 walked, advance at ceil(5.1) = 6.
@Test func indoorFractionsRoundTheWayThePinSays() {
    var p = IndoorProgress(script: script())
    _ = p.start()
    _ = p.update(stepsWalked: 27)   // into step 2 (baseline 30 nominal)
    #expect(p.index == 2)
    let _hoisted10 = p.update(stepsWalked: 34)
    #expect(_hoisted10 == [])
    let _hoisted11 = p.update(stepsWalked: 35)
    #expect(_hoisted11 == [.say(lm2)])
    let _hoisted12 = p.update(stepsWalked: 36)
    #expect(_hoisted12 == [.say(exitLine), .reachedExit])
}

/// Step boundaries are the nominal counts (10, then 30), not the early advance points: after
/// advancing at 9 the second step still ends at 10 + 17 = 27, so early advances never accumulate.
@Test func indoorCountsDoNotDriftAfterAnEarlyAdvance() {
    var p = IndoorProgress(script: script())
    _ = p.start()
    _ = p.update(stepsWalked: 9)
    let _hoisted13 = p.update(stepsWalked: 26)
    #expect(_hoisted13 == [])
    let _hoisted14 = p.update(stepsWalked: 27)
    #expect(_hoisted14 == [.advanced(2), .say(s2)])
}

/// The last step's completion says the exit line once and stops: steps after the exit, "next"
/// and a repeated update say nothing, and the index stays on the last step.
@Test func indoorLastStepEndsAtTheExitAndIgnoresLaterSteps() {
    var p = IndoorProgress(script: script())
    _ = p.start()
    _ = p.update(stepsWalked: 35)
    let _hoisted15 = p.update(stepsWalked: 36)
    #expect(_hoisted15 == [.say(exitLine), .reachedExit])
    #expect(p.atExit && p.index == 2)
    #expect(p.currentSay == exitLine)
    let _hoisted16 = p.update(stepsWalked: 36)
    #expect(_hoisted16 == [])
    let _hoisted17 = p.update(stepsWalked: 500)
    #expect(_hoisted17 == [])
    let _hoisted18 = p.next()
    #expect(_hoisted18 == [])
}

/// "next" advances regardless of the count, and the next step counts from where the walker said it.
@Test func indoorNextAdvancesRegardlessAndRebasesTheCount() {
    var p = IndoorProgress(script: script())
    _ = p.start()
    _ = p.update(stepsWalked: 3)
    let _hoisted19 = p.next()
    #expect(_hoisted19 == [.advanced(1), .say(s1)])
    let _hoisted20 = p.update(stepsWalked: 19)
    #expect(_hoisted20 == [])          // 16 walked in step 1
    let _hoisted21 = p.update(stepsWalked: 20)
    #expect(_hoisted21 == [.advanced(2), .say(s2)])   // 17 = ceil(0.85·20)
    _ = p.next()
    #expect(p.atExit)
}

/// A step with no count waits for "next"; pedometer steps never move it.
@Test func indoorStepWithoutACountWaitsForNext() {
    var p = IndoorProgress(script: script(steps: [
        IndoorStep(say: "Go through the double doors.", steps: nil),
        IndoorStep(say: "Walk about 10 steps.", steps: 10),
    ]))
    _ = p.start()
    let _hoisted22 = p.update(stepsWalked: 1000)
    #expect(_hoisted22 == [])
    #expect(p.index == 0)
    let _hoisted23 = p.next()
    #expect(_hoisted23 == [.advanced(1), .say("Walk about 10 steps.")])
    let _hoisted24 = p.update(stepsWalked: 1008)
    #expect(_hoisted24 == [])
    let _hoisted25 = p.update(stepsWalked: 1009)
    #expect(_hoisted25 == [.say(exitLine), .reachedExit])
}

/// A lower count (a pedometer restart) never moves the script backwards or re-arms a landmark.
@Test func indoorProgressNeverGoesBackwards() {
    var p = IndoorProgress(script: script())
    _ = p.start()
    _ = p.update(stepsWalked: 9)
    let _hoisted26 = p.update(stepsWalked: 2)
    #expect(_hoisted26 == [])
    #expect(p.index == 1)
    let _hoisted27 = p.update(stepsWalked: 26)
    #expect(_hoisted27 == [])
    let _hoisted28 = p.update(stepsWalked: 27)
    #expect(_hoisted28 == [.advanced(2), .say(s2)])
}

/// A jump across several steps: every `.advanced` in order, but at most two lines — the first
/// skipped step's line and the latest one.
@Test func indoorJumpSaysAtMostTwoLines() {
    var two = IndoorProgress(script: fourLegs())
    _ = two.start()
    let _hoisted29 = two.update(stepsWalked: 28)
    #expect(_hoisted29 == [.advanced(1), .say("Leg 2."), .advanced(2), .say("Leg 3.")])

    var three = IndoorProgress(script: fourLegs())
    _ = three.start()
    let _hoisted30 = three.update(stepsWalked: 35)
    #expect(_hoisted30
            == [.advanced(1), .say("Leg 2."), .advanced(2), .advanced(3), .say("Leg 4.")])
    #expect(three.index == 3)

    var toExit = IndoorProgress(script: fourLegs())
    _ = toExit.start()
    let events = toExit.update(stepsWalked: 39)
    #expect(events == [.advanced(1), .say("Leg 2."), .advanced(2), .advanced(3), .say(exitLine), .reachedExit])
    #expect(says(events).count <= IndoorProgress.maxJumpLines)
}

/// Landmarks count as lines too: a single advance keeps the passed step's landmark with the turn;
/// a longer jump keeps the turns and drops the landmarks.
@Test func indoorJumpPastALandmarkKeepsTheTurns() {
    var one = IndoorProgress(script: script())
    _ = one.start()
    let _hoisted31 = one.update(stepsWalked: 9)
    #expect(_hoisted31 == [.say(lm0), .advanced(1), .say(s1)])

    var far = IndoorProgress(script: script())
    _ = far.start()
    let _hoisted32 = far.update(stepsWalked: 35)
    #expect(_hoisted32 == [.advanced(1), .say(s1), .advanced(2), .say(s2)])
    // The dropped landmark is not said later either.
    let _hoisted33 = far.update(stepsWalked: 35)
    #expect(_hoisted33 == [])

    // One step say plus both landmarks around it: the step line and the current landmark.
    var mid = IndoorProgress(script: script(steps: [
        IndoorStep(say: "A.", steps: 10, landmark: "Old."),
        IndoorStep(say: "B.", steps: 10, landmark: "New."),
    ]))
    _ = mid.start()
    let _hoisted34 = mid.update(stepsWalked: 17)
    #expect(_hoisted34 == [.advanced(1), .say("B."), .say("New.")])
}

// MARK: - IndoorHandover

/// The handover numbers.
@Test func handoverNumbersArePinned() {
    #expect(IndoorHandover.goodAccuracyM == 15)
    #expect(IndoorHandover.consecutiveFixes == 3)
    #expect(IndoorHandover.forcedRecentAccuracyM == 30)
    #expect(IndoorHandover.forcedRecentWindowS == 20)
    #expect(IndoorHandover.waitingAccuracyM == 20)
    #expect(IndoorHandover.gpsOnlyAccuracyM == 10)
    #expect(IndoorHandover.gpsOnlyRadiusM == 15)
    #expect(IndoorHandover.gpsOnlyFixes == 3)
}

private func handover() -> IndoorHandover { IndoorHandover(exit: script().exit) }

private extension IndoorHandover {
    mutating func fix(_ c: Coordinate, _ accuracyM: Double, _ now: Double) -> Bool {
        fix(lat: c.latitude, lon: c.longitude, accuracyM: accuracyM, now: now)
    }
}

/// After the script's exit, three consecutive fixes ≤ 15 m accuracy within 25 m hand over, once.
@Test func handoverNeedsThreeGoodFixesInsideAfterTheExit() {
    var h = handover()
    h.reachedExit()
    let _hoisted35 = h.fix(north(10), 15, 1)
    #expect(!_hoisted35)
    let _hoisted36 = h.fix(north(-20), 5, 2)
    #expect(!_hoisted36)
    let _hoisted37 = h.fix(north(25), 10, 3)
    #expect(_hoisted37)
    #expect(h.handedOver)
    let _hoisted38 = h.fix(north(0), 5, 4)
    #expect(!_hoisted38)     // true only once
    let _hoisted39 = h.forced(now: 5)
    #expect(!_hoisted39)
}

/// Good fixes before the walker reached the exit (or said "I'm outside") do not count. (12 m
/// accuracy: good for the armed gate, too loose for the GPS-only handover.)
@Test func handoverIgnoresFixesBeforeItIsArmed() {
    var h = handover()
    for t in 1...5 {
        let _hoisted40 = h.fix(north(0), 12, Double(t))
        #expect(!_hoisted40)
    }
    h.reachedExit()
    let _hoisted41 = h.fix(north(0), 5, 6)
    #expect(!_hoisted41)
    let _hoisted42 = h.fix(north(0), 5, 7)
    #expect(!_hoisted42)
    let _hoisted43 = h.fix(north(0), 5, 8)
    #expect(_hoisted43)
}

/// A fix worse than 15 m neither counts nor resets the run.
@Test func handoverPoorFixNeitherCountsNorResets() {
    var h = handover()
    h.reachedExit()
    let _hoisted44 = h.fix(north(0), 8, 1)
    #expect(!_hoisted44)
    let _hoisted45 = h.fix(north(200), 15.1, 2)
    #expect(!_hoisted45)    // poor, far away: ignored
    let _hoisted46 = h.fix(north(0), 8, 3)
    #expect(!_hoisted46)
    let _hoisted47 = h.fix(north(0), 8, 4)
    #expect(_hoisted47)
}

/// A good fix outside the radius starts the run again.
@Test func handoverGoodFixOutsideResets() {
    var h = handover()
    h.reachedExit()
    let _hoisted48 = h.fix(north(0), 5, 1)
    #expect(!_hoisted48)
    let _hoisted49 = h.fix(north(0), 5, 2)
    #expect(!_hoisted49)
    let _hoisted50 = h.fix(north(26), 5, 3)
    #expect(!_hoisted50)
    let _hoisted51 = h.fix(north(0), 5, 4)
    #expect(!_hoisted51)
    let _hoisted52 = h.fix(north(0), 5, 5)
    #expect(!_hoisted52)
    let _hoisted53 = h.fix(north(0), 5, 6)
    #expect(_hoisted53)
}

/// "I'm outside" hands over at once when a fix ≤ 30 m accuracy within the exit radius (25 m) arrived
/// in the last 20 s (Muse M4: the radius, not 60 m).
@Test func handoverForcedIsImmediateWithARecentUsableFix() {
    var h = handover()
    let _hoisted54 = h.fix(north(25), 30, 100)
    #expect(!_hoisted54)
    let _hoisted55 = h.forced(now: 120)
    #expect(_hoisted55)
    #expect(h.handedOver)

    var inside = handover()
    let _hoisted56 = inside.fix(north(-24), 12, 110)
    #expect(!_hoisted56)
    let _hoisted57 = inside.forced(now: 111)
    #expect(_hoisted57)
}

/// Without such a fix, "I'm outside" waits for GPS and hands over on the first fix ≤ 20 m accuracy
/// within the exit radius. Too old (21 s), outside the radius (26 m) and too vague (31 m) do not count.
@Test func handoverForcedWithoutAFixWaitsForGPS() {
    var h = handover()
    let _hoisted58 = h.fix(north(0), 5, 99)
    #expect(!_hoisted58)        // 21 s before the request
    let _hoisted59 = h.fix(north(26), 5, 110)
    #expect(!_hoisted59)      // outside the 25 m radius
    let _hoisted60 = h.fix(north(0), 31, 115)
    #expect(!_hoisted60)      // too vague
    let _hoisted61 = h.forced(now: 120)
    #expect(!_hoisted61)
    #expect(h.waitingForGPS)
    let _hoisted62 = h.fix(north(0), 20.5, 121)
    #expect(!_hoisted62)    // not ≤ 20
    let _hoisted63 = h.fix(north(26), 20, 122)
    #expect(!_hoisted63)     // outside the 25 m radius
    let _hoisted64 = h.fix(north(25), 20, 123)
    #expect(_hoisted64)
}

/// Non-finite or negative accuracy (CoreLocation's "invalid") is no fix at all.
@Test func handoverIgnoresInvalidFixes() {
    var h = handover()
    let _hoisted65 = h.fix(north(0), .nan, 1)
    #expect(!_hoisted65)
    let _hoisted66 = h.fix(north(0), -1, 2)
    #expect(!_hoisted66)
    let _hoisted67 = h.fix(lat: .nan, lon: exitPoint.longitude, accuracyM: 5, now: 3)
    #expect(!_hoisted67)
    let _hoisted68 = h.forced(now: 4)
    #expect(!_hoisted68)
}

// MARK: - IndoorRecorder

/// A synthetic recording walk: yaw every 0.5 s, a pedometer update every two steps (0.5 s / step).
private struct Trace {
    var recorder = IndoorRecorder()
    var t = 0.0
    var count = 0

    /// Walks `steps` steps holding `heading` (± a deterministic `jitter` wobble on each sample).
    mutating func walk(_ steps: Int, heading: Double, jitter: Double = 0) {
        for i in 0..<steps {
            if i % 2 == 0 {
                let wobble = jitter == 0 ? 0 : (i % 4 == 0 ? jitter : -jitter)
                recorder.handle(.yaw(heading + wobble, t: t))
            }
            t += 0.5
            count += 1
            if count % 2 == 0 || i == steps - 1 { recorder.handle(.stepCount(count, t: t)) }
        }
    }

    /// Standing still, yaw samples moving from `from` to `to` over `seconds`, then held for `hold` s.
    mutating func turn(from: Double, to: Double, seconds: Double, hold: Double = 2) {
        let samples = Int(seconds / 0.25)
        for k in 1...max(1, samples) {
            t += 0.25
            recorder.handle(.yaw(from + (to - from) * Double(k) / Double(max(1, samples)), t: t))
        }
        var held = 0.0
        while held < hold { t += 0.25; held += 0.25; recorder.handle(.yaw(to, t: t)) }
    }

    mutating func finish() -> IndoorScript? {
        recorder.handle(.finish(lat: exitPoint.latitude, lon: exitPoint.longitude, t: t))
        return recorder.script(id: "recorded_2026-09-13", name: "Recorded", fromAliases: ["ISR"],
                               outdoorPlaceID: "isr", recordedAt: "2026-09-13")
    }
}

/// The turn-detector numbers.
@Test func recorderNumbersArePinned() {
    #expect(IndoorRecorder.turnThresholdDeg == 60)
    #expect(IndoorRecorder.turnHoldS == 1.5)
    #expect(IndoorRecorder.aroundThresholdDeg == 150)
}

/// A straight corridor with ±20° cane-sweep wobble is one step.
@Test func recorderStraightWalkIsOneStep() throws {
    var trace = Trace()
    trace.walk(30, heading: 10, jitter: 20)
    let _hoisted69 = trace.finish()
    let s = try #require(_hoisted69)
    #expect(s.steps == [IndoorStep(say: "Walk straight about 30 steps.", steps: 30, turn: .none)])
    #expect(s.walked && s.recordedAt == "2026-09-13" && s.strideM == nil)
    #expect(s.exit.lat == exitPoint.latitude && s.exit.lon == exitPoint.longitude && s.exit.radiusM == 25)
    #expect(s.validate().isEmpty)
}

/// An L: straight, then a sustained right turn (negative yaw), then straight.
@Test func recorderLTurnStartsARightStep() throws {
    var trace = Trace()
    trace.walk(20, heading: 0)
    trace.turn(from: 0, to: -90, seconds: 1)
    trace.walk(14, heading: -90)
    let _hoisted70 = trace.finish()
    let s = try #require(_hoisted70)
    #expect(s.steps == [
        IndoorStep(say: "Walk straight about 20 steps.", steps: 20, turn: .none),
        IndoorStep(say: "Turn right. Walk about 14 steps.", steps: 14, turn: .right),
    ])
}

/// A left turn is positive yaw; a turn of 150° or more is "around" — also when the walker turns
/// slowly and the turn is confirmed before they finish it.
@Test func recorderUTurnIsAroundEvenWhenSlow() throws {
    var fast = Trace()
    fast.walk(12, heading: 0)
    fast.turn(from: 0, to: 80, seconds: 1)
    fast.walk(8, heading: 80)
    fast.turn(from: 80, to: 260, seconds: 1)
    fast.walk(9, heading: 260)
    let _hoisted71 = fast.finish()
    let f = try #require(_hoisted71)
    #expect(f.steps.map(\.turn) == [.none, .left, .around])
    #expect(f.steps.map(\.say) == ["Walk straight about 12 steps.", "Turn left. Walk about 8 steps.",
                                   "Turn around. Walk about 9 steps."])

    // 180° over 4 s: crosses 60° at 1.33 s, is confirmed at ~2.8 s near 128°, keeps going.
    var slow = Trace()
    slow.walk(12, heading: 0)
    slow.turn(from: 0, to: 175, seconds: 4)
    slow.walk(10, heading: 175)
    let _hoisted72 = slow.finish()
    let s = try #require(_hoisted72)
    #expect(s.steps.map(\.turn) == [.none, .around])
    #expect(s.steps.count == 2)
}

/// A turn must stay ≥ 60° for ≥ 1.5 s: a 1 s glance is not a step, 59° held forever is not a
/// step, and exactly 1.5 s at 60° is.
@Test func recorderTurnMustBeHeldLongEnough() throws {
    var glance = Trace()
    glance.walk(10, heading: 0)
    glance.turn(from: 0, to: 90, seconds: 0.25, hold: 1.0)
    glance.turn(from: 90, to: 0, seconds: 0.25, hold: 0.5)
    glance.walk(10, heading: 0)
    let _hoisted73 = glance.finish()
    #expect(try #require(_hoisted73).steps.count == 1)

    var shallow = Trace()
    shallow.walk(10, heading: 0)
    shallow.turn(from: 0, to: 59, seconds: 0.5, hold: 10)
    shallow.walk(10, heading: 59)
    let _hoisted74 = shallow.finish()
    #expect(try #require(_hoisted74).steps.count == 1)

    var edge = IndoorRecorder()
    edge.handle(.yaw(0, t: 0))
    edge.handle(.stepCount(5, t: 1))
    edge.handle(.yaw(60, t: 2))
    edge.handle(.yaw(61, t: 3.49))
    edge.handle(.stepCount(6, t: 3.49))
    #expect(edge.stepCountsSoFar == [6])      // 1.49 s: still one step
    edge.handle(.yaw(60, t: 3.5))
    edge.handle(.stepCount(9, t: 4))
    #expect(edge.stepCountsSoFar == [6, 3])   // 1.5 s: a new left step
}

/// A turn before the first step is walked only sets the starting heading.
@Test func recorderTurnBeforeWalkingIsNotAStep() throws {
    var trace = Trace()
    trace.recorder.handle(.yaw(0, t: 0))
    trace.turn(from: 0, to: -120, seconds: 1)
    trace.walk(16, heading: -120)
    let _hoisted75 = trace.finish()
    let s = try #require(_hoisted75)
    #expect(s.steps == [IndoorStep(say: "Walk straight about 16 steps.", steps: 16, turn: .none)])
}

/// Landmarks attach to the step they were spoken in; two in one step are joined.
@Test func recorderLandmarksAttachToTheirStep() throws {
    var trace = Trace()
    trace.walk(8, heading: 0)
    trace.recorder.handle(.landmark("The personal lab is on your left", t: trace.t))
    trace.walk(8, heading: 0)
    trace.turn(from: 0, to: 90, seconds: 1)
    trace.walk(4, heading: 90)
    trace.recorder.handle(.landmark("  ", t: trace.t))             // blank: ignored
    trace.recorder.handle(.landmark("Elevators on your right.", t: trace.t))
    trace.recorder.handle(.landmark("Stairs ahead.", t: trace.t))
    trace.walk(1, heading: 90)
    let _hoisted76 = trace.finish()
    let s = try #require(_hoisted76)
    #expect(s.steps.count == 2)
    #expect(s.steps[0].landmark == "The personal lab is on your left.")
    #expect(s.steps[1].landmark == "Elevators on your right. Stairs ahead.")
    #expect(s.steps[1].say == "Turn left. Walk about 5 steps.")
}

/// No script before "finish at the exit" or with no steps; one step says "step", not "steps";
/// the stride comes from a measured distance; events after finish are ignored.
@Test func recorderOutputNeedsFinishStepsAndMeasuresStride() throws {
    var r = IndoorRecorder()
    #expect(r.script(id: "x", name: "X", fromAliases: ["ISR"], outdoorPlaceID: "isr", recordedAt: nil) == nil)
    r.handle(.finish(lat: 1, lon: 2, t: 0))
    #expect(r.script(id: "x", name: "X", fromAliases: ["ISR"], outdoorPlaceID: "isr", recordedAt: nil) == nil)

    var one = IndoorRecorder()
    one.handle(.yaw(0, t: 0))
    one.handle(.stepCount(1, t: 1))
    one.handle(.finish(lat: exitPoint.latitude, lon: exitPoint.longitude, t: 2))
    one.handle(.stepCount(50, t: 3))
    let s = try #require(one.script(id: "x", name: "X", fromAliases: ["ISR"], outdoorPlaceID: "isr",
                                    recordedAt: nil, distanceM: 0.72))
    #expect(s.steps == [IndoorStep(say: "Walk straight about 1 step.", steps: 1, turn: .none)])
    #expect(s.strideM == 0.72)

    var trace = Trace()
    trace.walk(40, heading: 0)
    trace.recorder.handle(.finish(lat: 0, lon: 0, t: trace.t))
    let measured = try #require(trace.recorder.script(id: "x", name: "X", fromAliases: ["ISR"],
                                                      outdoorPlaceID: "isr", recordedAt: nil, distanceM: 28))
    #expect(measured.strideM == 0.7)
    #expect(measured.exit.say == IndoorRecorder.defaultExitSay)
}

// MARK: - App support (Step 62 app half): catalog, exit averaging, status lines, yaw, sim steps

/// A recorded script replaces the bundled one with the same id in place; new ids are appended.
@Test func catalogRecordedScriptWinsByID() {
    let draft = script(walked: false)
    var recorded = script(walked: true)
    recorded.name = "Recorded"
    var other = script(walked: true)
    other.id = "siebel_lobby"
    let merged = IndoorScriptCatalog.merged(bundled: [draft], recorded: [recorded, other])
    #expect(merged.map(\.id) == ["isr_lab_to_front_doors", "siebel_lobby"])
    #expect(merged[0].name == "Recorded")
    #expect(merged[0].walked)
}

/// "take me from isr lab to …": aliases match case- and punctuation-insensitively (CampusPlaces.normalize,
/// "the" dropped); a walked script beats a draft with the same alias; no match → nil.
@Test func catalogPicksAScriptByItsSpokenOrigin() {
    var draft = script(walked: false)
    draft.id = "draft"
    draft.fromAliases = ["ISR lab", "Townsend"]
    var walked = script(walked: true)
    walked.fromAliases = ["townsend", "the lab"]
    let all = [draft, walked]
    #expect(IndoorScriptCatalog.script(forOrigin: "Townsend.", in: all)?.id == walked.id)
    #expect(IndoorScriptCatalog.script(forOrigin: "isr LAB", in: all)?.id == "draft")
    #expect(IndoorScriptCatalog.script(forOrigin: "Lab", in: all)?.id == walked.id)
    #expect(IndoorScriptCatalog.script(forOrigin: "Siebel", in: all) == nil)
    #expect(IndoorScriptCatalog.script(forOrigin: "the", in: all) == nil)
}

/// The outdoor leg: CIF (or no destination) is the recorded demo route; anything else is a MapKit route.
@Test func catalogOutdoorLegIsTheDemoRouteOnlyForCIF() {
    #expect(IndoorScriptCatalog.outdoorLeg(destination: "CIF") == .demoRoute)
    #expect(IndoorScriptCatalog.outdoorLeg(destination: "the CIF east entrance") == .demoRoute)
    #expect(IndoorScriptCatalog.outdoorLeg(destination: nil) == .demoRoute)
    #expect(IndoorScriptCatalog.outdoorLeg(destination: "  ") == .demoRoute)
    #expect(IndoorScriptCatalog.outdoorLeg(destination: "Grainger") == .navigate("Grainger"))
    #expect(IndoorScriptCatalog.outdoorLeg(destination: " Siebel Center ") == .navigate("Siebel Center"))
}

/// A typed id becomes a safe file name; blank → the ISR draft's id (so a recording replaces the draft).
@Test func catalogSanitizesRecordingIDs() {
    #expect(IndoorScriptCatalog.defaultRecordingID == "isr_townsend_to_front_doors")
    #expect(IndoorScriptCatalog.sanitizedID("  ") == "isr_townsend_to_front_doors")
    #expect(IndoorScriptCatalog.sanitizedID("ISR Lab/../doors") == "isr_lab____doors")
    #expect(IndoorScriptCatalog.sanitizedID("siebel-2") == "siebel-2")
}

/// "Finish at the exit": the mean of fixes ≤ 15 m inside 8 s; done at 8 s or after 5 good fixes;
/// with no good fix the last valid fix; nothing at all → nil. Invalid fixes are ignored.
@Test func exitAveragerAveragesGoodFixesElseTheLastFix() throws {
    var a = IndoorExitAverager(startedAt: 100)
    #expect(a.result() == nil)
    #expect(!a.isDone(now: 107.9))
    #expect(a.isDone(now: 108))
    a.add(lat: 40.0, lon: -88.0, accuracyM: 30, t: 101)          // not good: only a fallback
    #expect(a.result() == Coordinate(latitude: 40.0, longitude: -88.0))
    a.add(lat: .nan, lon: -88.0, accuracyM: 5, t: 101.5)          // invalid: ignored
    a.add(lat: 40.0002, lon: -88.0002, accuracyM: 15, t: 102)
    a.add(lat: 40.0004, lon: -88.0004, accuracyM: 5, t: 103)
    a.add(lat: 40.0010, lon: -88.0010, accuracyM: 4, t: 109)      // after the 8 s window: ignored
    let mean = try #require(a.result())
    #expect(abs(mean.latitude - 40.0003) < 1e-9)
    #expect(abs(mean.longitude + 88.0003) < 1e-9)
    #expect(a.goodFixCount == 2)

    var fast = IndoorExitAverager(startedAt: 0)
    for i in 0..<5 { fast.add(lat: 1, lon: 2, accuracyM: 3, t: Double(i) * 0.2) }
    #expect(fast.isDone(now: 1))
}

/// The status clause and the Guide line count steps from 1; at the exit they say so.
@Test func indoorStatusLinesCountFromOne() {
    #expect(IndoorStatus.statusClause(index: 2, count: 5, atExit: false) == "Indoors: step 3 of 5.")
    #expect(IndoorStatus.guideLine(index: 2, count: 5, atExit: false) == "Indoors · step 3 of 5")
    #expect(IndoorStatus.statusClause(index: 4, count: 5, atExit: true) == "Indoors: at the exit, waiting for GPS.")
    #expect(IndoorStatus.guideLine(index: 4, count: 5, atExit: true) == "Indoors · at the exit")
}

/// The status report speaks the indoor clause instead of "No route running." while indoors.
@Test func statusRouteClauseSpeaksIndoorProgress() {
    var f = StatusFacts(lidarSupported: true, obstacleDetectionRunning: true, depthFps: 30, gpsFix: false,
                        gpsAccuracyM: -1, locationDenied: false, headphonesConnected: false, headphoneName: "",
                        headTracking: false, hapticsHealthy: true, hapticsSilenced: false, watchReachable: false,
                        routeRunning: false, routeInstruction: "", metresToNext: nil, batteryPercent: -1)
    #expect(StatusSummary.routeLine(f) == StatusSummary.noRouteLine)
    f.indoorClause = "Indoors: step 3 of 5."
    #expect(StatusSummary.routeLine(f) == "Indoors: step 3 of 5.")
    #expect(StatusSummary.sentence(f).contains("Indoors: step 3 of 5."))
}

/// CMDeviceMotion yaw (radians, ±π) → unwrapped degrees: crossing ±180° keeps counting.
@Test func yawUnwrapperKeepsCountingAcrossTheSeam() {
    var u = IndoorYawUnwrapper()
    #expect(abs(u.unwrap(radians: 170 * .pi / 180)! - 170) < 1e-9)
    #expect(abs(u.unwrap(radians: -170 * .pi / 180)! - 190) < 1e-9)       // +20° across the seam
    #expect(abs(u.unwrap(radians: 10 * .pi / 180)! - 370) < 1e-9)
    #expect(abs(u.unwrap(radians: -90 * .pi / 180)! - 270) < 1e-9)        // −100°
    #expect(u.unwrap(radians: .nan) == nil)
}

/// CANEKIT_INDOOR_SIM_STEPS_PER_S: a positive rate up to 5 steps/s; synthetic steps = floor(rate·t).
@Test func simStepsParseTheRateAndCountWholeSteps() {
    #expect(IndoorSimSteps.rate(from: "1.8") == 1.8)
    #expect(IndoorSimSteps.rate(from: nil) == nil)
    #expect(IndoorSimSteps.rate(from: "0") == nil)
    #expect(IndoorSimSteps.rate(from: "fast") == nil)
    #expect(IndoorSimSteps.rate(from: "12") == 5)
    #expect(IndoorSimSteps.steps(rate: 1.8, elapsedS: 10) == 18)
    #expect(IndoorSimSteps.steps(rate: 1.8, elapsedS: 0.5) == 0)
    #expect(IndoorSimSteps.steps(rate: 1.8, elapsedS: -3) == 0)
    #expect(IndoorSimSteps.nextOnlyWaitS == 3)
}

/// Recording timings: 10 Hz yaw, a 20 s landmark window.
@Test func recorderTimingsAreTheSpec() {
    #expect(IndoorRecorder.yawSampleIntervalS == 0.1)
    #expect(IndoorRecorder.landmarkWindowS == 20)
    #expect(IndoorExitAverager.windowS == 8)
    #expect(IndoorExitAverager.goodAccuracyM == 15)
}

// MARK: - Steps 62 + 64 review round

/// Review item 2: a locked phone pauses the pedometer, so the script may never reach its exit.
/// Three consecutive fixes ≤ 10 m accuracy within 15 m of the exit hand over without it.
@Test func handoverGpsOnlyFiresOnThreeTightFixesWithoutTheExit() {
    var h = handover()
    let a = h.fix(north(15), 10, 1)
    #expect(!a)
    let b = h.fix(north(-5), 4, 2)
    #expect(!b)
    let c = h.fix(north(0), 8, 3)
    #expect(c)
    #expect(h.handedOver)
    #expect(!h.exitReached)
    let d = h.fix(north(0), 5, 4)
    #expect(!d)                   // true only once
}

/// Review item 2: a 12 m-accuracy fix or one 20 m from the exit breaks the GPS-only run (no
/// pedometer evidence, so the run must be consecutive).
@Test func handoverGpsOnlyNeedsConsecutiveTightFixesNearTheExit() {
    var h = handover()
    for (i, fix) in [(north(0), 5.0), (north(0), 5.0), (north(0), 12.0),
                     (north(0), 5.0), (north(0), 5.0), (north(20), 5.0),
                     (north(0), 5.0), (north(0), 5.0)].enumerated() {
        let r = h.fix(fix.0, fix.1, Double(i + 1))
        #expect(!r, "fix \(i + 1)")
    }
    let last = h.fix(north(0), 5, 9)
    #expect(last)
}

/// Muse M4: "I'm outside" with a recent fix outside the exit radius waits for GPS instead of
/// handing over (a fix 26 m off with 30 m accuracy can still be inside the building).
@Test func handoverForcedNeedsTheRecentFixInsideTheRadius() {
    var h = handover()
    let a = h.fix(north(26), 30, 100)
    #expect(!a)
    let b = h.forced(now: 101)
    #expect(!b)
    #expect(h.waitingForGPS)
}

/// Review item 6: the exit fallback (no good fix in the window) must still be a usable fix — ≤ 30 m
/// accuracy — and the last-known fix used after the window at most 20 s old; else "No GPS fix".
@Test func exitAveragerFallbackNeedsAUsableFix() {
    #expect(IndoorExitAverager.fallbackAccuracyM == 30)
    #expect(IndoorExitAverager.fallbackMaxAgeS == 20)
    var a = IndoorExitAverager(startedAt: 0)
    a.add(lat: 40, lon: -88, accuracyM: 65, t: 1)            // indoor-grade: no fallback
    #expect(a.result() == nil)
    a.add(lat: 40.1, lon: -88.1, accuracyM: 30, t: 2)
    #expect(a.result() == Coordinate(latitude: 40.1, longitude: -88.1))
    a.add(lat: 40.2, lon: -88.2, accuracyM: 31, t: 3)        // worse later fix keeps the usable one
    #expect(a.result() == Coordinate(latitude: 40.1, longitude: -88.1))
    #expect(a.goodFixCount == 0)

    #expect(IndoorExitAverager.usableFallback(accuracyM: 30, ageS: 20))
    #expect(!IndoorExitAverager.usableFallback(accuracyM: 30.5, ageS: 1))
    #expect(!IndoorExitAverager.usableFallback(accuracyM: 5, ageS: 20.5))
    #expect(!IndoorExitAverager.usableFallback(accuracyM: -1, ageS: 1))
    #expect(!IndoorExitAverager.usableFallback(accuracyM: .nan, ageS: 1))
}

/// Review item 1: while "Add landmark" waits, a command (stop, I'm outside, emergency, yes / no)
/// is not a landmark and must reach the conversation; plain text is.
@Test func landmarkHookLetsCommandsThrough() {
    for command in ["stop", "Stop route.", "cancel route", "end route", "I'm outside", "emergency",
                    "eight", "yes", "no"] {
        #expect(!IndoorRecorder.isLandmarkText(command), "\(command)")
    }
    #expect(!IndoorRecorder.isLandmarkText("   "))
    for landmark in ["personal lab on your left", "The main desk is on your right.", "water fountain"] {
        #expect(IndoorRecorder.isLandmarkText(landmark), "\(landmark)")
    }
}
