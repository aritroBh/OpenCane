//
//  LaunchRecovery.swift
//  CaneKitLogic
//
//  The rule that stops an optional feature from being able to keep the app from starting.
//
//  Why this file exists (the evidence, from the phone, 2026-09-12):
//    · `canekit-2026-09-12T02-40-53Z.jsonl`, t=17.583 —
//      `{"kind":"face_tracking","supported":true,"enabled":true}`. The walker turned on "Head
//      tracking without AirPods". That switch was persisted in `UserDefaults`.
//    · `canekit-2026-09-12T02-41-13Z.jsonl` — the very next launch. Three records and then the
//      file stops: `session` (t=0.641), `start` (t=0.667) carrying
//      `"face_head_tracking":true, "haptics":false`, and `multicam_depth` (t=0.827). `TripLogger`
//      buffers and flushes every 2 s, so those three reached disk at the t≈2 s flush and nothing
//      survived the t≈4 s one: the process died inside the ARKit warm-up, before the first `lanes`
//      record — which the healthy session immediately before it wrote at t=3.117.
//
//  What that costs, and why it is a P0 rather than a bug: a *persisted* optional feature that
//  kills the launch cannot be turned off by the person it hurts. The switch is on the Hazards
//  card, and the app never gets far enough to draw it. One tap yesterday turns the phone into a
//  brick today, and a blind walker has no way back. So the rule is not "find the crash" — the
//  rule is that no optional feature may ever be in a position to do this:
//
//      An optional feature must never be able to prevent the app from starting.
//      A persisted optional feature that fails degrades to off, says so, and the app runs.
//
//  How it works. `AppModel` writes a marker before it starts any engine and removes it once the
//  app has been alive for `healthySeconds` (or the moment the walker deliberately backgrounds it —
//  a launch someone is using is a launch that worked). Finding the marker still there at the next
//  launch means the previous one never got that far, so this launch runs in `.recovered`: every
//  key in `optionalFeatureKeys` is cleared back to its built-in default and `spokenLine` is said
//  out loud. The next launch after that is normal again.
//
//  This file holds only the decision and the numbers (AGENTS.md hard rule 3); the marker itself is
//  an empty FILE in Application Support (not `UserDefaults` — see `markerName`), handled by
//  `Settings` in AppModel.swift. Owners: `Settings.launchMode` (a `static let`, evaluated before
//  the first setting is read: checks the marker and, when recovering, removes every
//  `optionalFeatureKeys` key); `AppModel.start()` (arms the marker with
//  `Settings.armLaunchMarker()` before any engine starts, and clears it with
//  `Settings.markLaunchHealthy()` after `healthySeconds` or when the walker backgrounds the app);
//  `AppModel.announceLaunchRecovery()` (speaks `spokenLine` and logs `launch_recovery`). The `start`
//  trip-log record carries `launch` (the mode's raw value).
//  Tests: LaunchRecoveryTests.swift (7).
//

import Foundation

/// How this launch is running: with the walker's settings, or with the optional features cleared
/// because the previous launch never reported itself healthy. Raw values are logged as `launch`.
public enum LaunchMode: String, Sendable, Equatable {
    /// The previous launch completed. Every persisted setting is honoured.
    case normal
    /// The previous launch died before it was healthy. The optional features are off for this
    /// launch and their stored values have been cleared, so the walker is not put back into the
    /// same crash on the next start.
    case recovered
}

/// The crash-loop breaker for the launch path. Pure decision; no clock, no storage.
public enum LaunchRecovery {

    /// Seconds a launch must survive before it counts as healthy.
    ///
    /// ⚠ Must be longer than a cold ARKit start: on the phone the healthy session
    /// `canekit-2026-09-12T02-40-53Z.jsonl` published its first `lanes` record at t=3.117 s and the
    /// crashed one (`…02-41-13Z`) died before reaching that point. Ten seconds clears that warm-up
    /// with room for a slow first frame, and is short enough that a walker who launches and starts
    /// walking is past it long before the first waypoint. Pinned by
    /// `theHealthyMarkIsLaterThanAColdArkitStart`.
    public static let healthySeconds: Double = 10

    /// Name of the "a launch is in progress" marker. Written before the engines start, removed
    /// when the launch is healthy. Its *presence* at the next launch is the whole signal.
    ///
    /// ⚠ The app stores this as a **file**, not a `UserDefaults` key, and that is deliberate. This
    /// marker's entire job is to survive a process that dies two seconds after writing it.
    /// `UserDefaults` hands writes to `cfprefsd` and flushes "at appropriate intervals" — Apple's
    /// own reason for deprecating `synchronize()` — which is a guarantee about the common case,
    /// not about a crash inside the launch. A file created with `FileManager` is on disk when the
    /// call returns. The *settings* a recovery clears stay in `UserDefaults` (that is where they
    /// live); if one of those writes were lost to the same crash, the marker would still be there
    /// and the next launch would simply clear them again.
    public static let markerName = "launch-in-progress"

    /// The persisted settings a recovered launch clears, by `UserDefaults` key (they are the
    /// `AppModel` property names).
    ///
    /// Each one turns on a sensor or a model during `AppModel.start()` — the front TrueDepth
    /// camera, the LiDAR ground sampler, the Vision text pass, the 60 fps camera — so each one is
    /// a candidate for a launch that never finishes. None of them is needed to guide a walk:
    /// losing them costs the walker an extra, not the route, the obstacle cues, the haptics or
    /// the beacon.
    ///
    /// ⚠ A new persisted optional feature in `AppModel` belongs in this list, or a launch it kills
    /// repeats forever. Keys are removed (not set false), so a recovered launch gets each
    /// feature's built-in default back — sign reading is ON by default, so it comes back on. `recoveryClearsEveryPersistedOptionalFeature` and
    /// `recoveryNeverClearsCoreGuidanceSettings` pin both halves of that.
    public static let optionalFeatureKeys: [String] = [
        // Front camera face tracking. No longer persisted by `AppModel` (see its `didSet`), but a
        // phone that ran an older build still has the key on disk with `true` in it — this is what
        // removes it.
        "faceHeadTrackingEnabled",
        "groundHazardsEnabled",   // LiDAR drop-off / hole / curb warnings (untuned, off by default)
        "hazardWatchEnabled",     // periodic vision-model hazard check while walking
        "signsEnabled",           // on-device sign reading (Vision, every 3 s)
        "highFrameRateCamera",    // 60 fps camera: double the capture cost and heat
        // Family alerts: a background POST per detection, and the walker's position leaves the
        // phone. Off by default; cleared on a crash loop like every other optional feature.
        "familyAlertsEnabled",
        // Cane-fall detection: an always-on CoreMotion stream with thresholds that have never been
        // measured against a real cane. Exactly the kind of thing a crash loop should clear.
        "fallDetectionEnabled",
        // Deliberately absent: `NaturalVoiceLatch.settingsKey` ("naturalVoiceUnavailable").
        // A refused ElevenLabs key is not a crash-causing feature; clearing it would restore
        // two-voice mixing after quota death (`recoveryNeverClearsTheRefusedVoiceLatch`).
    ]

    /// How to run this launch.
    /// - Parameter previousLaunchCompleted: false when the marker file written by the previous
    ///   launch still exists — i.e. that launch reached `AppModel.start()` but never reached
    ///   `healthySeconds` and was never deliberately backgrounded.
    /// Pinned by `aCompletedPreviousLaunchStartsNormally`, `anIncompletePreviousLaunchRecovers`.
    public static func mode(previousLaunchCompleted: Bool) -> LaunchMode {
        previousLaunchCompleted ? .normal : .recovered
    }

    /// What the app says out loud about this launch, or nil when there is nothing to say.
    ///
    /// Spoken to someone who cannot see that a switch moved, so it names the loss *and* says the
    /// guidance is intact — AGENTS.md "How we engineer" 6: a refused feature warns loudly but still
    /// guides. Kept to one breath: it is said during launch, over the top of "OpenCane ready."
    /// ⚠ "Turn them back on in Hazards." names the Hazards card, which now sits on the Sense tab
    /// (Guide / Sense / Settings); "60 fps camera" lives on Settings → Mount. The words are pinned
    /// only loosely (`theRecoveryLineSaysWhatIsOffAndThatGuidanceRemains`), and are not prefetched.
    public static func spokenLine(for mode: LaunchMode) -> String? {
        switch mode {
        case .normal:
            return nil
        case .recovered:
            return "The last start did not finish, so the extra camera features are off. "
                 + "Guidance and obstacle warnings are on. Turn them back on in Hazards."
        }
    }
}
