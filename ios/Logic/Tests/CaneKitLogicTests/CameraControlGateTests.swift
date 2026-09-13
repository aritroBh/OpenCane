//
//  CameraControlGateTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins CameraControlGate.swift — when a Camera Control / volume press may start a scene
//  description (Step 67; review round Steps 67–68).
//
//  Why these are the tests: phone log `canekit-2026-09-13T15-48-34Z.jsonl`. The hand gripping the
//  phone pressed Camera Control three times in the first four seconds (t = 1.71, 2.89, 3.56:
//  `describe {trigger: cameraControl}`), two of them while "OpenCane ready." and the menu were
//  still speaking. The walker heard two busy earcons and, at 14.9 s, a scene description nobody
//  asked for. Each Step 67 test replays one part of that: the launch grace, the launch line, the
//  listening window.
//  Review round (Antigravity #6): the debounce used to restart on every press, refused or not, so a
//  hand touching the button every 1–1.8 s locked "Where am I" out for as long as it kept touching.
//  The debounce now runs from the last ACCEPTED press, and a grip is its own rule (≥ 3 presses in
//  1.5 s → `grip_burst`). Muse #6: a single press refused only because of the launch (grace, launch
//  line, listening) is remembered and answered when that state ends, unless a second quick press
//  (a grip) or another command came first.
//
//  Source pinned: `ios/Logic/Sources/CaneKitLogic/CameraControlGate.swift` (`launchGraceSeconds` 5,
//  `debounceSeconds` 2, `burstWindowSeconds` 1.5, `burstPresses` 3, `pendingMaxAgeSeconds` 30,
//  `pendingSettleSeconds` 0.5, `press(now:listening:launchLinePending:commandGeneration:)`,
//  `resolvePending(now:listening:launchLinePending:commandGeneration:)`, the skip reasons).
//  Caller: `AppModel.cameraControlPressed` / `AppModel.watchPendingCameraControl` (app), which log
//  `describe_skipped {reason, trigger, pending}` and `describe_deferred {action, reason}`.
//

import Testing
@testable import CaneKitLogic

@Suite("Camera Control gate")
struct CameraControlGateTests {

    /// The numbers, as the doc comments and the CHANGELOG state them.
    @Test func numbersArePinned() {
        #expect(CameraControlGate.launchGraceSeconds == 5)
        #expect(CameraControlGate.debounceSeconds == 2)
        #expect(CameraControlGate.burstWindowSeconds == 1.5)
        #expect(CameraControlGate.burstPresses == 3)
        #expect(CameraControlGate.pendingMaxAgeSeconds == 30)
        #expect(CameraControlGate.pendingSettleSeconds == 0.5)
    }

    /// The log's three presses (launch at 0.31 s, presses at 1.71, 2.89, 3.56) all fall inside the
    /// grace window: none describes, and because they came in quick succession (a grip) nothing is
    /// left pending to describe when the launch ends.
    @Test func thePressesFromTheLogAreAllInsideTheLaunchGrace() {
        var gate = CameraControlGate(launchedAt: 0.31)
        for t in [1.713, 2.889, 3.559] {
            #expect(gate.press(now: t, listening: false, launchLinePending: false) == .skip(reason: "launch_grace"), "t=\(t)")
        }
        #expect(!gate.hasPendingDescribe)
        let later = gate.resolvePending(now: 20, listening: false, launchLinePending: false)
        #expect(later == .none)
    }

    /// Exactly at the edge: 4.99 s after launch is refused, 5 s is allowed (with no press before it).
    @Test func graceEndsAtFiveSeconds() {
        var early = CameraControlGate(launchedAt: 100)
        #expect(early.press(now: 104.99, listening: false, launchLinePending: false) == .skip(reason: "launch_grace"))
        var onTime = CameraControlGate(launchedAt: 100)
        #expect(onTime.press(now: 105, listening: false, launchLinePending: false) == .describe)
    }

    /// While the voice shell listens (the launch listen, a follow-up, a press) a squeeze of the
    /// phone must not start a description over the walker's words.
    @Test func blockedWhileListening() {
        var gate = CameraControlGate(launchedAt: 0)
        #expect(gate.press(now: 20, listening: true, launchLinePending: false) == .skip(reason: "listening"))
        #expect(gate.press(now: 30, listening: false, launchLinePending: false) == .describe)
    }

    /// The launch line can still be speaking (or waiting to drain before the launch listen) after
    /// the grace: blocked until the launch sequence ends.
    @Test func blockedWhileTheLaunchLineIsPending() {
        var gate = CameraControlGate(launchedAt: 0)
        #expect(gate.press(now: 6, listening: false, launchLinePending: true) == .skip(reason: "launch_line"))
        #expect(gate.press(now: 9, listening: false, launchLinePending: false) == .describe)
    }

    /// The debounce runs from the last ACCEPTED press: a refused press in between does not push it
    /// back (Antigravity #6 — it used to, which is how a touching hand locked the button out).
    @Test func theDebounceRunsFromTheLastAcceptedPress() {
        var gate = CameraControlGate(launchedAt: 0)
        #expect(gate.press(now: 10.0, listening: false, launchLinePending: false) == .describe)
        #expect(gate.press(now: 11.2, listening: false, launchLinePending: false) == .skip(reason: "debounce"))
        #expect(gate.press(now: 12.1, listening: false, launchLinePending: false) == .describe)   // 2.1 s after the accepted one
    }

    /// Presses every 1.8 s after the grace (a hand brushing the button): every other one is
    /// accepted (≥ 2 s since the last accepted), never an indefinite lockout.
    @Test func pressesEveryOnePointEightSecondsAreNeverLockedOut() {
        var gate = CameraControlGate(launchedAt: 0)
        var verdicts: [CameraControlGate.Verdict] = []
        for i in 0..<10 {
            verdicts.append(gate.press(now: 10 + Double(i) * 1.8, listening: false, launchLinePending: false))
        }
        let expected: [CameraControlGate.Verdict] = (0..<10).map { $0 % 2 == 0 ? .describe : .skip(reason: "debounce") }
        #expect(verdicts == expected)
    }

    /// A grip: three or more presses within 1.5 s refuse the burst, and a grip that keeps pressing
    /// every 0.6 s keeps being refused; once the hand lets go, the next press describes.
    @Test func aGripBurstIsRefused() {
        var gate = CameraControlGate(launchedAt: 0)
        #expect(gate.press(now: 20.0, listening: false, launchLinePending: false) == .describe)
        #expect(gate.press(now: 20.5, listening: false, launchLinePending: false) == .skip(reason: "debounce"))
        #expect(gate.press(now: 21.0, listening: false, launchLinePending: false) == .skip(reason: "grip_burst"))
        #expect(gate.press(now: 21.6, listening: false, launchLinePending: false) == .skip(reason: "grip_burst"))
        #expect(gate.press(now: 22.2, listening: false, launchLinePending: false) == .skip(reason: "grip_burst"))
        #expect(gate.press(now: 25.0, listening: false, launchLinePending: false) == .describe)
    }

    /// Muse #6: one press during the launch (the walker opened the app to ask "where am I") is not
    /// lost — it waits through the grace, the launch line and the launch listen, and fires 0.5 s
    /// after all of them have ended.
    @Test func aSinglePressDuringTheLaunchIsAnsweredWhenTheLaunchEnds() {
        var gate = CameraControlGate(launchedAt: 0)
        #expect(gate.press(now: 2, listening: false, launchLinePending: true) == .skip(reason: "launch_grace"))
        #expect(gate.hasPendingDescribe)
        let r1 = gate.resolvePending(now: 4, listening: false, launchLinePending: true)
        #expect(r1 == .wait)
        let r2 = gate.resolvePending(now: 6, listening: false, launchLinePending: true)
        #expect(r2 == .wait)
        let r3 = gate.resolvePending(now: 9, listening: true, launchLinePending: false)
        #expect(r3 == .wait)
        let r4 = gate.resolvePending(now: 12, listening: false, launchLinePending: false)
        #expect(r4 == .wait)                                    // settling: the transcript may still arrive
        let r5 = gate.resolvePending(now: 12.4, listening: false, launchLinePending: false)
        #expect(r5 == .wait)
        let r6 = gate.resolvePending(now: 12.5, listening: false, launchLinePending: false)
        #expect(r6 == .fire)
        #expect(!gate.hasPendingDescribe)
        let r7 = gate.resolvePending(now: 13, listening: false, launchLinePending: false)
        #expect(r7 == .none)
        // It counts as the accepted press for the debounce.
        #expect(gate.press(now: 13.5, listening: false, launchLinePending: false) == .skip(reason: "debounce"))
    }

    /// A listen that ends with a spoken command (the coordinator's query generation moved on) drops
    /// the pending press: the walker asked for something else.
    @Test func aPendingPressIsDroppedWhenAnotherCommandRuns() {
        var gate = CameraControlGate(launchedAt: 0)
        #expect(gate.press(now: 6, listening: true, launchLinePending: false, commandGeneration: 3) == .skip(reason: "listening"))
        let r = gate.resolvePending(now: 10, listening: false, launchLinePending: false, commandGeneration: 4)
        #expect(r == .drop(reason: "other_command"))
        #expect(!gate.hasPendingDescribe)
    }

    /// A second press within 2 s of the first while blocked is a grip, not a request: nothing stays
    /// pending. A later single press (≥ 2 s after the previous one) arms it again.
    @Test func aQuickSecondPressWhileBlockedCancelsThePending() {
        var gate = CameraControlGate(launchedAt: 0)
        #expect(gate.press(now: 1, listening: false, launchLinePending: false) == .skip(reason: "launch_grace"))
        #expect(gate.hasPendingDescribe)
        #expect(gate.press(now: 2, listening: false, launchLinePending: false) == .skip(reason: "launch_grace"))
        #expect(!gate.hasPendingDescribe)
        #expect(gate.press(now: 7, listening: false, launchLinePending: true) == .skip(reason: "launch_line"))
        #expect(gate.hasPendingDescribe)
    }

    /// A pending press older than 30 s is dropped rather than describing a scene the walker has
    /// long since moved on from.
    @Test func aPendingPressExpires() {
        var gate = CameraControlGate(launchedAt: 0)
        #expect(gate.press(now: 2, listening: false, launchLinePending: false) == .skip(reason: "launch_grace"))
        let r1 = gate.resolvePending(now: 31.9, listening: true, launchLinePending: false)
        #expect(r1 == .wait)
        let r2 = gate.resolvePending(now: 32.1, listening: false, launchLinePending: false)
        #expect(r2 == .drop(reason: "expired"))
    }

    /// A press refused for the grace no longer starts a debounce (the debounce belongs to accepted
    /// presses); a lone press just after the grace describes, and the grace press is no longer
    /// pending because the walker's own press superseded it.
    @Test func aRefusedPressDoesNotStartTheDebounce() {
        var gate = CameraControlGate(launchedAt: 0)
        #expect(gate.press(now: 4.5, listening: false, launchLinePending: false) == .skip(reason: "launch_grace"))
        #expect(gate.press(now: 5.5, listening: false, launchLinePending: false) == .describe)
        #expect(!gate.hasPendingDescribe)
    }

    /// A clock that runs backwards (never expected; `systemUptime` is monotonic) refuses rather than
    /// describes.
    @Test func aBackwardsClockRefuses() {
        var gate = CameraControlGate(launchedAt: 50)
        #expect(gate.press(now: 40, listening: false, launchLinePending: false) == .skip(reason: "launch_grace"))
        var later = CameraControlGate(launchedAt: 0)
        #expect(later.press(now: 30, listening: false, launchLinePending: false) == .describe)
        #expect(later.press(now: 29, listening: false, launchLinePending: false) == .skip(reason: "debounce"))
    }
}
