//
//  VoiceShellPolicy.swift
//  CaneKitLogic
//
//  When the voice shell may open the microphone without being asked (Step 58), and the one word
//  the `scene_phase` record uses for why the app left the foreground (Step 60).
//
//  Why this exists: owner decision 2026-09-13 — at launch the app speaks the menu by itself and
//  then listens by itself; after an answer it may listen again for a follow-up. Every one of
//  those unasked-for microphone opens flips the audio session to `.playAndRecord` (hard rule 7),
//  lights the orange dot, and can raise a permission prompt nobody can see. The rules for when
//  that is allowed have numbers in them, so they live here with tests, and the app only applies
//  the verdict. Every number is [H] until a walk log tunes it.
//
//  Key invariants:
//    · Launch listen is refused when a permission prompt would appear (speech or microphone not
//      yet granted), under automation (`CANEKIT_UITEST` / `CANEKIT_MUTE`), when the setting is
//      off, when SoundWatcher owns the microphone, on a recovered launch, and with a denied camera.
//    · Follow-up: 5 s idle; OFF while navigating unless the owner opts in (then 3 s); never while
//      sub-safety lines are queued (the mic would hear them); a prompt that asked a question (the
//      emergency prompt) always gets its window.
//    · Pure and nonisolated.
//
//  Owner / callers: `AppModel` (`VoiceShell.swift`, C2's wiring: `launchListen` after the menu
//  drains, `followUp` at the end of every answer), `AppModel.scenePhaseChanged`
//  (`ScenePhaseReason.classify`).
//  Tests: VoiceShellPolicyTests.swift (7) and ScenePhaseReasonTests (3).
//

import Foundation

/// Decides the unasked-for microphone opens of the voice shell.
public enum VoiceShellPolicy {

    /// Follow-up window while idle, seconds. [H] 5 s: long enough for "repeat", short enough that
    /// the orange dot is gone before it is noticed.
    public static let followUpSeconds: Double = 5

    /// Follow-up window while navigating (opt-in only), seconds. [H] 3 s: route lines arrive every
    /// few seconds; a longer window catches one.
    public static let followUpSecondsNavigating: Double = 3

    /// Longest the launch sequence waits for the speech queue to drain before it gives up on the
    /// auto-listen, seconds. [H] 15 s: "OpenCane ready." + the menu + a warning or two.
    public static let menuWaitCap: Double = 15

    /// Verdict for the launch listen.
    public enum LaunchListen: Sendable, Equatable {
        /// Open the microphone once (`VoiceListenMode.launch`).
        case listen
        /// Do not; the reason is written to `voice_menu {action: skipped, reason}`.
        case skip(reason: String)
    }

    /// Whether to open the microphone once after the launch menu has been spoken.
    /// First refusal wins, in this order: disabled, muted, permission_prompt, mic_owned,
    /// recovered_launch, camera_denied.
    /// - Parameters:
    ///   - enabled: the "Listen on launch" setting.
    ///   - muted: `SpeechQueue.muted` (automation).
    ///   - speechAuthorized: `SFSpeechRecognizer.authorizationStatus() == .authorized`.
    ///   - micGranted: `AVAudioApplication.shared.recordPermission == .granted`.
    ///   - micOwnedElsewhere: `SoundWatcher` owns the microphone session.
    ///   - recoveredLaunch: `LaunchRecovery` disabled optional features this launch.
    ///   - cameraDenied: the camera permission is denied (the app is already warning loudly).
    public static func launchListen(enabled: Bool, muted: Bool, speechAuthorized: Bool, micGranted: Bool,
                                    micOwnedElsewhere: Bool, recoveredLaunch: Bool,
                                    cameraDenied: Bool) -> LaunchListen {
        guard enabled else { return .skip(reason: "disabled") }
        guard !muted else { return .skip(reason: "muted") }
        guard speechAuthorized, micGranted else { return .skip(reason: "permission_prompt") }
        guard !micOwnedElsewhere else { return .skip(reason: "mic_owned") }
        guard !recoveredLaunch else { return .skip(reason: "recovered_launch") }
        guard !cameraDenied else { return .skip(reason: "camera_denied") }
        return .listen
    }

    /// Verdict for a follow-up listen after an answer.
    public enum FollowUp: Sendable, Equatable {
        /// Open the microphone with this `UtteranceEndDetector.maxListen` cap.
        case open(seconds: Double)
        /// Do not; the reason is written to `voice_followup {action: skipped, reason}`.
        case skip(reason: String)
    }

    /// Whether to open a follow-up window once the answer has finished speaking.
    /// A question the app asked (`answerWasQuestion`) always opens its window (the emergency
    /// prompt needs a yes or no); otherwise: lines_queued, disabled, navigating (unless opted in).
    /// - Parameters:
    ///   - enabled: the "Follow-up listening" setting.
    ///   - navigating: `NavigationEngine.isNavigating`.
    ///   - navigatingEnabled: the owner's opt-in for follow-ups while walking (default off).
    ///   - queuedLines: `SpeechQueue.queuedLineCount` — sub-safety lines still waiting to speak.
    ///   - answerWasQuestion: the answer ended in a question the walker must answer.
    public static func followUp(enabled: Bool, navigating: Bool, navigatingEnabled: Bool,
                                queuedLines: Int, answerWasQuestion: Bool) -> FollowUp {
        let seconds = navigating ? followUpSecondsNavigating : followUpSeconds
        if answerWasQuestion { return .open(seconds: seconds) }
        guard queuedLines == 0 else { return .skip(reason: "lines_queued") }
        guard enabled else { return .skip(reason: "disabled") }
        if navigating, !navigatingEnabled { return .skip(reason: "navigating") }
        return .open(seconds: seconds)
    }
}

/// The one word written as `reason` on every `scene_phase` trip-log record (Step 60): was the
/// phone locked, or did the app merely leave the foreground? A locked phone pauses ARKit and
/// therefore obstacle warnings; the demo checklist (Auto-Lock Never, Guided Access) exists to
/// prevent it, and the log must show whether it happened.
public enum ScenePhaseReason {

    /// SwiftUI's `ScenePhase`, mirrored so this package stays Foundation-only.
    public enum Phase: Sendable, Equatable {
        case active, inactive, background
    }

    /// - Parameters:
    ///   - phase: the new scene phase.
    ///   - protectedDataAvailable: `UIApplication.shared.isProtectedDataAvailable` at that moment
    ///     (false once the device is locked with data protection).
    ///   - sawProtectedDataWillBecomeUnavailable: the app observed
    ///     `protectedDataWillBecomeUnavailableNotification` since it was last active.
    /// - Returns: "foreground", "inactive", "locked" or "backgrounded".
    public static func classify(phase: Phase, protectedDataAvailable: Bool,
                                sawProtectedDataWillBecomeUnavailable: Bool) -> String {
        switch phase {
        case .active: return "foreground"
        case .inactive: return "inactive"
        case .background:
            return (!protectedDataAvailable || sawProtectedDataWillBecomeUnavailable) ? "locked" : "backgrounded"
        }
    }
}
