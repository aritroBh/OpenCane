//
//  HandsFreeIntents.swift
//  CaneKit
//
//  The controls that used to exist only on screen, given a voice — so a walker with the phone
//  clamped to the cane can reach them. The seven route intents live in `AppIntents.swift`; this
//  file is everything the *cards* could do and the voice could not.
//
//  Why these, and why only these. An app may register at most **ten App Shortcuts** (the
//  phrase-driven, zero-setup kind that Siri, Spotlight and the Action button's "Choose a Shortcut"
//  list show without the walker building anything — Apple DTS, developer forums 787555).
//  `AppIntents.swift` uses six. The four spent here are the four a *blind walker* cannot do
//  without:
//    1. **Status** — the spoken version of the whole screen. Every card reports its health
//       visually and nothing reported it aloud, so the only evidence that obstacle detection had
//       stopped was that nothing happened, which is also what working sounds like. Silence must
//       never be the only sign that a safety channel died.
//    2. **Ask** — the one thing no other control offers: a question about what is actually in
//       front of the cane. It is also the top unmet request blind users make of this class of app
//       ("a shortcut that takes a picture and answers, hands-free" — AppleVis, "Feature request
//       for blindness AI apps"; none of Seeing AI, Be My Eyes or Aira's Access AI had one).
//    3. **Cane haptics on / off** — the only *safety-channel* control with no spoken equivalent,
//       and the only one whose right value changes mid-walk (a crowded corridor, a false-positive
//       stretch, a hand that needs the cane quiet). Everything else on the cards is set up before
//       leaving.
//    4. **Talk to OpenCane** — the Action button target: one press opens the app and starts
//       listening, so a walker with both hands on the cane can ask anything (status, scene,
//       places, posts) with no wake word and no screen.
//  What did NOT get a slot, and why: Recenter (the watch has it, and the app re-zeroes itself
//  after three straight-walking fixes), the hazard switches (configuration, set before the
//  walk, not during it), and "Navigate to CIF from here" (the Guide card button is unchanged
//  and "Take me to CIF in OpenCane" reaches the same route-file waypoint by Siri). All are
//  still reachable hands-free — as plain `AppIntent`s, which the Shortcuts app lists as actions
//  and which can be put on the Action button by building a one-step shortcut around them. Only
//  the automatic, phrase-driven kind is capped at ten.
//
//  Deliberately NOT built: a spoken back-and-forth conversation. See `QuestionPrompt`
//  (CaneKitLogic) for the evidence — users want to ask, but the measured complaint about AI
//  answers is their length, and conversational video assistants are weakest on exactly the moving
//  scenes a walker is in. One question, one sentence, no follow-up.
//
//  Owner: module `app-core` (docs/CODE_REFERENCE.md). Like the intents in `AppIntents.swift`,
//  every `perform()` only forwards to a public `AppModel` method, so voice, watch and screen share
//  one code path.
//
//  Key invariants:
//    · ⚠ `supportedModes` stays `.foreground(.immediate)` on every intent here, for the same
//      reason as the other seven: ARKit obstacle warnings only run while the app is frontmost, and
//      nothing may start guidance, or occupy the voice, with the safety channel off.
//    · ⚠ Every answer these intents speak is `.scene`, the lowest speech priority, so an obstacle
//      name, a route line or "Head height." interrupts it. A status report or a scene answer must
//      never delay a warning.
//    · ⚠ Four App Shortcuts are added to `CaneKitShortcuts` in `AppIntents.swift`, taking it to
//      the limit of ten. Anything new after this is a plain `AppIntent`, not an `AppShortcut`.
//
//  Threading / isolation: every `perform()` and every `AppModel` extension method is main actor
//  (target default; `perform()` is also marked `@MainActor`). The enums are value types.
//
//  Tests: the words and thresholds are pure and pinned in CaneKitLogic — `StatusSummaryTests`
//  (every status clause and `hapticsLine`), `QuestionPromptTests` (question cleaning),
//  `CueProfileTests` (`namesLimitLine`, appended by `setOption` when names go on under a limiting
//  level or place), `HeadNodDetectorTests` (the untuned `nodToTalk` gesture). The intents
//  themselves cannot be driven by XCUITest; verify phrases on the phone.
//

import AppIntents
import CaneKitLogic
import Foundation

// MARK: - Model methods the intents call

/// The hands-free half of `AppModel`'s public surface: spoken status, one scene question, the
/// cane-haptics switch and the voice-safe feature switches. An extension here (not in
/// AppModel.swift) so the voice contract and its safety reasoning sit next to the intents that
/// use it; it adds no stored state. Also called by `ConversationCoordinator`.
extension AppModel {

    /// Speaks the answer to "is this thing working?": obstacle detection, GPS, audio, haptics,
    /// route, battery — in that fixed order, every time.
    ///
    /// This is the spoken version of the whole screen. Every clause is decided by
    /// `StatusSummary` (CaneKitLogic, with the thresholds and the tests); this method only
    /// gathers the live facts and speaks them.
    ///
    /// Each clause is spoken as its own line rather than one long sentence on purpose: an
    /// obstacle warning then cuts a single clause and the rest stay queued behind it, instead of
    /// the whole report being cut mid-way (`SpeechQueue.say` re-queues a pre-empted line to resume
    /// from the clause it was cut in, at most `SpeechResume.maxResumes` = 3 times — Step 37).
    ///
    /// Priority `.scene` and a 20 s TTL: the answer is information, never a warning, so anything
    /// the sensors say outranks it, and a clause still waiting after 20 s of warnings is stale
    /// enough to drop. The battery clause is omitted when the level is unknown (simulator).
    /// Logs `status_spoken {text}` with the whole report as one sentence.
    /// Callers: `StatusIntent` (Siri / Shortcuts / the Action button). `ConversationCoordinator`
    /// builds its own `StatusFacts` for voice status questions rather than calling this.
    func speakStatus() {
        let facts = StatusFacts(
            lidarSupported: lidarSupported,
            obstacleDetectionRunning: depth.isRunning,
            depthFps: depth.fps,
            gpsFix: location.fix != nil,
            gpsAccuracyM: location.fix?.accuracy ?? -1,
            locationDenied: location.denied,
            headphonesConnected: audioRoute.headphonesConnected,
            headphoneName: audioRoute.outputName,
            // Either head-yaw source counts: the beacon uses whichever one is live
            // (`HeadYawSelector`), so the walker only needs to know that one of them is.
            headTracking: head.isConnected || faceHead.isTracking,
            hapticsHealthy: haptics.isHealthy,
            hapticsSilenced: hapticsSilenced,
            watchReachable: watch.isReachable,
            routeRunning: nav.isNavigating,
            routeInstruction: nav.instruction,
            metresToNext: nav.distanceToNext,
            batteryPercent: batteryPercent)
        for line in StatusSummary.lines(facts) { speech.say(line, .scene, ttl: 20) }
        logger.event("status_spoken", ["text": StatusSummary.sentence(facts)])
    }

    /// Asks the vision model one question about the frame in front of the cane and speaks one
    /// sentence back (`SceneDescriber.ask`, `.scene` priority, `CloudSceneGate` on the reply).
    /// - Parameter question: what the walker said; Siri's transcription arrives unedited and is
    ///   cleaned by `QuestionPrompt.clean`.
    /// - Returns: false when nothing was sent — a wordless question (spoken "I did not catch a
    ///   question.") or a description already in flight ("Still describing the previous scene.").
    ///   Without a cloud model the question is downgraded to a plain description, which still
    ///   returns true. The outcome is logged later as `describe_result` with `question`.
    /// Logs `ask {question, provider}` first, so a question that never produced an answer is visible.
    /// Callers: `AskSceneIntent`, `ConversationCoordinator` (scene questions by voice).
    @discardableResult
    func askAboutScene(_ question: String) -> Bool {
        logger.event("ask", ["question": question,
                             "provider": describer.providerName ?? "none"])
        return describer.ask(question)
    }

    /// Silences or un-silences the cane buzz and says what the walker will get instead.
    ///
    /// It speaks even when nothing changed ("say it again" must confirm the state, not go
    /// silent): a walker who cannot see the switch has no other way to learn where obstacle cues
    /// are going. The line is `StatusSummary.hapticsLine`, so the wording is the same one the
    /// status report and `announceChannels` use — one fact, one sentence, everywhere.
    /// - Parameter silenced: true to silence the cane.
    /// Logs `haptics_silenced {silenced, by: "voice"}`.
    /// Callers: `SilenceHapticsIntent`, `ConversationCoordinator` ("silence the cane" by voice);
    /// the on-screen "Silence haptics" toggle still writes `hapticsSilenced` directly (it is
    /// visible, so it needs no spoken confirmation).
    func setHapticsSilenced(_ silenced: Bool) {
        hapticsSilenced = silenced
        // `.nav`, not `.scene`: this is a statement about which safety channel is live, the same
        // class of line as `announceChannels` at route start and "Recentered." — both `.nav`. It is
        // still below "Head height." and never pre-empts a `.safety` cue (review round 1).
        speech.say(StatusSummary.hapticsLine(healthy: haptics.isHealthy,
                                             silenced: hapticsSilenced,
                                             watchReachable: watch.isReachable),
                   .nav, ttl: 10)
        logger.event("haptics_silenced", ["silenced": silenced, "by": "voice"])
    }

    /// Turns one of the optional features on or off by voice and says the new state out loud.
    ///
    /// Only features that are safe to change while walking are reachable here. "Both cameras" is
    /// deliberately absent: it *pauses obstacle detection*, and a voice command that quietly turns
    /// the safety channel off is exactly what must not exist. "Head tracking without AirPods" is
    /// absent too — it restarts the AR session (1–2 s with no depth) and is a bench setting.
    /// - Parameters:
    ///   - option: which feature.
    ///   - enabled: the new state.
    /// Logs `option_set {option, requested, actual, by: "voice"}` — `actual` differing from
    /// `requested` is a synchronous refusal.
    /// Callers: `SetOptionIntent` (Shortcuts / the Action button; not an App Shortcut),
    /// `ConversationCoordinator` (fast-path settings by voice).
    func setOption(_ option: HandsFreeOption, enabled: Bool) {
        switch option {
        case .dropOffs: groundHazardsEnabled = enabled
        case .signs: signsEnabled = enabled
        case .hazardWatch: hazardWatchEnabled = enabled
        case .namePeople: namePeopleEnabled = enabled
        case .obstacleNames: obstacleNamesEnabled = enabled
        case .beacon: beaconEnabled = enabled
        case .sirens: dangerSoundsEnabled = enabled
        case .nodToTalk: nodToTalkEnabled = enabled
        }
        // Say the state, not "done": the walker cannot see the switch move. `dangerSoundsEnabled`
        // can refuse itself (a denied microphone, a degraded audio route), so the line is read back
        // from the property rather than from the request. ⚠ That read is synchronous: an ASYNC
        // refusal (the 0.25 s input-format settle in `SoundWatcher.startEngine`) lands after this
        // line is spoken, so the walker hears "on" followed within ~a second by the watcher's own
        // failure line switching it back off. Announcing the request is still right — most
        // failures are synchronous and the async correction arrives immediately — but never claim
        // here that a refused feature cannot be announced as on first (AGENTS.md rule 1).
        //
        // ⚠ Turning one of these OFF also says what stops, and is spoken at `.nav`, not `.scene`
        // (review round 1: "voice can silence warning subsets mid-walk"). Four of the eight options
        // (drop-offs, hazard watch, obstacle names, sirens) are warning channels, and a one-word "off" that a `.scene` line could drop behind other
        // speech is not enough acknowledgement for switching a warning channel off. `.nav` is the
        // same priority `announceChannels` uses for exactly this kind of statement, and still
        // below "Head height.". The core obstacle and head-height cues are not reachable from
        // here at all — `obstacleNames` only stops the *naming*, and its line says so.
        let on = isOptionEnabled(option)
        // Names on under a level or place that limits them: say so, or "on" is a silent promise
        // (`CueRules.namesLimitLine`, Step 36 review).
        let limit = (option == .obstacleNames && on) ? cueRules.namesLimitLine.map { " \($0)" } ?? "" : ""
        speech.say(on ? "\(option.spokenName) on.\(limit)"
                      : "\(option.spokenName) off. \(option.offConsequence)", .nav, ttl: 10)
        logger.event("option_set", ["option": option.rawValue, "requested": enabled,
                                    "actual": isOptionEnabled(option), "by": "voice"])
    }

    /// The live value of an optional feature, read back after `setOption` so the spoken line is
    /// what happened rather than what was asked for. Main actor; a plain property read, no side
    /// effects. Callers: `setOption` (twice: the spoken line and the `actual` log field).
    /// - Parameter option: which feature.
    /// - Returns: whether it is on right now.
    func isOptionEnabled(_ option: HandsFreeOption) -> Bool {
        switch option {
        case .dropOffs: groundHazardsEnabled
        case .signs: signsEnabled
        case .hazardWatch: hazardWatchEnabled
        case .namePeople: namePeopleEnabled
        case .obstacleNames: obstacleNamesEnabled
        case .beacon: beaconEnabled
        case .sirens: dangerSoundsEnabled
        case .nodToTalk: nodToTalkEnabled
        }
    }
}

// MARK: - Parameter types

/// On or off, said out loud. Used by the haptics intent and the feature intent so a phrase can
/// carry the state ("Turn cane haptics off in OpenCane") — an App Shortcut phrase can interpolate
/// an `AppEnum`, never a `Bool` or a `String`.
enum SwitchState: String, AppEnum {
    // `on` = the feature (or, for `SilenceHapticsIntent`, the cane buzz) runs; `off` = it does not.
    case on, off

    /// Parameter type name in Shortcuts.
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "State"
    /// The words Siri matches. The synonyms are the ones a walker actually says: "quiet" and
    /// "silent" for off, "back on" for on.
    static let caseDisplayRepresentations: [SwitchState: DisplayRepresentation] = [
        .on: DisplayRepresentation(title: "on", synonyms: ["on", "back on", "enabled"]),
        .off: DisplayRepresentation(title: "off", synonyms: ["off", "quiet", "silent", "disabled"]),
    ]

    /// The Bool the model wants.
    var isOn: Bool { self == .on }
}

/// The optional features that are safe to switch by voice while walking.
///
/// ⚠ Deliberately incomplete. "Both cameras" pauses obstacle detection and "Head tracking without
/// AirPods" restarts the AR session; neither may be flipped by a phrase mid-walk. The purely
/// visual switches (live camera view, portrait, mirror, 60 fps) are for a sighted helper on the
/// bench and have nothing to say to a walker.
///
/// `nodToTalk` (Step 3 of the nod plan) is the one non-hazard option here: it is safe mid-walk (it
/// only ever *starts* listening, never stops guidance) and it is the option a walker with both
/// hands busy most wants to switch on by voice. ⚠ Its gesture detector is untuned
/// (`HeadNodDetector`, HeadNodDetectorTests) and the feature ships off, unpersisted.
enum HandsFreeOption: String, AppEnum {
    // Each case maps to one `AppModel` switch (`setOption` / `isOptionEnabled`), and its raw value
    // is written to the trip log as `option_set.option`:
    //   `dropOffs` → `groundHazardsEnabled` (persisted, default off) · `signs` → `signsEnabled`
    //   (persisted, default on) · `hazardWatch` → `hazardWatchEnabled` (persisted, default off) ·
    //   `namePeople` → `namePeopleEnabled` (persisted, default off; experimental) · `obstacleNames` →
    //   `obstacleNamesEnabled` (persisted, default off since Step 36) · `beacon` → `beaconEnabled`
    //   (persisted, default on) · `sirens` → `dangerSoundsEnabled` (not persisted, can refuse
    //   itself) · `nodToTalk` → `nodToTalkEnabled` (not persisted, untuned).
    case dropOffs, signs, hazardWatch, namePeople, obstacleNames, beacon, sirens, nodToTalk

    /// Parameter type name in Shortcuts.
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "OpenCane feature"
    /// Titles match the switch labels on the Hazards card so the spoken name and the screen name
    /// are the same thing; synonyms are what a walker would say instead.
    static let caseDisplayRepresentations: [HandsFreeOption: DisplayRepresentation] = [
        .dropOffs: DisplayRepresentation(title: "Detect drop-offs", synonyms: ["drop-offs", "drop offs", "curbs", "steps"]),
        .signs: DisplayRepresentation(title: "Read signs", synonyms: ["signs", "sign reading"]),
        .hazardWatch: DisplayRepresentation(title: "Hazard watch", synonyms: ["hazard watch", "hazards"]),
        .namePeople: DisplayRepresentation(title: "Name people ahead", synonyms: ["people", "naming people"]),
        .obstacleNames: DisplayRepresentation(title: "Speak obstacle names", synonyms: ["obstacle names", "object names"]),
        .beacon: DisplayRepresentation(title: "Audio beacon", synonyms: ["beacon", "the clicking"]),
        .sirens: DisplayRepresentation(title: "Listen for sirens and horns", synonyms: ["sirens", "horns", "sirens and horns"]),
        .nodToTalk: DisplayRepresentation(title: "Nod to talk", synonyms: ["nod", "nod to talk", "head nod"]),
    ]

    /// How the confirmation line names the feature ("Read signs on."). Same words as the switch.
    var spokenName: String {
        switch self {
        case .dropOffs: "Drop-off detection"
        case .signs: "Sign reading"
        case .hazardWatch: "Hazard watch"
        case .namePeople: "Naming people ahead"
        case .obstacleNames: "Obstacle names"
        case .beacon: "The audio beacon"
        case .sirens: "Siren and horn listening"
        case .nodToTalk: "Nod to talk"
        }
    }

    /// What the walker stops getting when this feature goes off, said out loud with the "off".
    ///
    /// ⚠ Four of these eight are warning channels (drop-offs, hazard watch, obstacle names,
    /// sirens), and "off" on its own is not an acknowledgement a
    /// blind walker can act on — they cannot see which switch moved, and the difference between
    /// "the cane stopped buzzing because I turned something off" and "the cane stopped buzzing
    /// because it broke" is the whole safety question. `obstacleNames` gets the most important line
    /// of the eight: turning it off leaves the cane buzzing, and the walker has to know that.
    var offConsequence: String {
        switch self {
        case .dropOffs: "Curbs, drop-offs and holes will not be announced."
        case .signs: "Signs will not be read out."
        case .hazardWatch: "The camera will not check the path ahead for hazards."
        case .namePeople: "People ahead will not be named."
        case .obstacleNames: "Obstacles are still felt on the cane, but not named."
        case .beacon: "The direction click is off. Route instructions still come."
        case .sirens: "Sirens and horns will not be called out."
        case .nodToTalk: "Nodding will not start listening; use the button or the Action button."
        }
    }
}

// MARK: - App Shortcuts (four of the ten; registered in AppIntents.swift)

/// Siri / Action button "How is OpenCane doing": speaks obstacle detection, GPS, audio, haptics,
/// route and battery. The spoken version of every card on the screen, for a walker who cannot see
/// one of them.
struct StatusIntent: AppIntent {
    /// Shown in Shortcuts and the Action button picker.
    static let title: LocalizedStringResource = "Status check"
    /// Subtitle in Shortcuts.
    static let description = IntentDescription("Says whether obstacle detection, GPS, AirPods, haptics and the route are working.")
    /// ⚠ Foreground only, like every intent in this app: the status it reports is the status of
    /// engines that only run while the app is frontmost, so reporting from the background would
    /// describe a system that is not running.
    static let supportedModes: IntentModes = .foreground(.immediate)

    /// Waits for the model (cold launch) and speaks the status lines.
    /// Throws `IntentSupport.NotReady` if the model never appears within 2 s.
    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        model.speakStatus()
        return .result()
    }
}

/// Siri / Action button "Ask OpenCane about the scene": one question about what the cane-mounted
/// camera is looking at, one sentence back.
///
/// The question is a `String` parameter and not part of the phrase, because an App Shortcut phrase
/// can only interpolate an `AppEnum` / `AppEntity` — the same reason "Take me somewhere in OpenCane"
/// exists beside "Take me to Grainger in OpenCane". Siri therefore asks "What do you want to know?"
/// and runs the intent again with the answer.
struct AskSceneIntent: AppIntent {
    /// Shown in Shortcuts and the Action button picker.
    static let title: LocalizedStringResource = "Ask about the scene"
    /// Subtitle in Shortcuts.
    static let description = IntentDescription("Asks a question about what the camera can see and answers in one sentence.")
    /// ⚠ Foreground only: the camera frame comes from the ARKit session, which only runs frontmost.
    static let supportedModes: IntentModes = .foreground(.immediate)

    /// What the walker wants to know ("is there a bench on my left", "what does that sign say").
    /// Siri asks for it when the phrase did not carry one.
    @Parameter(title: "Question", requestValueDialog: "What do you want to know?")
    var question: String?

    /// Waits for the model, then `AppModel.askAboutScene(_:)`. An empty question throws back to
    /// Siri so it asks again rather than sending the model a blank prompt.
    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        let text = (question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw $question.needsValueError("What do you want to know?") }
        model.askAboutScene(text)
        return .result()
    }
}

/// Siri / Action button "Silence the cane": stops (or restores) the cane buzz and says where
/// obstacle cues go instead.
///
/// The state parameter is optional and defaults to **off** (silenced) on purpose. The phrase a
/// walker says in a hurry is "silence the cane" — the urgent direction is always toward quiet;
/// nobody urgently needs the buzzing back. Un-silencing is the explicit "turn cane haptics on".
struct SilenceHapticsIntent: AppIntent {
    /// Shown in Shortcuts and the Action button picker.
    static let title: LocalizedStringResource = "Cane haptics on or off"
    /// Subtitle in Shortcuts.
    static let description = IntentDescription("Silences the cane buzz, or turns it back on, and says where obstacle cues go.")
    /// ⚠ Foreground only, like every intent here: silencing the cane re-routes obstacle cues to
    /// speech and the watch, which are only running while the app is frontmost.
    static let supportedModes: IntentModes = .foreground(.immediate)

    /// On or off; nil means off (see the type's doc comment).
    @Parameter(title: "State")
    var state: SwitchState?

    /// Waits for the model and calls `AppModel.setHapticsSilenced(_:)`, which speaks the result.
    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        // `state == .on` means "haptics on", which is `silenced == false`.
        model.setHapticsSilenced(!(state?.isOn ?? false))
        return .result()
    }
}

// MARK: - Intents without an App Shortcut slot
//
// These are ordinary `AppIntent`s. They appear in the Shortcuts app as actions and can be put on
// the Action button by building a one-step shortcut around them; what they do not get is an
// automatic Siri phrase, because the ten App Shortcut slots are full. See the file header for why
// these two (and `NavigateToCIFIntent` in AppIntents.swift) lost and the four above won.

/// Shortcuts / Action button "Recenter": tells the app the walker is now facing the way to walk,
/// so the audio beacon renders from there.
///
/// Not an App Shortcut because the walk already has two other ways to do it: the watch's Recenter
/// button, and the automatic re-zero after three straight-walking fixes (`StraightWalkDetector`),
/// which is what happens on a normal walk. This is the escape hatch for a walker with no watch.
struct RecenterIntent: AppIntent {
    /// Shown in Shortcuts and the Action button picker.
    static let title: LocalizedStringResource = "Recenter the beacon"
    /// Subtitle in Shortcuts.
    static let description = IntentDescription("Sets the direction you are facing now as the beacon's straight ahead.")
    /// ⚠ Foreground only, like every intent in this app.
    static let supportedModes: IntentModes = .foreground(.immediate)

    /// Waits for the model and calls `AppModel.recenter()` (says "Recentered.").
    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        model.recenter()
        return .result()
    }
}

/// Shortcuts / Action button "Turn <feature> on/off": the Hazards-card switches, by voice.
///
/// Not an App Shortcut because these are configuration — chosen before a walk, not during one —
/// and because giving each of the eight features its own phrase would need eight of the ten slots.
/// A walker who wants one of them on the Action button builds a one-step shortcut around this
/// intent with the feature already filled in, which is also how it becomes a single press.
struct SetOptionIntent: AppIntent {
    /// Shown in Shortcuts and the Action button picker.
    static let title: LocalizedStringResource = "Turn a feature on or off"
    /// Subtitle in Shortcuts.
    static let description = IntentDescription("Switches drop-off detection, sign reading, the hazard watch, naming people, obstacle names, the beacon, siren listening or nod to talk.")
    /// ⚠ Foreground only, like every intent in this app.
    static let supportedModes: IntentModes = .foreground(.immediate)

    /// Which feature. Required: there is no sensible default, and guessing would flip the wrong
    /// switch on a walker who cannot see which one moved.
    @Parameter(title: "Feature", requestValueDialog: "Which feature?")
    var option: HandsFreeOption

    /// On or off. Required for the same reason: a toggle would leave the walker unsure what they
    /// now have.
    @Parameter(title: "State", requestValueDialog: "On or off?")
    var state: SwitchState

    /// Waits for the model and calls `AppModel.setOption(_:enabled:)`, which speaks the state the
    /// feature actually ended up in (a refused microphone must not be announced as on).
    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        model.setOption(option, enabled: state.isOn)
        return .result()
    }
}

/// Action button / Shortcuts "Talk to OpenCane": spoken conversational assistant query.
///
/// Registered as an App Shortcut (`CaneKitShortcuts` in `AppIntents.swift`), so it appears
/// directly in iOS Settings > Action Button > Shortcut with no user-built shortcut, and answers
/// to "Talk to OpenCane" via Siri. An empty query (an Action button press) toggles push-to-talk
/// listening in the app; a filled one is answered conversationally at `.scene` priority.
///
/// Why it is an App Shortcut at all (Step 29): as a plain `AppIntent` it never appeared in the
/// Action button's picker, so "the Action button still isn't working" was literally true;
/// `NavigateToCIFIntent` gave up its slot for it.
struct TalkToOpenCaneIntent: AppIntent {
    /// Shown in Shortcuts and the Action button picker.
    static let title: LocalizedStringResource = "Talk to OpenCane"
    /// Subtitle in Shortcuts.
    static let description = IntentDescription("Speak to OpenCane to navigate, set posts, check status, or ask questions.")
    /// ⚠ Foreground only: ensures the app is frontmost with obstacle warnings live.
    static let supportedModes: IntentModes = .foreground(.immediate)
    /// Direct Action button presses bring OpenCane to the screen immediately.
    static let openAppWhenRun: Bool = true

    /// What the walker wants to ask or command. Optional on purpose: nil / blank means "start (or
    /// submit) push-to-talk", which is what a bare Action button press sends.
    @Parameter(title: "Query", requestValueDialog: "How can OpenCane help?")
    var query: String?

    /// Waits for the model, then either toggles push-to-talk (`AppModel.toggleVoiceInput(source:
    /// "actionButton")`, logged `voice_toggle`) for a blank query, or hands a typed / dictated
    /// query to `AppModel.handleSpokenQuery(_:)` and awaits `ConversationCoordinator.handleQuery`
    /// (which returns at once, silently, if a previous query is still being processed).
    /// Throws `IntentSupport.NotReady` if the model never appears within 2 s.
    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        let text = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            // When triggered from Action button or Shortcuts without a pre-set query,
            // immediately toggle push-to-talk listening in the app.
            model.toggleVoiceInput(source: "actionButton")
            return .result()
        }
        await model.handleSpokenQuery(text)
        return .result()
    }
}
