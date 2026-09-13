//
//  VoiceShellPolicyTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins VoiceShellPolicy.swift (when the shell may open the microphone on its own —
//  at launch after "OpenCane ready.", and for a follow-up after an answer) and `ScenePhaseReason`
//  (the one word the `scene_phase` trip-log record uses for why the app left the foreground).
//
//  Why these are the tests: every unasked-for microphone open flips the audio session (hard
//  rule 7) and lights the orange dot; a permission prompt raised by an auto-listen on first launch
//  would be a modal nobody can see; a follow-up window during route speech would catch our own
//  lines. Each refusal reason is pinned so a log reader can trust it.
//
//  Source pinned: `ios/Logic/Sources/CaneKitLogic/VoiceShellPolicy.swift` (`followUpSeconds` 5,
//  `followUpSecondsNavigating` 3, `speechDrainCap` 15, `readyLine`, `noLidarLine`, `launchLine(lidarSupported:)`,
//  `launchListen(...)`, `followUp(...)`,
//  `ScenePhaseReason.classify`). Callers: `AppModel` (`VoiceShell.swift`, C2's wiring) and
//  `AppModel.scenePhaseChanged`.
//

import Testing
@testable import CaneKitLogic

@Suite("Voice shell policy")
struct VoiceShellPolicyTests {

    /// Step 67: the launch says "OpenCane ready." and nothing else — no menu, no instructions (phone
    /// log `canekit-2026-09-13T15-48-34Z.jsonl`: "OpenCane ready." then the 76-character eight-word
    /// menu before the microphone opened; owner: "It should just be 'OpenCane ready' and then boom").
    /// A phone without LiDAR says that instead, because obstacle warnings cannot work. The listening
    /// tone follows (`launchListen`).
    @Test func launchSaysOnlyOpenCaneReady() {
        #expect(VoiceShellPolicy.readyLine == "OpenCane ready.")
        #expect(VoiceShellPolicy.launchLine(lidarSupported: true) == "OpenCane ready.")
        #expect(VoiceShellPolicy.noLidarLine == "OpenCane. This phone has no LiDAR.")
        #expect(VoiceShellPolicy.launchLine(lidarSupported: false) == VoiceShellPolicy.noLidarLine)
        for line in [VoiceShellPolicy.launchLine(lidarSupported: true), VoiceShellPolicy.launchLine(lidarSupported: false)] {
            let lower = line.lowercased()
            for menuWord in ["say ", "route", "where am i", "help", "emergency"] {
                #expect(!lower.contains(menuWord), "\(line) contains \(menuWord)")
            }
        }
    }

    /// Everything granted, nothing else owns the mic: listen.
    @Test func launchListensWhenEverythingIsGranted() {
        let v = VoiceShellPolicy.launchListen(enabled: true, muted: false, speechAuthorized: true,
                                              micGranted: true, micOwnedElsewhere: false,
                                              recoveredLaunch: false, cameraDenied: false)
        #expect(v == .listen)
        #expect(VoiceShellPolicy.speechDrainCap == 15)
    }

    /// A first launch has no speech / microphone grant yet: the menu is spoken, the mic is not
    /// opened (the first Talk press asks), so no system prompt appears unbidden.
    @Test func launchListenSkipsWhenAPermissionPromptWouldAppear() {
        let noSpeech = VoiceShellPolicy.launchListen(enabled: true, muted: false, speechAuthorized: false,
                                                     micGranted: true, micOwnedElsewhere: false,
                                                     recoveredLaunch: false, cameraDenied: false)
        #expect(noSpeech == .skip(reason: "permission_prompt"))
        let noMic = VoiceShellPolicy.launchListen(enabled: true, muted: false, speechAuthorized: true,
                                                  micGranted: false, micOwnedElsewhere: false,
                                                  recoveredLaunch: false, cameraDenied: false)
        #expect(noMic == .skip(reason: "permission_prompt"))
    }

    /// `CANEKIT_UITEST` / `CANEKIT_MUTE`: screenshots stay deterministic, no mic in the simulator.
    /// The setting off and the siren watcher owning the mic are refusals too.
    @Test func launchListenSkipsUnderAutomation() {
        let muted = VoiceShellPolicy.launchListen(enabled: true, muted: true, speechAuthorized: true,
                                                  micGranted: true, micOwnedElsewhere: false,
                                                  recoveredLaunch: false, cameraDenied: false)
        #expect(muted == .skip(reason: "muted"))
        let off = VoiceShellPolicy.launchListen(enabled: false, muted: false, speechAuthorized: true,
                                                micGranted: true, micOwnedElsewhere: false,
                                                recoveredLaunch: false, cameraDenied: false)
        #expect(off == .skip(reason: "disabled"))
        let owned = VoiceShellPolicy.launchListen(enabled: true, muted: false, speechAuthorized: true,
                                                  micGranted: true, micOwnedElsewhere: true,
                                                  recoveredLaunch: false, cameraDenied: false)
        #expect(owned == .skip(reason: "mic_owned"))
    }

    /// A launch that recovered from a crash, or one already warning loudly about a denied camera,
    /// does not add a microphone flip on top.
    @Test func launchListenSkipsOnARecoveredLaunch() {
        let recovered = VoiceShellPolicy.launchListen(enabled: true, muted: false, speechAuthorized: true,
                                                      micGranted: true, micOwnedElsewhere: false,
                                                      recoveredLaunch: true, cameraDenied: false)
        #expect(recovered == .skip(reason: "recovered_launch"))
        let camera = VoiceShellPolicy.launchListen(enabled: true, muted: false, speechAuthorized: true,
                                                   micGranted: true, micOwnedElsewhere: false,
                                                   recoveredLaunch: false, cameraDenied: true)
        #expect(camera == .skip(reason: "camera_denied"))
    }

    /// Idle, nothing queued: a 5 s window. Route lines waiting: no window (they would be heard).
    @Test func followUpSkipsWhileRouteLinesAreQueued() {
        let open = VoiceShellPolicy.followUp(enabled: true, navigating: false, navigatingEnabled: false,
                                             queuedLines: 0, answerWasQuestion: false)
        #expect(open == .open(seconds: 5))
        let queued = VoiceShellPolicy.followUp(enabled: true, navigating: false, navigatingEnabled: false,
                                               queuedLines: 2, answerWasQuestion: false)
        #expect(queued == .skip(reason: "lines_queued"))
        let off = VoiceShellPolicy.followUp(enabled: false, navigating: false, navigatingEnabled: false,
                                            queuedLines: 0, answerWasQuestion: false)
        #expect(off == .skip(reason: "disabled"))
    }

    /// While navigating the window is OFF by default (every mic open flips the audio session and
    /// invites the route-change revert, hard rule 7); if the owner turns it on, it is 3 s, not 5.
    @Test func followUpShortensWhileNavigating() {
        let defaultWalk = VoiceShellPolicy.followUp(enabled: true, navigating: true, navigatingEnabled: false,
                                                    queuedLines: 0, answerWasQuestion: false)
        #expect(defaultWalk == .skip(reason: "navigating"))
        let optIn = VoiceShellPolicy.followUp(enabled: true, navigating: true, navigatingEnabled: true,
                                              queuedLines: 0, answerWasQuestion: false)
        #expect(optIn == .open(seconds: 3))
        #expect(VoiceShellPolicy.followUpSeconds == 5)
        #expect(VoiceShellPolicy.followUpSecondsNavigating == 3)
    }

    /// An answer that itself asked a question (the emergency prompt) opens the window even while
    /// navigating: the walker was asked to say yes or no.
    @Test func aQuestionAlwaysGetsItsAnswerWindow() {
        let prompt = VoiceShellPolicy.followUp(enabled: false, navigating: true, navigatingEnabled: false,
                                               queuedLines: 0, answerWasQuestion: true)
        #expect(prompt == .open(seconds: 3))
        let promptIdle = VoiceShellPolicy.followUp(enabled: false, navigating: false, navigatingEnabled: false,
                                                   queuedLines: 0, answerWasQuestion: true)
        #expect(promptIdle == .open(seconds: 5))
    }
}

@Suite("Scene phase reason")
struct ScenePhaseReasonTests {

    /// Background with protected data gone, or after the will-lock notification: "locked".
    @Test func lockIsToldApartFromBackgrounding() {
        #expect(ScenePhaseReason.classify(phase: .background, protectedDataAvailable: false,
                                          sawProtectedDataWillBecomeUnavailable: false) == "locked")
        #expect(ScenePhaseReason.classify(phase: .background, protectedDataAvailable: true,
                                          sawProtectedDataWillBecomeUnavailable: true) == "locked")
    }

    /// Background with protected data still available and no lock warning: the walker (or iOS)
    /// switched away — "backgrounded".
    @Test func plainBackgroundIsBackgrounded() {
        #expect(ScenePhaseReason.classify(phase: .background, protectedDataAvailable: true,
                                          sawProtectedDataWillBecomeUnavailable: false) == "backgrounded")
    }

    /// Inactive (control centre, a call, the lock animation) and active are named as such,
    /// whatever the protected-data flags say.
    @Test func inactiveAndActiveAreNamed() {
        #expect(ScenePhaseReason.classify(phase: .inactive, protectedDataAvailable: false,
                                          sawProtectedDataWillBecomeUnavailable: true) == "inactive")
        #expect(ScenePhaseReason.classify(phase: .active, protectedDataAvailable: false,
                                          sawProtectedDataWillBecomeUnavailable: true) == "foreground")
    }
}
