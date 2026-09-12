//
//  LaunchRecoveryTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins LaunchRecovery.swift — the rule that stops an optional feature from bricking the
//  app at launch. Written *before* the fix, from a real trip log (AGENTS.md "How we engineer"
//  rule 2: a bug fix starts with a failing test that reproduces it).
//
//  The bug it reproduces, from the phone (`/tmp/crashhunt`, 2026-09-12):
//    · `canekit-2026-09-12T02-40-53Z.jsonl`, t=17.583:
//      `{"kind":"face_tracking","supported":true,"enabled":true}` — the walker turned on
//      "Head tracking without AirPods", which is persisted to UserDefaults.
//    · `canekit-2026-09-12T02-41-13Z.jsonl` (the next launch) has THREE records and stops:
//      `session`, `start` with `"face_head_tracking":true`, `multicam_depth`. The trip log is
//      buffered and flushed every 2 s, so those three reached disk at t≈2 s and nothing survived
//      the t≈4 s flush: the process died inside the ARKit warm-up, before the first `lanes`
//      record (which the healthy session before it wrote at t=3.117).
//  A persisted optional feature that kills the launch is unrecoverable by the walker: the switch
//  that would turn it off is behind a screen the app never reaches. That is the shape this file
//  makes impossible.
//
//  Key invariants under test:
//    · A launch that never reported itself healthy puts the *next* launch in `.recovered`, with
//      every optional feature cleared — the app must come up.
//    · The healthy mark is later than a cold ARKit start (first depth at 3.1 s on the phone) and
//      earlier than a walk, so a crash inside the warm-up is always caught.
//    · `optionalFeatureKeys` never contains a core-guidance setting: recovering from a crash may
//      not silence the beacon, the haptics or the trip log.
//    · The spoken line says what is off *and* that guidance still works (AGENTS.md rule 6: a
//      refused feature warns loudly but still guides).
//
//  Source pinned: `ios/Logic/Sources/CaneKitLogic/LaunchRecovery.swift` (`LaunchMode`,
//  `LaunchRecovery.mode(previousLaunchCompleted:)`, `healthySeconds`, `optionalFeatureKeys`,
//  `spokenLine(for:)`). Caller: `AppModel.swift` — `Settings.launchMode` checks the on-disk marker
//  file (`LaunchRecovery.markerName`, a file rather than a UserDefaults key) and removes every
//  `optionalFeatureKeys` default on `.recovered`; `AppModel.start()` speaks the recovery line and
//  marks the launch healthy after `healthySeconds`. ⚠ Every new persisted optional feature `AppModel` touches at launch must be
//  added to `optionalFeatureKeys` and to `recoveryClearsEveryPersistedOptionalFeature`.
//

import Testing
@testable import CaneKitLogic

/// The normal case: the previous launch reported itself healthy, so nothing is taken away.
@Test func aCompletedPreviousLaunchStartsNormally() {
    #expect(LaunchRecovery.mode(previousLaunchCompleted: true) == .normal)
    #expect(LaunchRecovery.spokenLine(for: .normal) == nil)
}

/// The crash loop, reproduced: the previous launch never cleared its marker (it died at ~2–4 s
/// with `face_head_tracking: true`), so this launch runs with the optional features off.
@Test func anIncompletePreviousLaunchRecovers() {
    #expect(LaunchRecovery.mode(previousLaunchCompleted: false) == .recovered)
    #expect(LaunchRecovery.spokenLine(for: .recovered) != nil)
}

/// ⚠ The healthy mark must sit *after* a cold ARKit start. The healthy session
/// `canekit-2026-09-12T02-40-53Z.jsonl` published its first `lanes` record at t=3.117 s; the
/// crashed one died before it. A mark earlier than that would call a dying launch healthy and the
/// walker would be left holding a phone that cannot start.
@Test func theHealthyMarkIsLaterThanAColdArkitStart() {
    #expect(LaunchRecovery.healthySeconds > 3.117)
    // …and short enough that a walker who starts a route immediately is past it well before the
    // first waypoint: a launch the walker is visibly using is a launch that worked.
    #expect(LaunchRecovery.healthySeconds <= 20)
}

/// Recovering from a crash may never take away the guidance the cane user depends on. These keys
/// are the ones `AppModel` persists for core behaviour; none of them may be cleared.
@Test func recoveryNeverClearsCoreGuidanceSettings() {
    let core = ["portraitMode", "mirrorLeftRight", "hapticsSilenced", "loggingEnabled",
                "obstacleNamesEnabled", "beaconEnabled", "fallbackToWatch", "namePeopleEnabled"]
    for key in core {
        #expect(!LaunchRecovery.optionalFeatureKeys.contains(key),
                "recovery must not clear the core setting \(key)")
    }
}

/// Every optional sensor/model feature that is persisted *and* touched during `AppModel.start()`
/// has to be in the list, or the next launch runs it again and dies again.
/// ⚠ Adding a persisted optional feature to `AppModel` means adding its key here.
@Test func recoveryClearsEveryPersistedOptionalFeature() {
    for key in ["faceHeadTrackingEnabled", "groundHazardsEnabled", "hazardWatchEnabled",
                "signsEnabled", "highFrameRateCamera"] {
        #expect(LaunchRecovery.optionalFeatureKeys.contains(key),
                "\(key) starts a sensor at launch and must be cleared after a failed launch")
    }
}

/// The line is spoken to someone who cannot see the switches, so it must name the loss and say
/// the app still guides — never just "something went wrong".
@Test func theRecoveryLineSaysWhatIsOffAndThatGuidanceRemains() throws {
    let line = try #require(LaunchRecovery.spokenLine(for: .recovered))
    #expect(line.contains("off"))
    #expect(line.lowercased().contains("guidance"))
    #expect(line.hasSuffix("."))
}
