//
//  SoundWatcher.swift
//  CaneKit
//
//  The microphone's job: hear the traffic the LiDAR cannot see. Sirens, horns and vehicle sounds
//  reach the walker from behind, around a corner, and from 100 m away — none of which the 5 m
//  LiDAR, the camera or the GPS route can tell them about.
//
//  How: Apple's built-in sound classifier (`SNClassifySoundRequest(classifierIdentifier:
//  .version1)`, 303 labels on this phone — counted, see below) over the live microphone, via
//  `AVAudioEngine.inputNode` → `SNAudioStreamAnalyzer`. Every classification window is reduced to
//  at most one `DangerSound` and handed to CaneKitLogic `SoundAlertPolicy`, which holds the
//  confidence gates, the two-window agreement rule and the per-kind repeat intervals
//  (AGENTS.md hard rule 3; tests in SoundAlertsTests).
//
//  Label identifiers are **read off the phone, never guessed**. Apple documents "hundreds of
//  sounds" but publishes no list of the strings, and `SNClassifySoundRequest.knownClassifications`
//  is the documented way to get them. `start()` intersects `SoundAlerts.candidateLabels` with that
//  array and matches only labels this iOS version actually has, logging both the matches and the
//  misses as `sound_watch_labels`. Measured on the iPhone 17 Pro Max / iOS 27 (2026-09-11,
//  trip-log `probe_f_sound_labels`): 303 known labels, of which these exist — siren,
//  police_siren, ambulance_siren, fire_engine_siren, civil_defense_siren, emergency_vehicle,
//  car_horn, air_horn, train_horn, bicycle_bell, car_passing_by, traffic_noise, engine,
//  engine_idling, bus, truck, motorcycle — and "vehicle", "car", "honk", "car_alarm",
//  "tire_squeal" and friends do **not**.
//
//  Audio session — the real cost, stated plainly. `.playback` has no input, so this feature needs
//  `.playAndRecord`, which AGENTS.md hard rule 7 and ios/README.md §2 deliberately forbid as the
//  app's steady state (HFP would drop AirPods to call quality and kill the HRTF beacon). The
//  compromise: the switch is **off by default**, the category change goes through the one owner of
//  the session (`SpeechQueue.setMicrophoneEnabled(_:owner:)`), `.allowBluetoothHFP` is never requested, and
//  the output route is guarded for the **whole time the microphone is on** — not just at the
//  moment it is switched on. iOS settles a route change asynchronously (an AirPods flip lands
//  a few hundred milliseconds after `setActive` returns), so the before/after comparison inside
//  `setMicrophoneEnabled` cannot be the whole guard: `SpeechQueue` also watches
//  `routeChangeNotification` and calls `onMicrophoneRouteChanged`, which lands in
//  `routeChanged(from:to:)` here and stops the watcher. Speech, obstacle warnings and the
//  beacon are the safety path; a microphone feature never outranks them.
//
//  Owner: `AppModel.sounds` (one instance).
//
//  ─────────────────────────────────────────────────────────────────────────────────────────────
//  WHAT PRIORITY AN EMERGENCY SIREN GETS, AND WHY IT IS NOT `.safety`
//  ─────────────────────────────────────────────────────────────────────────────────────────────
//  An emergency siren has the strongest claim of anything in this app to being interrupt-worthy:
//  it is the single hazard neither the cane tip, nor the 5 m LiDAR, nor the camera, nor the GPS
//  route can ever detect. It arrives from behind, around corners, and from hundreds of metres.
//  It is still **not** `.safety`, for three reasons, in order of weight:
//
//   1. `.safety` is a queue, not a volume knob. `SpeechQueue` pre-empts only on a *strictly*
//      higher priority; equal priorities queue FIFO. A siren line sitting at `.safety` would
//      therefore **delay "Head height."** — or a LiDAR drop-off — by its own length, every time
//      the two coincided. The rule that `.safety` is never suppressed is not weakened here; it is
//      protected, by keeping out of that band anything that is not imminent, physical, and
//      invisible to the walker.
//   2. The walker already has this signal. A siren is an auditory warning device, engineered to be
//      heard by pedestrians; a blind traveller's hearing is their primary instrument and hears it
//      far further than a phone microphone strapped to a swinging cane. "Head height." warns about
//      something nobody can perceive. This tells the walker what a sound they can hear *means*.
//   3. Apple, about this exact classifier, shipped as Sound Recognition: "Don't rely on your
//      iPhone to recognize sounds in circumstances where you may be harmed or injured, in
//      high-risk or emergency situations, or for navigation." A model with that disclaimer does
//      not get the band reserved for the cues that are always right.
//
//  So the emergency siren sits at `.nav` — the band route lines and crossing instructions use —
//  and horns and vehicle sounds stay at `.obstacle`, unchanged. `.nav` is not a compromise, it is
//  the semantically correct band: what a siren tells a blind pedestrian is a *crossing* fact (see
//  SoundAlerts.swift R1 — the siren masks the traffic sound the crossing decision is made from),
//  and crossing facts are `.nav` in this app. Mechanically `.nav` also buys the two things
//  `.obstacle` could not: the alert no longer waits behind a 20-word scene description, and it can
//  no longer cut a crossing instruction, because equal priorities queue.
//  Nothing new can delay a warning: `.safety` still pre-empts `.nav` instantly, the haptic cue
//  channel is untouched, and the only line a siren can now interrupt is an obstacle *name* — which
//  is what every route line in the app has always done, and which resumes afterwards.
//  There is still no haptic and no wrist tap for a sound alert: the cane's taps mean "something is
//  in your path", and borrowing them for something heard would make the safety channel ambiguous.
//
//  Threading / isolation: `@MainActor @Observable`. `SNResultsObserving` is called by
//  SoundAnalysis on its own queue, and the microphone tap is called on an AVAudioEngine render
//  thread, so both go through `nonisolated` relays that carry only Sendable values (`String`,
//  `Double`) and hop with `Task { @MainActor in … }` (AGENTS.md hard rule 1). The analyser itself
//  runs on a dedicated serial queue, as Apple's article requires. It is built and its request is
//  added on the main actor, before the tap exists — nothing is analysing yet, and the first
//  `queue.async` is the barrier that publishes it — and from that moment on **every** call into it
//  (`analyze`, `removeAllRequests`) goes through `SoundAnalysisPump` onto that one queue, because
//  Apple requires the analyser to be used from a single queue and a `removeAllRequests` racing a
//  buffer also makes the analyser report a failure on what was a perfectly clean stop.
//
//  Key invariants:
//    · Nothing runs until `start()`, and `start()` is only called from the Hazards card's switch.
//    · A degraded audio route always wins: input and output ports are snapshotted, HFP/missing
//      input or any output move restores `.playback`, `lastError` is set, and `isRunning` is false.
//    · `stop()` always restores `.playback`, even if the engine failed half-way up.
//    · Every way this feature can die attempts the same three things: the session back on
//      `.playback`, `isRunning` false, and `onFailure` fired so `AppModel` puts the switch back to
//      off and says why once. If both bounded restore attempts fail, the card and spoken line say
//      the audio state is unknown instead of claiming playback. A failure that only set
//      `lastError` used to leave the microphone open, the orange recording dot on, and the switch
//      showing a feature that was dead.
//    · Anything that resumes asynchronously (the permission prompt, the input-format retry and
//      the permission monitor) is fenced by `generation` / task cancellation: if the walker
//      turned the switch off in the meantime, it does nothing. A microphone that starts *after*
//      you switched it off is the worst bug this file can have.
//

import AVFoundation
import CaneKitLogic
import Foundation
import Observation
import SoundAnalysis

/// Danger-sound recognition on the live microphone. Off by default; owned by `AppModel`.
@MainActor
@Observable
final class SoundWatcher {

    // MARK: Published

    /// True while the microphone tap and the analyser are live.
    private(set) var isRunning = false
    /// True while this watcher owns the shared microphone lease, including the short startup
    /// interval before its tap/analyser has become live. `VoiceInputEngine` uses this to avoid
    /// attempting to restore or replace the session during that interval.
    var ownsMicrophoneSession: Bool { sessionHeld || isRunning }
    /// Last line spoken because of a sound ("Siren. Do not start crossing."), for the Hazards card.
    private(set) var lastAlert: String?
    /// Why the watcher is not running: a refused microphone, a degraded audio route, or an engine
    /// failure. Shown on the Hazards card in the warning colour; never cleared silently.
    private(set) var lastError: String?
    /// "17 of 30 labels available" — proof in the UI that the classifier really has the labels
    /// this build matches on.
    private(set) var labelReport = ""

    /// Fired on the main actor for each sound worth announcing. `AppModel` speaks it and logs it.
    @ObservationIgnored var onAlert: ((DangerSound) -> Void)?
    /// Fired on the main actor, once, when the watcher gives up for any reason: microphone
    /// refused, audio route degraded, analyser dead, engine dead.
    ///
    /// By the time it fires the session has attempted to return to `.playback` and `isRunning` is
    /// false, so the handler's only job is the part this object cannot do: put
    /// `AppModel.dangerSoundsEnabled` back to off and say the message once. A restore failure is
    /// included in that cue. Without it the switch stayed on after a failed
    /// start, and every foregrounding retried, failed and announced again
    /// (`AppModel.wireSounds()`).
    @ObservationIgnored var onFailure: ((String) -> Void)?
    /// Trip-log hook: `(kind, fields)`, wired by `AppModel.wireSounds()`.
    @ObservationIgnored var onDiagnostic: ((String, [String: Any]) -> Void)?

    // MARK: Private

    /// The one audio engine for the microphone tap; created lazily on first `start()` and reused,
    /// because a fresh `AVAudioEngine` per start leaks render threads.
    @ObservationIgnored private let engine = AVAudioEngine()
    /// Serial queue the analyser runs on (Apple: "running the stream analyzer on a dedicated
    /// dispatch queue" keeps the audio engine responsive). Every analyser call runs here.
    @ObservationIgnored private let analysisQueue = DispatchQueue(label: "canekit.sound", qos: .userInitiated)
    /// Non-nil while running; discarded on `stop()` because an analyser is bound to one input
    /// format (Apple: "if the input device's audio format changes… create a new one").
    @ObservationIgnored private var analyzer: SNAudioStreamAnalyzer?
    /// Strong reference to the results relay (SoundAnalysis holds observers weakly).
    @ObservationIgnored private var observer: SoundResultsRelay?
    /// Carries microphone buffers from the audio tap thread to the analysis queue, and tears the
    /// analyser down on that same queue; non-nil only while running.
    @ObservationIgnored private var pump: SoundAnalysisPump?
    /// The confidence / agreement / repeat rules (CaneKitLogic, SoundAlertsTests).
    @ObservationIgnored private var policy = SoundAlertPolicy()
    /// Pure lifecycle / route / permission guard. The AVFoundation callbacks below only translate
    /// framework state into `SoundRecognitionGuard` events; the guard decides whether one failure
    /// may stop the feature, which keeps route-flapping and permission-race behavior testable.
    @ObservationIgnored private var lifecycle = SoundRecognitionGuard()
    /// The labels this phone's classifier actually has, mapped to their kind. Built in `start()`
    /// from `knownClassifications`; empty until then, so nothing can match before the check.
    @ObservationIgnored private var activeLabels: [String: DangerSound] = [:]
    /// The audio-session owner; the only object allowed to call `setCategory`.
    @ObservationIgnored private let speech: SpeechQueue

    /// Bumped by `stop()` and by `fail(_:)`. Everything that resumes asynchronously — the
    /// microphone permission prompt, the input-format retry — captures its value first and does
    /// nothing if it has moved.
    ///
    /// Without it, "switch on (prompt appears) → switch off → tap Allow" started recording with
    /// the switch showing off, because the permission continuation called `start()`
    /// unconditionally and `stop()` had returned early with nothing to tear down.
    @ObservationIgnored private var generation = 0
    /// The pending input-format re-read (see `startEngine(attempt:)`); cancelled by `stop()` and
    /// `fail(_:speak:)` so a dead start cannot wake up later. There is never more than one: while
    /// it is pending, `pendingRequest` is non-nil and `start()` refuses to begin a second attempt,
    /// which would otherwise orphan this task *and* re-baseline `SpeechQueue`'s route guard to
    /// whatever the route had already become.
    @ObservationIgnored private var formatRetry: Task<Void, Never>?
    /// Observes `AVAudioSession.interruptionNotification` while the microphone is on. A call or
    /// Siri invocation can leave SoundAnalysis alive but starved of frames, so `.began` is a hard
    /// stop through `interruptionChanged`; the observer is removed with the session and `.ended`
    /// is logged only for diagnosis. SpeechQueue independently handles speech interruption.
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    /// Polls the system permission while the watcher owns `.playAndRecord`. iOS has no reliable
    /// permission-revoked notification; the short, bounded cadence is the adapter's only way to
    /// catch Settings changes that do not emit a route or interruption event.
    @ObservationIgnored private var permissionWatchTask: Task<Void, Never>?
    /// Engine configuration changes can invalidate a tap/analyser without producing a route event.
    /// It is observed only while this watcher owns the input and removed before teardown.
    @ObservationIgnored private var engineConfigurationObserver: NSObjectProtocol?
    /// The classify request built by the current `start()`, held across the input-format retry so
    /// the retry does not rebuild the label table or re-log it. Nil whenever nothing is starting.
    @ObservationIgnored private var pendingRequest: SNClassifySoundRequest?
    /// True from the moment `setMicrophoneEnabled(true)` is granted until it is given back.
    ///
    /// It is not the same thing as `isRunning`: between the session being granted and the engine
    /// starting there is a window — the input-format retry waits inside it — where the app holds
    /// `.playAndRecord` and the orange recording indicator with nothing listening yet. `stop()`
    /// used to look only at `isRunning`/`analyzer` and return early there, walking away from a
    /// session it had taken. Everything goes through `releaseSession()` so there is one answer to
    /// "does the app still hold the microphone".
    @ObservationIgnored private var sessionHeld = false
    /// Error returned while restoring the shared session to `.playback`. Kept until `fail` can
    /// merge it into the technical Hazards-card line; explicit user stops report it immediately.
    @ObservationIgnored private var sessionRestoreFailure: String?

    /// True when this build can create the built-in classifier at all (it cannot on a platform
    /// without the model). Evaluated once; gates the Hazards card's switch.
    static let isAvailable: Bool = (try? SNClassifySoundRequest(classifierIdentifier: .version1)) != nil

    /// - Parameter speech: `AppModel.speech`, which owns the audio session.
    init(speech: SpeechQueue) {
        self.speech = speech
    }

    // MARK: Lifecycle

    /// Ask for the microphone, put the session into `.playAndRecord` (reverting if that costs the
    /// output route), build the analyser and start the engine.
    ///
    /// Order matters: permission → session → route guard → labels → analyser → tap → engine. A
    /// failure at any step leaves `lastError` set, `isRunning` false, the session restored or an
    /// explicit restore error recorded, and `onFailure` fired.
    /// Caller: `AppModel.dangerSoundsEnabled`'s `didSet`, `AppModel.start()` and
    /// `AppModel.scenePhaseChanged(.active)` when the setting was already on.
    func start() {
        // Three states mean "already dealt with": running, holding the session, or waiting for the
        // input format. `AppModel` starts the watcher from three places (`start()`,
        // `scenePhaseChanged(.active)`, the switch) and two of them can land in the same launch —
        // without `sessionHeld` / `pendingRequest` a second call inside the 0.25 s format-retry
        // window would take the session again and orphan the first retry task, which shares this
        // one's `generation` and so would not be fenced by it.
        guard !isRunning, !sessionHeld, pendingRequest == nil else { return }
        lastError = nil
        sessionRestoreFailure = nil
        speech.microphoneRestoreError = nil
        // Permission first: `.playAndRecord` on a phone that has refused the microphone would
        // succeed and then deliver silence, which looks exactly like "no sirens today".
        switch AVAudioApplication.shared.recordPermission {
        case .denied:
            guard lifecycle.beginStart() else { return }
            fail("Microphone is off for OpenCane. Sound alerts need it.")
            return
        case .undetermined:
            // The prompt can stay up for as long as the walker likes, and they can turn the
            // switch off while it is up. Fence the continuation on both generations so "off then
            // Allow" cannot start the microphone behind a switch that says off.
            guard let permissionGeneration = lifecycle.beginPermissionRequest() else { return }
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let decision = self.lifecycle.permissionResolved(granted: granted,
                                                                     generation: permissionGeneration)
                    guard decision == .continueRunning else {
                        if case .stop = decision {
                            self.fail("Microphone is off for OpenCane. Sound alerts need it.")
                        }
                        return
                    }
                    guard granted, self.lifecycle.beginStart() else {
                        self.fail("Microphone is off for OpenCane. Sound alerts need it.")
                        return
                    }
                    self.startGrantedSession()
                }
            }
            return
        case .granted:
            guard lifecycle.beginStart() else { return }
        @unknown default:
            guard lifecycle.beginStart() else { return }
            fail("Microphone permission is unavailable for OpenCane.")
            return
        }

        startGrantedSession()
    }

    /// Continues a start after the permission check has succeeded. Kept separate from `start()` so
    /// a permission callback cannot re-enter the lifecycle guard and accidentally create a second
    /// generation while the first start is still being torn down.
    private func startGrantedSession() {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            fail("Microphone permission was revoked before sound alerts started.",
                 speak: "Sound alerts could not start because microphone access was revoked.")
            return
        }
        // Install before activating `.playAndRecord`: a call/Siri interruption can begin during
        // category activation and route negotiation. The observer is generation-fenced and
        // removed by every exit path, so an early notification cannot resurrect a later run.
        let sessionGeneration = generation
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            guard let type else { return }
            MainActor.assumeIsolated {
                self?.interruptionChanged(type, generation: sessionGeneration)
            }
        }
        switch speech.setMicrophoneEnabled(true, owner: .soundRecognition) {
        case .granted(let route):
            sessionHeld = true
            onDiagnostic?("sound_watch", ["action": "session", "route": route])
            // The output route is guarded from here until `stop()`. The check inside
            // `setMicrophoneEnabled` only sees a route that has *already* moved; AirPods move
            // theirs a few hundred milliseconds later, which is exactly when the walker is
            // already walking.
            guard let routeSnapshot = speech.microphoneRouteSnapshot else {
                fail("Microphone route was unavailable after activation.",
                     speak: "Sound alerts could not start the microphone.")
                return
            }
            let sessionDecision = lifecycle.sessionStarted(route: routeSnapshot)
            guard case .continueRunning = sessionDecision else {
                let reason: SoundRecognitionFailure
                if case .stop(let failure) = sessionDecision {
                    reason = failure
                } else {
                    reason = .inputUnavailable
                }
                fail(failureMessage(for: reason), speak: spokenFailureMessage(for: reason))
                return
            }
            speech.onMicrophoneRouteChanged = { [weak self] before, after in
                self?.routeChanged(from: before, to: after, generation: sessionGeneration)
            }
            startPermissionWatch()
        case .revertedRouteChanged(let before, let after):
            onDiagnostic?("sound_watch", ["action": "session_reverted", "before": before, "after": after])
            fail("Sound alerts would change the audio route from \(before) to \(after), so they stayed off.",
                 speak: "Sound alerts stayed off: they would have changed your headphone sound.")
            return
        case .failed(let message):
            onDiagnostic?("sound_watch", ["action": "session_failed", "error": message])
            fail("Sound alerts could not use the microphone: \(message)",
                 speak: "Sound alerts could not use the microphone.")
            return
        }

        guard let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else {
            releaseSession()
            fail("This phone has no built-in sound classifier.")
            return
        }
        // Two windows must agree before anything is spoken, so the window hop sets the latency:
        // `overlapFactor` 0.5 over the classifier's own window ≈ 0.5 s per window.
        request.overlapFactor = 0.5
        buildLabelTable(request)
        pendingRequest = request
        startEngine(attempt: 0)
    }

    /// Read the microphone's input format, and once it is real, build the analyser, install the
    /// tap and start the engine.
    ///
    /// Split out of `start()` for one reason: the format is **not** trustworthy on the first read.
    /// `.playAndRecord` has only just been activated and iOS settles the route asynchronously, so
    /// `inputNode.outputFormat(forBus: 0)` can answer 0 Hz / 0 channels for a moment — most
    /// likely on the first-ever enable with AirPods, where the input has to be negotiated. The old
    /// code failed there and told the walker "No microphone input available" about a microphone
    /// that worked a quarter of a second later. The format check itself cannot be dropped:
    /// `installTap` traps on an invalid format. So it is re-read instead, once, after
    /// `MicrophoneStart.formatRetryDelay` (CaneKitLogic, SoundAlertsTests own the numbers).
    /// - Parameter attempt: zero-based; `MicrophoneStart.retryDelay(afterAttempt:)` decides
    ///   whether there is another one.
    private func startEngine(attempt: Int) {
        guard let request = pendingRequest else { return }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            pendingRequest = nil
            releaseSession()
            fail("Microphone permission was revoked while sound alerts were starting.",
                 speak: "Sound alerts could not start because microphone access was revoked.")
            return
        }
        // `prepare()` realises the input node against the now-active session. Only on a retry: the
        // first read costs nothing and usually succeeds, and this keeps the happy path untouched.
        if attempt > 0 { engine.prepare() }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard MicrophoneStart.isUsableInputFormat(sampleRate: format.sampleRate,
                                                  channels: format.channelCount) else {
            guard let delay = MicrophoneStart.retryDelay(afterAttempt: attempt) else {
                pendingRequest = nil
                releaseSession()
                fail("No microphone input available.")
                return
            }
            onDiagnostic?("sound_watch", ["action": "format_wait", "attempt": attempt,
                                          "sample_rate": format.sampleRate,
                                          "channels": Int(format.channelCount)])
            let generation = self.generation
            formatRetry = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                self.startEngine(attempt: attempt + 1)
            }
            return
        }

        let runGeneration = generation
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let relay = SoundResultsRelay { [weak self] label, confidence in
            Task { @MainActor [weak self] in
                self?.classified(label: label, confidence: confidence, generation: runGeneration)
            }
        } onFailure: { [weak self] message in
            Task { @MainActor [weak self] in
                self?.analysisFailed(message, generation: runGeneration)
            }
        }
        do {
            try analyzer.add(request, withObserver: relay)
        } catch {
            pendingRequest = nil
            releaseSession()
            fail("Sound analysis refused the request: \(error.localizedDescription)",
                 speak: "Sound alerts could not start.")
            return
        }
        self.analyzer = analyzer
        observer = relay
        policy.reset()

        // The tap is called on an audio thread and must return fast, so it only hands the buffer
        // to the analyser's own queue (Apple: "run the stream analyzer on a dedicated dispatch
        // queue"). `SoundAnalysisPump` is what makes that legal under strict concurrency, and it
        // is also the only thing allowed to talk to the analyser afterwards.
        let pump = SoundAnalysisPump(analyzer: analyzer, queue: analysisQueue)
        self.pump = pump
        pump.installTap(on: engine.inputNode, format: format)
        do {
            engine.prepare()
            try engine.start()
        } catch {
            // Undo everything this method built. It used to leave the analyser and the pump in
            // place with `isRunning` false, which is a half-started feature nobody owns.
            engine.inputNode.removeTap(onBus: 0)
            pump.finish()
            self.analyzer = nil
            observer = nil
            self.pump = nil
            pendingRequest = nil
            releaseSession()
            fail("The audio engine could not start: \(error.localizedDescription)",
                 speak: "Sound alerts could not start the microphone.")
            return
        }
        // Register immediately after the engine is live, before the route/permission checks below.
        // A configuration change can arrive in that small window; the analyser is already bound
        // to the tap, so it must be treated as a hard failure rather than waiting for the 0.5 s
        // permission/engine-health poll.
        let engineGeneration = generation
        engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.engineConfigurationChanged(generation: engineGeneration)
            }
        }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            pendingRequest = nil
            stop(reportRestoreFailure: false)
            fail("Microphone permission was revoked while sound alerts were starting.",
                 speak: "Sound alerts stopped because microphone access was revoked.")
            return
        }
        guard let activeRoute = speech.microphoneRouteSnapshot else {
            pendingRequest = nil
            stop(reportRestoreFailure: false)
            fail("Sound alerts could not start with a usable microphone input.",
                 speak: "Sound alerts could not start the microphone.")
            return
        }
        let recognitionDecision = lifecycle.recognitionStarted(route: activeRoute)
        guard case .continueRunning = recognitionDecision else {
            let reason: SoundRecognitionFailure
            if case .stop(let failure) = recognitionDecision {
                reason = failure
            } else {
                reason = .inputUnavailable
            }
            pendingRequest = nil
            stop(reportRestoreFailure: false)
            fail(failureMessage(for: reason), speak: spokenFailureMessage(for: reason))
            return
        }
        pendingRequest = nil
        isRunning = true
        onDiagnostic?("sound_watch", ["action": "start", "sample_rate": format.sampleRate,
                                      "labels": activeLabels.count, "attempt": attempt])
    }

    /// Stop the tap and the engine, drop the analyser and attempt to restore `.playback`.
    /// Callers: the Hazards card's switch (through `AppModel.dangerSoundsEnabled`),
    /// `AppModel.scenePhaseChanged(.background)`, and every failure path in this file.
    /// It deliberately survives a route ending: the walker asked to be told about traffic, not
    /// about traffic on a route.
    ///
    /// Safe to call at any point of a start, including while the permission prompt is up or the
    /// input format is settling — that is what the `generation` bump above the early return is
    /// for. It does not clear `lastError`: a failure path stops first and records afterwards, so
    /// the walker still learns why the feature went away. A restore failure is surfaced through
    /// the existing `onFailure` cue when `reportRestoreFailure` is true; failure paths pass false
    /// so their primary reason and the restore detail are spoken once together.
    @discardableResult
    func stop(reportRestoreFailure: Bool = true) -> String? {
        // Before the early return, not after: a start that is still waiting for the prompt or the
        // format has nothing to tear down, but it must still be told to give up.
        generation &+= 1
        formatRetry?.cancel()
        formatRetry = nil
        permissionWatchTask?.cancel()
        permissionWatchTask = nil
        pendingRequest = nil
        _ = lifecycle.cancel()
        speech.onMicrophoneRouteChanged = nil
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver)
            self.engineConfigurationObserver = nil
        }
        // `sessionHeld` is in the guard on purpose: a start that got the session and is still
        // waiting for the input format has no analyser to tear down but very much has a
        // microphone to give back.
        guard isRunning || analyzer != nil || sessionHeld else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        // On the analysis queue, behind every buffer already queued there — never from main.
        // Apple requires one queue for the analyser, and tearing it down under a concurrent
        // `analyze` both races and makes the analyser report a failure for a clean stop.
        pump?.finish()
        analyzer = nil
        observer = nil
        pump = nil
        policy.reset()
        isRunning = false
        releaseSession()
        let restoreFailure = sessionRestoreFailure
        if reportRestoreFailure, let restoreFailure {
            sessionRestoreFailure = nil
            let message = "Sound alerts stopped, but audio session restore failed: \(restoreFailure)"
            lastError = message
            onDiagnostic?("sound_watch", ["action": "session_restore_failed", "error": restoreFailure])
            onFailure?("Sound alerts stopped because audio output could not be restored.")
        }
        onDiagnostic?("sound_watch", ["action": "stop"])
        return restoreFailure
    }

    /// Give the audio session back to `.playback`, once, if this object took it.
    ///
    /// Every exit from a start, `fail(_:speak:)` and `stop()` itself end here. Guarding on
    /// `sessionHeld` keeps a double call (a failure path that stops first and then fails) from
    /// bouncing the category twice, which on a real route is two more chances for iOS to move the
    /// output and two more blocking `setActive` calls on the main actor. The route-change path
    /// clears `sessionHeld` itself, because there `SpeechQueue` has already done the restore.
    private func releaseSession() {
        guard sessionHeld else { return }
        sessionHeld = false
        guard case .failed(_) = speech.setMicrophoneEnabled(false, owner: .soundRecognition) else {
            return
        }
        // Audio-session activation can fail transiently while a route is settling. One immediate
        // retry is bounded and keeps a normal stop from leaving the orange mic indicator up; if it
        // also fails, preserve the second error and surface it instead of claiming playback.
        guard case .failed(let error) = speech.setMicrophoneEnabled(false, owner: .soundRecognition) else {
            return
        }
        sessionRestoreFailure = error
        onDiagnostic?("sound_watch", ["action": "session_restore_failed", "error": error])
    }

    // MARK: Failure paths

    /// The microphone route moved while it was on (`SpeechQueue` has already put the session back
    /// to `.playback`). Give the feature up. The pure guard distinguishes an output move from an
    /// HFP/missing-input transition; both are fail-safe stops, but the diagnostic says which one.
    ///
    /// This is the case the synchronous before/after check in `setMicrophoneEnabled` cannot see:
    /// AirPods negotiating HFP take a few hundred milliseconds, by which time the switch has
    /// already reported success. The spoken line deliberately does not read the port names out
    /// loud ("BluetoothHFP" means nothing to a walker); they go to the trip log instead.
    /// - Parameters:
    ///   - before: the route snapshot when the microphone was granted.
    ///   - after: the route snapshot now.
    private func routeChanged(from before: SoundRecognitionRoute, to after: SoundRecognitionRoute,
                              generation: Int) {
        guard self.generation == generation else { return }
        permissionRevokedIfNeeded()
        let decision = lifecycle.routeChanged(after)
        guard case .stop(let reason) = decision else { return }
        onDiagnostic?("sound_watch", ["action": "route_changed_stopped",
                                      "reason": reason.rawValue,
                                      "before_output": before.output,
                                      "after_output": after.output,
                                      "before_input": before.input,
                                      "after_input": after.input,
                                      "before_quality": before.inputQuality.rawValue,
                                      "after_quality": after.inputQuality.rawValue])
        // `SpeechQueue` restored `.playback` before calling us, so the session is no longer ours.
        // Clearing this first keeps `stop()` from setting the category and re-activating the
        // session a second time — a blocking main-actor call, made exactly while a Bluetooth route
        // is renegotiating and the walker is still being guided.
        sessionHeld = false
        if speech.microphoneRestoreError != nil {
            // The first restore happens inside SpeechQueue's route observer. Retry once from the
            // owner while the route event is still on the main actor; if it still fails, the error
            // is retained and the existing failure cue tells the walker the output state is not
            // known to be back on `.playback`.
            _ = speech.setMicrophoneEnabled(false, owner: .soundRecognition)
        }
        if let restoreError = speech.microphoneRestoreError {
            sessionRestoreFailure = restoreError
        }
        stop(reportRestoreFailure: false)
        fail(failureMessage(for: reason), speak: spokenFailureMessage(for: reason))
    }

    /// Interruption notifications are guarded for the whole active lifetime, not just logged. A
    /// call or Siri can leave SoundAnalysis alive but starved of frames; stopping immediately is
    /// safer than pretending a silent classifier is still listening. SpeechQueue handles its own
    /// speech interruption independently, so this only disables the optional sound watch.
    private func interruptionChanged(_ type: AVAudioSession.InterruptionType, generation: Int) {
        guard self.generation == generation else { return }
        switch type {
        case .began:
            permissionRevokedIfNeeded()
            let decision = lifecycle.interruptionBegan()
            guard case .stop = decision else { return }
            onDiagnostic?("sound_watch", ["action": "interruption_stopped"])
            stop(reportRestoreFailure: false)
            fail(failureMessage(for: .interrupted), speak: spokenFailureMessage(for: .interrupted))
        case .ended:
            onDiagnostic?("sound_watch", ["action": "interruption_ended_ignored"])
        @unknown default:
            break
        }
    }

    /// iOS does not provide a dependable microphone-permission-revoked notification. Poll only
    /// while this object owns the microphone, at a bounded Logic-pinned cadence, and tear the task
    /// down with the rest of the session. Route/interruption callbacks also call this check through
    /// `permissionRevokedIfNeeded` for immediate coverage of those transitions.
    private func startPermissionWatch() {
        permissionWatchTask?.cancel()
        permissionWatchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(SoundRecognitionGuard.permissionPollInterval))
                guard !Task.isCancelled, let self else { return }
                guard self.isRunning || self.sessionHeld || self.pendingRequest != nil else { return }
                self.permissionRevokedIfNeeded()
                if self.isRunning, !self.engine.isRunning {
                    self.engineConfigurationChanged()
                    return
                }
            }
        }
    }

    /// Check the live permission and fail once if Settings revoked it during setup or recognition.
    private func permissionRevokedIfNeeded() {
        guard AVAudioApplication.shared.recordPermission != .granted else { return }
        let decision = lifecycle.permissionRevoked()
        guard case .stop = decision else { return }
        onDiagnostic?("sound_watch", ["action": "permission_revoked"])
        stop(reportRestoreFailure: false)
        fail(failureMessage(for: .permissionRevoked), speak: spokenFailureMessage(for: .permissionRevoked))
    }

    /// An input format/configuration change invalidates the analyser's bound stream. Treat it as a
    /// hard failure even if SoundAnalysis has not emitted `didFailWithError` yet; the next buffer
    /// would otherwise be consumed by a stale tap with no trustworthy classifications.
    private func engineConfigurationChanged(generation: Int? = nil) {
        if let generation, self.generation != generation { return }
        permissionRevokedIfNeeded()
        guard isRunning || analyzer != nil else { return }
        guard case .stop(let reason) = lifecycle.analyzerFailed() else { return }
        onDiagnostic?("sound_watch", ["action": "engine_configuration_failed"])
        stop(reportRestoreFailure: false)
        fail(failureMessage(for: reason), speak: spokenFailureMessage(for: reason))
    }

    /// Technical card/trip-log text stays separate from the short spoken line, as with every other
    /// subsystem failure. These mappings are centralized so a new failure cannot accidentally read
    /// an NSError or Bluetooth port name to a blind walker.
    private func failureMessage(for reason: SoundRecognitionFailure) -> String {
        switch reason {
        case .outputRouteChanged:
            return "Sound alerts stopped: the microphone changed the audio output route."
        case .inputRouteDegraded:
            return "Sound alerts stopped: microphone input degraded to a low-quality route."
        case .inputUnavailable:
            return "Sound alerts stopped: microphone input is unavailable."
        case .analyzerFailed:
            return "Sound alerts stopped: the sound analyzer failed."
        case .interrupted:
            return "Sound alerts stopped: audio was interrupted."
        case .permissionRevoked:
            return "Sound alerts stopped: microphone permission was revoked."
        case .permissionDenied:
            return "Microphone is off for OpenCane. Sound alerts need it."
        }
    }

    private func spokenFailureMessage(for reason: SoundRecognitionFailure) -> String {
        switch reason {
        case .outputRouteChanged, .inputRouteDegraded:
            return "Sound alerts stopped because they would change your headphone sound."
        case .inputUnavailable:
            return "Sound alerts stopped because the microphone is unavailable."
        case .analyzerFailed:
            return "Sound alerts stopped listening because the sound analyzer failed."
        case .interrupted:
            return "Sound alerts stopped because audio was interrupted."
        case .permissionRevoked:
            return "Sound alerts stopped because microphone access was revoked."
        case .permissionDenied:
            return "Sound alerts need microphone access."
        }
    }

    /// The analyser gave up (format change, internal error). Stop properly instead of only
    /// recording the message.
    ///
    /// Before this, a dead analyser left `isRunning` true, the session on `.playAndRecord` (orange
    /// recording indicator, degraded beacon) and the Hazards switch on — a feature that was
    /// visibly enabled, silently deaf, and would never alert again. `stop()` runs first so the
    /// teardown is the normal one; `fail` then puts the message back, because `stop()` does not
    /// touch `lastError`.
    /// - Parameters:
    ///   - message: the analyser's message, already formatted by `SoundResultsRelay`.
    ///   - generation: the run token captured when the analyser was created; stale failures cannot
    ///     tear down a newer run.
    private func analysisFailed(_ message: String, generation: Int) {
        guard self.generation == generation else { return }  // a late callback from an old run
        guard isRunning || analyzer != nil else { return }   // a late failure after a clean stop
        guard case .stop(let reason) = lifecycle.analyzerFailed() else { return }
        onDiagnostic?("sound_watch", ["action": "analysis_failed", "error": message])
        stop(reportRestoreFailure: false)
        fail("\(failureMessage(for: reason)) \(message)", speak: spokenFailureMessage(for: reason))
    }

    /// Record a reason the watcher is not running, make sure the flag agrees with it, cancel
    /// anything still trying to start, and tell the owner once.
    ///
    /// Every failure in this file goes through here, so there is exactly one place that decides
    /// what a failure means: no pending work, `isRunning` false, `lastError` set for the Hazards
    /// card, and `onFailure` so `AppModel` turns the switch off and speaks it once.
    ///
    /// The two strings are deliberately separate. `message` is for the card and the trip log and
    /// may carry the detail a developer needs — an `NSError` description, the audio port names.
    /// `spoken` is what a blind walker hears mid-walk, and reading
    /// "com.apple.SoundAnalysis error 2" or "BluetoothA2DP to BluetoothHFP" out loud over a route
    /// is noise at best. These used to be one string that only ever reached the card; the moment a
    /// failure became something the app *says*, they had to part company.
    /// - Parameters:
    ///   - message: shown on the Hazards card and logged; may be technical.
    ///   - spoken: what is said aloud. Defaults to `message`, which is right only when the message
    ///     is already a plain sentence.
    private func fail(_ message: String, speak spoken: String? = nil) {
        generation &+= 1
        formatRetry?.cancel()
        formatRetry = nil
        permissionWatchTask?.cancel()
        permissionWatchTask = nil
        pendingRequest = nil
        _ = lifecycle.cancel()
        // A start that got as far as the session but no further has already left a route hook on
        // `SpeechQueue`; nothing must be able to call back into a watcher that has given up.
        speech.onMicrophoneRouteChanged = nil
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver)
            self.engineConfigurationObserver = nil
        }
        // Structural, not conventional: every current caller releases the session before it fails,
        // but the file header promises that *every* way this feature dies attempts `.playback`, and
        // a promise kept by six call sites agreeing is one bad merge from being broken.
        // `releaseSession()` is idempotent, so the duplicate costs nothing.
        releaseSession()
        let restoreDetail = sessionRestoreFailure ?? speech.microphoneRestoreError
        sessionRestoreFailure = nil
        if let restoreDetail {
            lastError = "\(message) Audio session restore failed: \(restoreDetail)"
        } else {
            lastError = message
        }
        isRunning = false
        if restoreDetail != nil {
            onFailure?((spoken ?? message) + " Audio output could not be restored.")
        } else {
            onFailure?(spoken ?? message)
        }
    }

    // MARK: Classification

    /// Keep only the candidate labels this phone's classifier really has, and log the rest.
    /// Without this the feature could look enabled while matching identifiers that do not exist.
    private func buildLabelTable(_ request: SNClassifySoundRequest) {
        let known = Set(request.knownClassifications)
        var table: [String: DangerSound] = [:]
        var missing: [String] = []
        for (kind, labels) in SoundAlerts.labels {
            for label in labels {
                if known.contains(label) { table[label] = kind } else { missing.append(label) }
            }
        }
        activeLabels = table
        labelReport = "\(table.count) of \(SoundAlerts.candidateLabels.count) labels available"
        onDiagnostic?("sound_watch_labels", [
            "known_count": known.count,
            "matched": table.keys.sorted(),
            "missing": missing.sorted(),
        ])
    }

    /// One classification window's best danger-sound candidate (already filtered and hopped to
    /// main by `SoundResultsRelay`): run it through the policy and announce what survives.
    /// - Parameters:
    ///   - label: a classifier identifier known to be in `activeLabels`.
    ///   - confidence: 0…1 from `SNClassification.confidence`.
    ///   - generation: the run token captured when the analyser was created; stale callbacks are
    ///     ignored after stop → start.
    private func classified(label: String, confidence: Double, generation: Int) {
        guard self.generation == generation, isRunning else { return }
        let kind = activeLabels[label]
        let now = Date().timeIntervalSinceReferenceDate
        guard let announce = policy.update(kind: kind, confidence: confidence, now: now) else { return }
        lastAlert = announce.spokenLine
        onDiagnostic?("sound_alert", ["sound": announce.rawValue, "label": label,
                                      "confidence": (confidence * 100).rounded() / 100])
        onAlert?(announce)
    }

}

/// Hands microphone buffers from the audio tap thread to the analyser's serial queue, and is the
/// only thing that ever calls the analyser.
///
/// It exists to make that hop legal under Swift 6 strict concurrency: neither
/// `SNAudioStreamAnalyzer` nor `AVAudioPCMBuffer` is `Sendable`, and the tap block escapes the
/// audio thread. `@unchecked Sendable` is sound here — once this object exists the analyser is
/// touched **only** from `queue` (a serial queue); it was built and given its request on the main
/// actor before that, with no tap installed and therefore nothing analysing, and the first
/// `queue.async` publishes it. Each buffer is handed over exactly once and never read again by the
/// tap, and the pump is dropped (with the tap removed first) in `SoundWatcher.stop()`. It is not
/// used to silence a real data race (AGENTS.md hard rule 1).
///
/// ⚠ `finish()` is part of that contract. `SoundWatcher.stop()` used to call
/// `analyzer.removeAllRequests()` straight from the main actor while this class was still
/// dispatching `analyze(_:atAudioFramePosition:)` onto `queue`: two queues in one analyser, which
/// Apple forbids, and a buffer analysed just after the requests were removed throws an internal
/// error — so a clean stop reported a failure to the walker.
private nonisolated final class SoundAnalysisPump: @unchecked Sendable {

    private let analyzer: SNAudioStreamAnalyzer
    private let queue: DispatchQueue
    /// True once `finish()` has run. **Only ever read or written inside `queue`**, which is what
    /// makes it race-free without a lock: the serial queue is the synchronisation.
    private var finished = false

    init(analyzer: SNAudioStreamAnalyzer, queue: DispatchQueue) {
        self.analyzer = analyzer
        self.queue = queue
    }

    /// Installs the audio tap from this `nonisolated` class so the tap closure does not inherit
    /// `@MainActor` isolation under Swift 6.
    func installTap(on inputNode: AVAudioNode, format: AVAudioFormat) {
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            self?.feed(buffer, at: time.sampleTime)
        }
    }

    /// Called on the audio tap thread; returns immediately.
    ///
    /// The `finished` check runs *inside* the queue, so a buffer the audio thread handed over
    /// while `stop()` was running is dropped rather than analysed against a torn-down analyser.
    /// - Parameters:
    ///   - buffer: the PCM buffer the tap delivered (SoundAnalysis only accepts PCM).
    ///   - position: `AVAudioTime.sampleTime`, the analyser's stream position.
    func feed(_ buffer: AVAudioPCMBuffer, at position: AVAudioFramePosition) {
        let box = SoundBufferBox(buffer)
        queue.async { [self] in
            guard !finished else { return }
            analyzer.analyze(box.buffer, atAudioFramePosition: position)
        }
    }

    /// Tear the analyser's requests down **on the analysis queue**, after every buffer already
    /// queued there and before any that arrive later.
    ///
    /// Called by `SoundWatcher.stop()` (and by the engine-start failure path) after the tap has
    /// been removed. It is deliberately asynchronous: blocking the main actor on an audio queue
    /// while the walker is being guided is not a trade this app makes, and the analyser is only
    /// reachable through this object, which the caller drops immediately afterwards.
    func finish() {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            analyzer.removeAllRequests()
        }
    }
}

/// Carries one non-`Sendable` `AVAudioPCMBuffer` across the tap → analysis-queue hop. Sound
/// because the buffer is written once before the hop and read once after it, by one queue.
private nonisolated final class SoundBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

/// `SNResultsObserving` relay. SoundAnalysis calls it on the analyser's queue, so it is
/// `nonisolated` and carries only Sendable values (`String`, `Double`) into the main-actor hop
/// (AGENTS.md hard rule 1). It keeps no state of its own, so it is trivially safe there.
///
/// It forwards the whole window's best *danger* candidate rather than the top classification: the
/// classifier's most confident label on a street is usually "speech" or "silence", and filtering
/// on main would mean hopping 2 × per second for nothing.
private nonisolated final class SoundResultsRelay: NSObject, SNResultsObserving, @unchecked Sendable {

    /// `(label, confidence)` of the best danger sound in a window; a window with none reports
    /// `("", 0)` so the policy's agreement run is correctly broken.
    private let onResult: @Sendable (String, Double) -> Void
    /// The analyser gave up (format change, internal error). Reaches
    /// `SoundWatcher.analysisFailed`, which stops the watcher rather than only noting it.
    private let onFailure: @Sendable (String) -> Void

    init(onResult: @escaping @Sendable (String, Double) -> Void,
         onFailure: @escaping @Sendable (String) -> Void) {
        self.onResult = onResult
        self.onFailure = onFailure
    }

    /// One classification window. Exactly one label with a `DangerSound` mapping is forwarded; the
    /// mapping itself is checked again on the main actor against the *measured* label table.
    ///
    /// Which one is `SoundAlerts.best(of:)`'s decision, not this class's, and it is deliberately
    /// **not** "the highest confidence". Next to a road `traffic_noise` and `engine` are high in
    /// every window, so an approaching siren would come second window after window, and
    /// `SoundAlertPolicy` — which needs *consecutive agreeing* windows — would have the siren's run
    /// broken by the ambient class every time and would never announce it at all. `best(of:)`
    /// prefers the more urgent kind whenever it clears its own gate; see its doc comment and
    /// `SoundAlertsTests.anEmergencySirenIsNotShadowedByTheAmbientTrafficClass`.
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult else { return }
        let candidates = classification.classifications.map {
            (label: $0.identifier, confidence: $0.confidence)
        }
        let best = SoundAlerts.best(of: candidates)
        onResult(best?.label ?? "", best?.confidence ?? 0)
    }

    /// Analysis failed; the message reaches `SoundWatcher.analysisFailed`, which stops the
    /// watcher, hands the microphone back and leaves the message in `lastError`.
    func request(_ request: SNRequest, didFailWithError error: Error) {
        onFailure("Sound analysis failed: \(error.localizedDescription)")
    }

    /// Stream ended (only on `removeAllRequests` here); nothing to do.
    func requestDidComplete(_ request: SNRequest) {}
}
