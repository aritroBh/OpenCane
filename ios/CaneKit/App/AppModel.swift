//
//  AppModel.swift
//  CaneKit
//
//  Purpose: central owner of every engine and of the user settings, and the glue between them:
//  the depth "cue router" (LaneReport → haptics / watch / speech / log), navigation and
//  headphone-route wiring, the route start/stop sequence (including the depth-readiness
//  interlock that holds a route until ARKit delivers fresh trusted frames), watch commands,
//  auto-recenter of the head reference (AirPods or front camera), the cue profile
//  (level × place), the optional sensor modes (both cameras, front-camera head tracking,
//  microphone danger sounds, nod to talk, flashlight), voice input, launch-crash recovery, and
//  thermal/battery observation.
//
//  Why one class: every engine needs events from several others (a depth report feeds haptics,
//  watch, speech, scene context and the log; a GPS fix feeds nav, trip, Live Activity, watch and
//  auto-recenter). Keeping all wiring in one main-actor owner means there is exactly one place
//  where the order of effects is decided (and where most trip-log events are written; engines
//  that log for themselves do it through `onDiagnostic` / `onEvent` closures installed here), and
//  SwiftUI observes one object.
//
//  Owner: `CaneKitApp` creates exactly one instance (`@State`) for the process lifetime and
//  injects it into SwiftUI with `.environment(model)`; App Intents reach it via `AppModel.shared`.
//  Module `app-core` in docs/CODE_REFERENCE.md. Callers: every card in `ios/CaneKit/UI/`,
//  `AppIntents.swift` / `HandsFreeIntents.swift` (the `AppModel` extension there adds
//  `speakStatus`, `askAboutScene`, `setHapticsSilenced`, `setOption`, `isOptionEnabled`),
//  `ConversationCoordinator` (weak back-reference), `PhoneWatchLink.onCommand`.
//
//  Threading / isolation: `@MainActor` (the project default, SWIFT_DEFAULT_ACTOR_ISOLATION =
//  MainActor). Engines that run off-main (DepthEngine's ARKit queue, CoreLocation) publish
//  Sendable value types (`LaneReport`, `GeoFix`) back through closures installed here, which are
//  always invoked on the main actor. `MainActor.assumeIsolated` is used only inside
//  NotificationCenter observers registered with `queue: .main` (AGENTS.md hard rule 1).
//
//  Key invariants:
//    · `start()` runs once; its order (audio session → haptics → ARKit) is load-bearing.
//    · **No optional feature may keep the app from starting.** Optional sensor/model features are
//      either not persisted at all (the microphone and the front camera) or cleared by
//      `LaunchRecovery` after a launch that never reported itself healthy. A walker who cannot
//      reach the switch cannot turn the feature off, so the app has to do it for them.
//    · Cue-router timing uses the ARKit clock (`report.timestamp`), never wall time.
//    · The `.head` cue is never suppressed (AGENTS.md hard rule 8); "Head height." is spoken
//      once per obstacle episode, never every second.
//    · Decisions with numbers in them live in CaneKitLogic (CueDecider, CueSpeechPolicy,
//      StraightWalkDetector); this class only owns state, timing and effects (hard rule 3).
//    · `commonLines` must stay byte-identical to the strings spoken elsewhere (prefetch cache).
//    · On a LiDAR phone with camera access a route never starts guidance before `DepthReadiness`
//      reports ready (3 consecutive trusted frames, 5 s bound; `queueRouteStart`). The only
//      routes that start at once are the documented degraded paths (no LiDAR, camera denied).
//    · Both cameras, front-camera head-tracking changes and the two sensor self-tests pause or
//      re-run ARKit, so they are refused while a route is guiding or starting (the switches say
//      why out loud; the debug self-tests only show it in `selfTestStatus`). ⚠ The 60 fps switch
//      (`highFrameRateCamera`) also re-runs the session and has no such refusal today.
//    · Trip-log field names `t` and `kind` belong to the record (`TripLogRecord`): events here
//      name theirs `cue`, `type`, `source`, … (`ios/scripts/e2e.py` fails a run on `field_kind`).
//
//  Engines by step:
//    step 2 DepthEngine · step 3 HapticPlayer · step 4 SpeechQueue/ObstacleNamer ·
//    step 5 PhoneWatchLink · step 6 LocationService/NavigationEngine · step 7 BeaconEngine/
//    HeadPoseTracker · step 8 SceneDescriber · step 9 TripTracker/LiveActivityController
//    (+ thermal downgrade in `updateThermal`; there is no separate watchdog type) · step 10
//    AudioRouteMonitor (AirPods / watch presence) · step 11 SceneContext/HazardScanner/HazardLog · step 14 FaceHeadPose/
//    SoundWatcher/DualCameraSession · step 22/25 route-start readiness interlock · step 23
//    ConversationCoordinator/VoiceInputEngine · step 34 flashlight (`TorchSwitch`) · step 36 cue
//    profile (`CueRules`) · step 37 `speech_dispatch` / `speech_end` logging (`SpeechResume`).
//
//  Tests: this class has no unit tests of its own (it needs ARKit, Core Haptics, WatchConnectivity).
//  Its decisions are pinned in CaneKitLogic: `CueDeciderTests`, `NavSupportTests` (CueSpeechPolicy,
//  StraightWalkDetector), `HazardTests` (GroundHazardPolicy), `DepthReadinessTests`,
//  `LiveViewTests` (FaceTrackingChange, BothCameras), `TorchSwitchTests`, `CueProfileTests`,
//  `LaunchRecoveryTests`, `HeadYawSourcesTests`, `SoundAlertsTests`, `SpokenPhrasesTests`,
//  `TripLogRecordTests`. End to end: `make uitest` (accessibility-label contract, AGENTS.md hard
//  rule 9) and `make e2e` (GPS replay through this wiring; reads the trip log it writes).
//

import ARKit
import AVFoundation
import CaneKitLogic
import CoreLocation
import Observation
import SwiftUI

/// The single app-wide model: owns every engine, persists settings, and routes events between
/// engines. SwiftUI views read its published state; nothing else creates engines.
@MainActor
@Observable
final class AppModel {

    /// The live instance, for App Intents (Action button) that run inside the app process.
    /// Set in `init`; weak so it never extends the model's lifetime. Read by
    /// `IntentSupport.model()`, which polls for it on a cold lock-screen launch.
    private(set) static weak var shared: AppModel?

    // MARK: Engines

    /// LiDAR lanes + gyro gate (step 2).
    let depth = DepthEngine()
    /// Taptic Engine renderer (step 3).
    let haptics = HapticPlayer()
    /// JSONL trip log for reproducible test walks.
    let logger = TripLogger()
    /// The app's single voice (step 4).
    let speech = SpeechQueue()
    /// WatchConnectivity link (step 5).
    let watch = PhoneWatchLink()
    /// GPS + compass (step 6). Runs for the whole foreground session from `start()` (not only
    /// during a route); stopped only when backgrounded with no route running.
    let location = LocationService()
    /// Waypoint navigation (step 6). Owns the pure geofence / turn-settle / veer logic; speaks
    /// through `onSpeak` / `onRepeat`, wired in `wireNavigation`.
    let nav = NavigationEngine()
    /// Spatial-audio beacon (step 7). Renders only into headphones; `enabled` mirrors `beaconEnabled`.
    let beacon = BeaconEngine()
    /// AirPods head yaw (step 7) and pitch (the nod-to-talk gesture). Started only while a route
    /// runs (`startRouteNow`, or a mid-route AirPods connect).
    let head = HeadPoseTracker()
    /// Head yaw from the **front** camera's `ARFaceAnchor`, running beside LiDAR depth — the
    /// fallback that makes the AirPods optional (step 14).
    let faceHead = FaceHeadPose()
    /// Danger-sound recognition on the microphone (sirens, horns, vehicles); off by default.
    /// Built in `init` because it needs `speech`, which owns the audio session (step 14).
    let sounds: SoundWatcher
    /// Front **and** back camera previews at once (`AVCaptureMultiCamSession`), for a sighted
    /// spotter and the demo video. Off by default; ARKit is paused while it runs (step 14).
    let bothCameras = DualCameraSession()
    /// Headphones present? (beacon gate, spoken connect/disconnect lines).
    let audioRoute = AudioRouteMonitor()
    /// "Where am I" (step 8). Built in `init` because it needs `depth.processor` and `speech`.
    let describer: SceneDescriber
    /// Elapsed / distance / steps for the arrival card (step 9).
    let trip = TripTracker()
    /// Dynamic Island / lock screen (step 9).
    let liveActivity = LiveActivityController()
    /// Medical ID card, emergency profile and mobility fitness tracking (step 43).
    let medicalProfile = MedicalProfileStore()
    /// LiDAR facts handed to the on-device describer ("1.4 meters ahead, obstacle."). A
    /// `Sendable` lock-guarded box: written here on the main actor (`contextLine` per report),
    /// read off-main by the on-device VLM client. Built in `init` (the VLM client needs it).
    let sceneContext: SceneContext
    /// Camera hazards: signs (on-device) + hazard watch (cloud → on-device, or on-device).
    let hazards: HazardScanner
    /// Hazard map: every announced hazard with GPS + photo → Documents/hazards/*.geojson.
    let hazardLog = HazardLog()
    /// Cane-went-over detector (CoreMotion → CaneKitLogic `FallDetector`). ⚠ Unvalidated
    /// thresholds; see FallDetector.swift.
    let fallWatcher = FallWatcher()
    /// Spam guard for the two buttons that POST to the webhook (CaneKitLogic; 10 s apart).
    @ObservationIgnored private var actionLimit = ActionRateLimit()
    /// Family alerts: cane detections → the Grok Bot routine "OpenCane cane events" (step 39).
    /// Off unless `familyAlertsEnabled`; unconfigured (no webhook key) is a no-op that says so.
    let family = FamilyAlerts()
    /// The cloud mirror (step 45): every local store — settings, family list, Medical ID, trip
    /// log, hazard map, posts, alerts — kept in Supabase as well as on the phone. Inert when
    /// `Secrets.plist` has no `SUPABASE_URL` / `SUPABASE_ANON_KEY`, and never on the cue path.
    let cloud = CloudSync()
    /// Last LiDAR ground hazard spoken ("Two meters ahead, drop-off."), for the Hazards card's
    /// LIDAR row. Set by `groundHazardFound`; cleared by `startRouteNow` so a new route never shows
    /// the previous route's drop-off.
    private(set) var lastGroundHazard: String?
    /// When a confirmed ground hazard is worth saying again (CaneKitLogic, HazardTests): the same
    /// kind within 1 m is silent for 30 s unless the walker is ≥ 1 m closer. AR clock. `reset()`
    /// at every `startRouteNow`.
    @ObservationIgnored private var groundPolicy = GroundHazardPolicy()

    /// Conversational assistant coordinator (dialogue memory, history, tool dispatching, markers;
    /// Step 23). Implicitly unwrapped because it takes `self` (held weakly): Swift only allows
    /// passing `self` once every stored property is initialised, so it is assigned last in `init`
    /// and is non-nil from then on. Read by `GuideCard` (`isProcessing` → "Thinking…") and by the
    /// voice-input transcript handler wired in `start()`.
    private(set) var conversation: ConversationCoordinator!
    /// On-device push-to-talk speech recognition (`SFSpeechRecognizer`, Step 23/24). Assigned at
    /// the end of `init` beside `conversation` (same implicitly-unwrapped pattern). It borrows the
    /// microphone through `SpeechQueue`'s lease and mutes the beacon while listening; wired in
    /// `start()` (`onTranscriptionFinalized`, `shouldRestorePlaybackSession`, `onEvent`).
    private(set) var voiceInput: VoiceInputEngine!

    /// Route picker state: the destination text typed in the route field (read/write from the UI).
    /// Also overwritten by `navigate(to:)` (trimmed text, or the gazetteer place name), so a Siri
    /// or voice destination shows up in the box.
    var destinationQuery = ""
    /// Last route-building failure shown under the route picker; nil when there is none.
    /// "Type a destination first" is also an accessibility/test string (AGENTS.md hard rule 9).
    /// Set by `navigate(to:)`, `buildRoute`, `startDemoRoute`, `announceCameraDenied`,
    /// `announceLocationDenied`, `failQueuedRouteStart` and the both-cameras refusals; cleared by
    /// `clearRouteError` (every keystroke), a new build and `startRouteNow`.
    private(set) var routeError: String?
    /// True while a MapKit build (`buildRoute`: typed field, Siri, "Navigate to CIF from here")
    /// waits for a fix and MapKit directions (UI shows progress, Go / CIF buttons disabled).
    private(set) var isBuildingRoute = false
    /// Visible state while a route request waits for post-camera-transition depth evidence.
    /// This is deliberately separate from `routeError`: the request is still alive and will
    /// continue automatically when the interlock clears.
    private(set) var routeStartStatus: String?
    /// True only while a route request is queued. This is stored (rather than computed from the
    /// ignored pending payload) so SwiftUI invalidates the Guide and Hazards cards immediately.
    /// A timed-out status remains visible but does not disable a retry.
    private(set) var routeStartWaiting = false

    // MARK: - On-Device Walk Simulation
    /// True while simulating walking the route indoors on this device.
    var isSimulatingWalk = false
    /// Speed for the on-device walk simulator (metres per second). Default 1.4 m/s.
    var simulationSpeedMps: Double = 1.4
    /// Background task driving simulated walk fixes.
    @ObservationIgnored private var simulatedWalkTask: Task<Void, Never>?
    /// Generation counter guarding simulated walk cancellation and task races.
    @ObservationIgnored private var simulatedWalkGeneration = 0

    /// A route that has been requested but cannot start until the depth interlock is ready
    /// (Step 22/25). Value type so it can be held across the readiness wait without aliasing.
    private struct PendingRouteStart: Sendable {
        /// The route to hand to `startRouteNow` once depth is ready.
        let route: Route
        /// The "Walking to <place>, N meters." line for a MapKit route, spoken when it finally
        /// starts; nil for the bundled demo route.
        let announce: String?
    }

    /// Pending route-start state is app-owned; the pure consecutive-frame / timeout decisions live
    /// in `DepthReadiness` and are owned by `DepthEngine`. Non-nil exactly while
    /// `routeStartWaiting` is true; cleared by `depthReadinessChanged(.ready)`,
    /// `failQueuedRouteStart` and `cancelPendingRouteStart`.
    @ObservationIgnored private var pendingRouteStart: PendingRouteStart?
    /// Waits for queued two-camera work to drain, arms `depth.beginReadiness`, then polls
    /// `depth.pollReadiness` every 100 ms until the state leaves `.warming`. Cancelled by every
    /// path that clears `pendingRouteStart`.
    @ObservationIgnored private var routeReadinessTask: Task<Void, Never>?
    /// The request's own deadline (`DepthReadiness.standardConfiguration.timeout`, 5 s), separate
    /// from the pure gate's so a camera transition that never drains still fails loudly.
    @ObservationIgnored private var routeReadinessTimeoutTask: Task<Void, Never>?
    /// Bumped (`&+=`) by every queue, failure and cancel; a readiness task whose captured number
    /// is no longer current exits without touching state (the `routeBuildGeneration` pattern).
    @ObservationIgnored private var routeStartGeneration = 0

    /// Pure route-time policy for AR configuration changes. User changes are refused while a
    /// route is warming or guiding; thermal mesh changes are deferred until the route ends.
    @ObservationIgnored private var sensorModeInterlock = SensorModeInterlock()
    /// Deferred-release task used when a route ends while the serialized MultiCam teardown still
    /// owns the cameras. It is canceled if a newer route reserves the interlock first; the
    /// deferred thermal mode then remains protected by the new route.
    @ObservationIgnored private var sensorModeFinishTask: Task<Void, Never>?
    @ObservationIgnored private var sensorModeFinishGeneration = 0
    /// True after an active-route AR failure/interruption has invalidated obstacle sensing. It is
    /// cleared only by a running engine plus a same-frame normal/trusted report, never merely by
    /// an "AR resumed" status or a stale queued report.
    @ObservationIgnored private var depthSafetyDegraded = false
    /// Prevents a refused setting write from re-entering its own `didSet` while the UI switch is
    /// snapped back to the value that was actually applied.
    @ObservationIgnored private var revertingSensorModeSetting = false

    /// Decides which cue fires from each lane report (pure logic, CaneKitLogic).
    /// ⚠ Its timing contract is the AR clock; see `handle(_:)`. A `let` of a (final) class:
    /// `applyCueRules` writes `decider.thresholds.head` (Indoors shortens it to 1.2 m), and every
    /// ARKit pause (`scenePhaseChanged(.background)`, both cameras on) calls `reset()`.
    @ObservationIgnored private let decider = CueDecider()
    /// "Two meters ahead, door" from the mesh classification (step 4). Consulted only while
    /// `obstacleNamesEnabled`; `reset()` wherever the decider is reset.
    @ObservationIgnored private let namer = ObstacleNamer()
    /// Kind currently decided as active (for the UI and the `lanes` log line); `.clear` when
    /// nothing is in range or after any ARKit pause.
    private(set) var activeCue: CueKind = .clear

    // MARK: Device capabilities (fixed for the life of the process)

    /// True on LiDAR iPhones: `ARFrame.sceneDepth` will be populated.
    let lidarSupported = DepthEngine.supportsDepth
    /// True when ARKit can build a classified mesh (door / wall / seat …).
    let meshClassificationSupported = DepthEngine.supportsMesh

    // MARK: Runtime state shown in the UI

    /// One-line status for the header ("Depth OK", "No LiDAR", …).
    var status: String { depth.status }
    /// Set once `start()` has run; guards against double starts from `.task` re-entry.
    /// Also what `IntentSupport.model()` waits for (an intent must not act on an unwired model)
    /// and what `scenePhaseChanged` / `updateThermal` check before acting.
    private(set) var started = false
    /// Thermal state name, set by `updateThermal` (which also applies the heat downgrade).
    /// One of `nominal|fair|serious|critical|unknown`; also written into every `lanes` log line
    /// and into the `both_cameras` / `face_head_selftest` records.
    private(set) var thermalName = "nominal"
    /// 0–100, or -1 when unknown (simulator). Set by `updateBattery`; read by the `lanes` log line,
    /// `speakStatus` and `ConversationCoordinator` (battery questions).
    private(set) var batteryPercent = -1

    // MARK: Settings (persisted; each `didSet` pushes into the engines that care)
    //
    // Each setting is a UserDefaults key of the same name (see `Settings`). `didSet` does not run
    // for the initial value, so `init()` pushes the loaded values into the engines once.

    /// Phone mounted upright (portrait, camera at the top). See ios/README.md §6 for the remap.
    /// Pushed to `depth.apply(portrait:mirror:)` via `pushDepthSettings()`.
    var portraitMode: Bool = Settings.bool("portraitMode", default: true) {
        didSet {
            Settings.set(portraitMode, "portraitMode")
            pushDepthSettings()
            // Tilt is measured off whichever axis points up the cane; a stale value here would
            // make every fall look upright and none would ever be reported.
            fallWatcher.portraitMount = portraitMode
        }
    }
    /// Swap left/right if the mount points the camera the other way.
    /// Toggled by the "Mirror left / right" control (accessibility label is a UI-test contract).
    var mirrorLeftRight: Bool = Settings.bool("mirrorLeftRight", default: false) {
        didSet { Settings.set(mirrorLeftRight, "mirrorLeftRight"); pushDepthSettings() }
    }
    /// Master haptic silence (state machine keeps running so speech/watch stay in sync).
    /// While silenced, obstacle cues are mirrored to the watch and spoken (see `handle(_:)`).
    var hapticsSilenced: Bool = Settings.bool("hapticsSilenced", default: false) {
        didSet { Settings.set(hapticsSilenced, "hapticsSilenced"); haptics.silenced = hapticsSilenced }
    }
    /// Write the JSONL trip log. Mirrored into `logger.enabled`; turning it off flushes the buffer.
    var loggingEnabled: Bool = Settings.bool("loggingEnabled", default: true) {
        didSet { Settings.set(loggingEnabled, "loggingEnabled"); logger.enabled = loggingEnabled }
    }
    /// Speak obstacle names ("Two meters ahead, door"). Off = haptics only.
    /// Read on every report in `handle(_:)`; not pushed anywhere. Even when on, `cueRules` decides
    /// which classes may be named (Quiet / Indoors: none; Standard: doors on a route; Detailed:
    /// all but walls).
    /// ⚠ Default **off** since Step 36 (cue design v2 #2, the lowest-risk calming change): the first
    /// field log suppressed 10 names in 2 minutes, and blind travellers rank furniture names lowest
    /// because the cane finds furniture (docs/cue_design_v2.md P1/P7). A walker who turned it on
    /// before keeps their stored `true`; a walker who never touched the switch (no stored key, so
    /// the old default applied) now has names off — turn them on for the D6 names test and demos.
    var obstacleNamesEnabled: Bool = Settings.bool("obstacleNamesEnabled", default: false) {
        didSet { Settings.set(obstacleNamesEnabled, "obstacleNamesEnabled") }
    }
    /// Cue verbosity level (Settings → Cues). Persisted as `CueLevel.rawValue` under `cueLevel`.
    /// ⚠ Default `.detailed` = today's behaviour until a trip log from the MOUNTED cane tunes the
    /// calmer levels (owner decision 2026-09-12; AGENTS.md "How we engineer" 6). A change is
    /// applied (`applyCueRules`), spoken once at `.nav` ("Quiet cues.") and logged `cue_profile`.
    var cueLevel: CueLevel = CueLevel(rawValue: Settings.string("cueLevel", default: CueLevel.detailed.rawValue)) ?? .detailed {
        didSet { cueProfileChanged(levelChanged: cueLevel != oldValue, placeChanged: false) }
    }
    /// Outdoors / Indoors (Settings → Cues). Persisted as `CuePlace.rawValue` under `cuePlace`;
    /// default outdoors (today). Indoors shortens the head distance to 1.2 m, names nothing and
    /// reads only safety signs (`CueRules`).
    var cuePlace: CuePlace = CuePlace(rawValue: Settings.string("cuePlace", default: CuePlace.outdoors.rawValue)) ?? .outdoors {
        didSet { cueProfileChanged(levelChanged: false, placeChanged: cuePlace != oldValue) }
    }
    /// The rules the current level × place imply (CaneKitLogic `CueRules`, `CueProfileTests`).
    var cueRules: CueRules { CueRules(level: cueLevel, place: cuePlace) }

    /// Persist, apply, speak and log a level or place change. Called only from the two `didSet`s;
    /// an unchanged value (a picker re-selecting its current segment) does nothing.
    private func cueProfileChanged(levelChanged: Bool, placeChanged: Bool) {
        guard levelChanged || placeChanged else { return }
        Settings.set(cueLevel.rawValue, "cueLevel")
        Settings.set(cuePlace.rawValue, "cuePlace")
        applyCueRules()
        let line = levelChanged ? cueLevel.spokenLine : cuePlace.spokenLine
        speech.say(line, .nav, ttl: 6)
        logger.event("cue_profile", ["level": cueLevel.rawValue, "place": cuePlace.rawValue, "text": line])
    }

    /// Push `cueRules` into the engines that hold a copy: the head distance into `CueDecider`, the
    /// allowed sign phrases into `HazardScanner`. Obstacle names read `cueRules` per report in
    /// `handle(_:)`. Called from `init` (stored values) and `cueProfileChanged`.
    private func applyCueRules() {
        let rules = cueRules
        decider.thresholds.head = rules.headEnterM
        hazards.signAllowedPhrases = rules.allowedSignPhrases
    }

    /// Spatial click toward the next waypoint while navigating. Mirrored into `beacon.enabled`.
    var beaconEnabled: Bool = Settings.bool("beaconEnabled", default: true) {
        didSet { Settings.set(beaconEnabled, "beaconEnabled"); beacon.enabled = beaconEnabled }
    }
    /// Mirror every obstacle cue to the watch even while the phone engine is healthy.
    /// Read in `handle(_:)` and `groundHazardFound`; not pushed anywhere.
    var fallbackToWatch: Bool = Settings.bool("fallbackToWatch", default: false) {
        didSet { Settings.set(fallbackToWatch, "fallbackToWatch") }
    }
    /// LiDAR drop-off / hole / curb warnings (Hazards card).
    /// Default OFF until validated on the phone (the review's sweep simulation; AGENTS.md).
    var groundHazardsEnabled: Bool = Settings.bool("groundHazardsEnabled", default: false) {
        didSet { Settings.set(groundHazardsEnabled, "groundHazardsEnabled"); pushDepthSettings() }
    }
    /// On-device sign reading (Hazards card).
    var signsEnabled: Bool = Settings.bool("signsEnabled", default: true) {
        didSet { Settings.set(signsEnabled, "signsEnabled"); hazards.signsEnabled = signsEnabled }
    }
    /// Periodic vision-model hazard check while walking a route (Hazards card).
    /// Default OFF until validated on the phone.
    var hazardWatchEnabled: Bool = Settings.bool("hazardWatchEnabled", default: false) {
        didSet { Settings.set(hazardWatchEnabled, "hazardWatchEnabled"); hazards.watchEnabled = hazardWatchEnabled }
    }
    /// Send cane events (fall, SOS, close obstacle, breadcrumb, low battery) to the Grok Bot
    /// routine so it can alert family.
    ///
    /// Default **OFF** (AGENTS.md → new untuned features ship off, and this one sends the walker's
    /// position off the phone, so it is opt-in twice over: the switch here and a webhook key in
    /// Secrets.plist). In `LaunchRecovery.optionalFeatureKeys`, so a crash loop clears it.
    var familyAlertsEnabled: Bool = Settings.bool("familyAlertsEnabled", default: false) {
        didSet {
            Settings.set(familyAlertsEnabled, "familyAlertsEnabled")
            family.enabled = familyAlertsEnabled
            applyFallWatcher()
        }
    }
    /// Family email addresses the bot should alert. Stored normalised (`FamilyContacts.normalize`),
    /// so what is on disk is what gets posted.
    ///
    /// ⚠ Editing this list does NOT register it — `saveFamilyContacts()` does. Kept apart on
    /// purpose: typing half an address should not fire a webhook, and the bot emails a
    /// confirmation to every address on the first accepted Save.
    private(set) var familyEmails: [String] = FamilyContacts.normalize(
        Settings.strings("familyContactEmails", default: []))

    /// True once the bot has accepted a contact list. Drives `send_test`: the confirmation email
    /// goes out on the first successful registration only, not every time the walker edits.
    private(set) var familyContactsRegistered = Settings.bool("familyContactsRegistered", default: false)

    /// True when the stored list has not been registered since it last changed — the Settings
    /// card uses it to show that Save is still needed.
    private(set) var familyContactsNeedSave = false

    /// Watch for the cane going over and report it to family.
    ///
    /// Default **on** — the owner asked for falls to be reported, and it only ever sends anything
    /// while family alerts are also on. ⚠ It is nonetheless the least validated thing in the app:
    /// the thresholds have never been measured against a real cane (docs/todo.md), so if it cries
    /// wolf on the phone, turn it off here rather than living with it.
    var fallDetectionEnabled: Bool = Settings.bool("fallDetectionEnabled", default: true) {
        didSet { Settings.set(fallDetectionEnabled, "fallDetectionEnabled"); applyFallWatcher() }
    }

    /// Let a cheap model add one sentence of context to each family alert (`extra.ai_context`).
    ///
    /// Default **on**, unlike the alert switch itself: by the time this matters the walker has
    /// already opted into sending events, and context is the difference between "obstacle" and
    /// "stopped 40 m from CIF with 12 % battery". It is still a switch because it costs a model
    /// request per alert and can delay one by up to `AlertSummarizer.requestTimeout`.
    var familyAlertsAIContext: Bool = Settings.bool("familyAlertsAIContext", default: true) {
        didSet { Settings.set(familyAlertsAIContext, "familyAlertsAIContext"); family.aiContextEnabled = familyAlertsAIContext }
    }
    /// Name people (and dogs / cats) in "Where am I" (Hazards card).
    ///
    /// Default **ON**, unlike the drop-off and hazard-watch switches: this runs nowhere near the
    /// cue path — only when the walker asks "Where am I", a few times a walk — and it is expected
    /// to add no wall clock there, because the body detectors run concurrently with the text pass
    /// (`OnDeviceVision.detect`), which is the long pole. It is a switch at all because Vision's neural
    /// models cannot be exercised in the simulator: the first real evidence comes from the phone,
    /// and if the detector is noisy on the cane it can be turned off here without a rebuild.
    var namePeopleEnabled: Bool = Settings.bool("namePeopleEnabled", default: true) {
        didSet {
            Settings.set(namePeopleEnabled, "namePeopleEnabled")
            sceneContext.setPeopleEnabled(namePeopleEnabled)
        }
    }
    /// Live camera view on the Hazards card (sighted helper / demo video). Not persisted: off at launch.
    /// Nothing in the model reacts to it: `HazardsCard` decides what to draw with `LiveView.state`
    /// (CaneKitLogic, LiveViewTests) and renders `LiveCameraView` straight from
    /// `depth.arSession` — no JPEG polling, no extra camera work.
    var liveViewEnabled = false

    /// "Both cameras": the front **and** back camera previews on screen at the same time, through
    /// `AVCaptureMultiCamSession`, with **ARKit paused** for the duration.
    ///
    /// Deliberately **not persisted** and false at launch: while it is on there are no obstacle
    /// lanes, no depth, no ground hazards and no sign reading, and no launch may ever come up in
    /// that state. Writing it goes through `setBothCameras(_:)`, which owns the whole trade —
    /// pausing ARKit, saying out loud that the safety channel is off, and refusing while a route
    /// is running. ⚠ Do not add a `Settings.set` here.
    var bothCamerasEnabled = false {
        didSet {
            // `applyingBothCameras` is not decoration. `setBothCameras` snaps the switch back
            // (refused during a route, unsupported hardware), which re-enters this `didSet`;
            // without the flag that second pass ran the whole *off* path — resuming a depth engine
            // that was never paused and speaking "Obstacle detection is back." after a refusal that
            // never turned it off.
            guard bothCamerasEnabled != oldValue, !applyingBothCameras else { return }
            applyingBothCameras = true
            setBothCameras(bothCamerasEnabled)
            applyingBothCameras = false
        }
    }

    /// True while `setBothCameras` is running, so its own writes to `bothCamerasEnabled` cannot
    /// re-enter it. See the `didSet` above.
    @ObservationIgnored private var applyingBothCameras = false

    /// Back-camera flashlight as the on-screen switch shows it: the walker's request at once
    /// while it settles, then the device's own `isTorchActive` (`torchSwitch.displayed`).
    /// Device-level torch: it touches no capture session, so it works while ARKit runs, while
    /// both-cameras runs, and mid-route, and is never refused the way both-cameras is. Not
    /// persisted and false at launch: a pocketed phone with the torch on is a dead battery and a
    /// burn risk. Written only by `applyTorch(_:)`; the card binds through `setTorch(_:)`.
    private(set) var torchEnabled = false

    /// The flashlight state machine (CaneKitLogic `TorchSwitch`): optimistic display, confirmation
    /// by device report, failure only after its settle deadline. ⚠ It exists because reading
    /// `isTorchActive` right after setting it returned the old value on the phone and snapped the
    /// switch back on every press (trip log 2026-09-12T20-57-17Z; `TorchSwitchTests`).
    @ObservationIgnored private var torchSwitch = TorchSwitch()
    /// The back camera device the torch is set and observed on. Stored, not re-fetched: KVO holds
    /// its target weakly and must watch the same instance the torch is set through (Step 34
    /// review, Muse + Antigravity). Main actor only; never crosses into the KVO closure.
    @ObservationIgnored private var torchDevice: AVCaptureDevice?
    /// KVO on `torchDevice.isTorchActive`, installed on the first `setTorch`; kept for the app's
    /// lifetime so a thermal cut-out with no window open is still announced.
    @ObservationIgnored private var torchObservation: NSKeyValueObservation?
    /// The settle-deadline task of the latest request; replaced (cancelled) by each new request.
    @ObservationIgnored private var torchDeadline: Task<Void, Never>?

    /// Turn the back-camera torch on or off; the outcome is spoken when the device confirms it
    /// or when the settle deadline passes.
    ///
    /// The torch is a property of the camera device, not of any session: ARKit keeps its
    /// frames and the multi-cam session keeps its feeds either way, which is why this works
    /// everywhere both-cameras cannot (mid-route, with obstacle detection alive). The switch
    /// shows the request immediately (`TorchSwitch.request`); a thrown lock or set error snaps it
    /// back at once, a silent refusal (thermal) snaps it back at the deadline with "The flashlight
    /// did not switch on.". The trip log records `torch {action, active, outcome}` per outcome, so
    /// a device run measures whether torch + ARKit coexist on this phone.
    /// - Parameter on: the requested state.
    /// Main actor. Caller: `HazardsCard`'s Flashlight toggle.
    func setTorch(_ on: Bool) {
        guard let device = torchDevice
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              device.hasTorch else {
            torchEnabled = false
            speech.say("This phone has no flashlight.", .scene, ttl: 6)
            logger.event("torch", ["action": "unsupported"])
            return
        }
        torchDevice = device
        observeTorch(device)
        torchSwitch.request(on, now: ProcessInfo.processInfo.systemUptime)
        torchEnabled = torchSwitch.displayed
        logger.event("torch", ["action": on ? "request_on" : "request_off", "active": device.isTorchActive])
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if on {
                try device.setTorchModeOn(level: 1.0)
            } else {
                device.torchMode = .off
            }
        } catch {
            // A thrown error is a definite answer: close the window now instead of at the deadline.
            torchDeadline?.cancel()
            applyTorch(torchSwitch.tick(active: device.isTorchActive, now: .infinity),
                       active: device.isTorchActive, error: error.localizedDescription)
            return
        }
        // ⚠ No `report` from `device.isTorchActive` here: on the line after setting it, that read is
        // the OLD state (the measured bug), and after a quick OFF→ON it can even match the new
        // request and confirm too early (Step 34 review). KVO confirms; the deadline decides.
        torchDeadline?.cancel()
        let settle = torchSwitch.configuration.settleSeconds
        torchDeadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(settle))
            guard !Task.isCancelled, let self, let device = self.torchDevice else { return }
            let active = device.isTorchActive
            // `.infinity`: this task IS the deadline. Comparing `systemUptime` (stops in system
            // sleep) with a `ContinuousClock` sleep could leave the window open forever.
            self.applyTorch(self.torchSwitch.tick(active: active, now: .infinity), active: active)
        }
    }

    /// Install the one `isTorchActive` observer (no-op after the first call). Caller: `setTorch`.
    /// KVO calls back on an arbitrary thread, so the
    /// `@Sendable` closure only hops to the main actor (AGENTS.md hard rule 1). The hop re-reads
    /// `torchDevice.isTorchActive` rather than trusting `change.newValue`: unstructured main-actor
    /// tasks are not guaranteed FIFO, and reordered snapshots could leave the switch showing a
    /// state the device left (Step 34 review, Muse + Antigravity). Re-reading makes every hop
    /// apply the current truth, whatever order they run in.
    private func observeTorch(_ device: AVCaptureDevice) {
        guard torchObservation == nil else { return }
        torchObservation = device.observe(\.isTorchActive, options: []) { @Sendable [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, let device = self.torchDevice else { return }
                let active = device.isTorchActive
                self.applyTorch(self.torchSwitch.report(active: active,
                                                        now: ProcessInfo.processInfo.systemUptime),
                                active: active)
            }
        }
    }

    /// Publish a `TorchSwitch` outcome: update the switch, speak its fixed line at `.scene` for
    /// `Outcome.queueSeconds` (4 s for a confirmation, 12 s for a failure or device change), log it.
    /// `.none` only refreshes the switch. Main actor.
    /// - Parameters:
    ///   - outcome: what `TorchSwitch.report` / `tick` decided.
    ///   - active: the device's `isTorchActive` read on this hop (logged as `active`).
    ///   - error: a thrown lock / set error's description, logged as `error` when present.
    /// Callers: `setTorch` (thrown error), its deadline task, the KVO hop in `observeTorch`.
    private func applyTorch(_ outcome: TorchSwitch.Outcome, active: Bool, error: String? = nil) {
        torchEnabled = torchSwitch.displayed
        guard let line = outcome.spokenLine else { return }
        speech.say(line, .scene, ttl: outcome.queueSeconds)
        var fields: [String: Any] = ["action": "\(outcome)", "active": active, "text": line]
        if let error { fields["error"] = error }
        logger.event("torch", fields)
    }

    /// Head tracking from the **front** camera instead of the AirPods (`DepthEngine`'s
    /// `userFaceTrackingEnabled`). Default OFF: new and untuned on the real cane (AGENTS.md rule
    /// 6), and it costs the TrueDepth camera's power. Turning it on re-runs the AR session
    /// (~1–2 s of depth), which is why it is a *setting* and not something the app flips itself.
    ///
    /// ⚠ **Not persisted**, for the same reason the microphone switch below is not — and this one
    /// was learned the hard way. It *was* persisted, and on 2026-09-12 that made the app
    /// unstartable. The evidence, from the phone:
    ///   · `canekit-2026-09-12T02-40-53Z.jsonl`, t=17.583:
    ///     `{"kind":"face_tracking","supported":true,"enabled":true}` — the switch went on. "Both
    ///     cameras" was running at the time (t=5.772), so ARKit was paused and
    ///     `DepthEngine.setFaceTracking` only stored the flag; the session was never actually run
    ///     with it in that process.
    ///   · `canekit-2026-09-12T02-41-13Z.jsonl`, the next launch: three records —
    ///     `session` (t=0.641), `start` with `"face_head_tracking":true` (t=0.667) and
    ///     `multicam_depth` (t=0.827) — and the file stops. `TripLogger` buffers and flushes every
    ///     2 s, so those reached disk at the t≈2 s flush and nothing survived the t≈4 s one: the
    ///     process died inside the ARKit warm-up, before the first `lanes` record (the healthy
    ///     session before it wrote one at t=3.117).
    /// Persisting it meant the first thing the app did on every later launch was the thing that
    /// had just killed it, and the switch that would turn it off is on a screen the app never
    /// reached. A blind walker cannot get out of that. Like the microphone below, the front camera
    /// is cheap to turn on and expensive to notice, so it is a per-session choice now and not a
    /// setting that re-arms itself because of something the walker did yesterday.
    /// `LaunchRecovery` (CaneKitLogic) is the belt to this braces: it also *removes* any
    /// `faceHeadTrackingEnabled` an older build left on disk.
    var faceHeadTrackingEnabled: Bool = false {
        didSet {
<<<<<<< HEAD
            guard !applyingFaceTracking, faceHeadTrackingEnabled != oldValue else { return }
            // Either direction re-runs the AR session (~1–2 s without obstacle frames), so a
            // route refuses it like the two-camera mode (`FaceTrackingChange`, LiveViewTests).
            let change = FaceTrackingChange.decide(navigating: nav.isNavigating,
                                                   routeStartWaiting: routeStartWaiting)
            guard change == .apply else {
                applyingFaceTracking = true
                faceHeadTrackingEnabled = oldValue
                applyingFaceTracking = false
                // No `routeError`: that is the Guide card's route-build line and nothing clears it on
                // this path (Step 34 review). The spoken line and the Sense caption explain it.
                if change == .refusedRoute {
                    speech.say("Head tracking without AirPods cannot change while a route is guiding you. Stop the route first.",
                               .nav, ttl: 10)
                    logger.event("face_tracking", ["action": "refused_route", "requested": !oldValue])
                } else {
                    speech.say("Head tracking without AirPods cannot change while a route is starting. Wait for obstacle detection to be ready.",
                               .nav, ttl: 10)
                    logger.event("face_tracking", ["action": "refused_route_start", "requested": !oldValue])
                }
=======
            guard !revertingSensorModeSetting else { return }
            let decision = sensorModeInterlock.request(.faceTracking, source: .user)
            guard decision == .allowRestart else {
                revertingSensorModeSetting = true
                faceHeadTrackingEnabled = oldValue
                revertingSensorModeSetting = false
                rejectSensorModeChange(.faceTracking, decision: decision)
>>>>>>> 21b1717 (Step 29: interlock AR sensor mode restarts during routes)
                return
            }
            depth.setFaceTracking(faceHeadTrackingEnabled)
            if faceHeadTrackingEnabled { faceHead.start() } else { faceHead.stop() }
            logger.event("face_tracking", ["enabled": faceHeadTrackingEnabled,
                                           "supported": DepthEngine.supportsFrontCameraWithLiDAR])
        }
    }

    /// True while `faceHeadTrackingEnabled`'s `didSet` writes the old value back after a refusal,
    /// so that write does not re-enter it (the `applyingBothCameras` pattern).
    @ObservationIgnored private var applyingFaceTracking = false

    /// Danger-sound recognition on the microphone (Hazards card). Default OFF, and deliberately
    /// so: it is the only feature that moves the app's audio session off `.playback`
    /// (AGENTS.md hard rule 7), and it is untuned on a real street.
    ///
    /// ⚠ **Not persisted**, unlike every other setting on this card, and that asymmetry is the
    /// point: persisting it means one tester enabling it once arms `.playAndRecord` — the orange
    /// recording dot, and the risk of AirPods dropping to call quality — on *every* later launch,
    /// before anyone opens the Hazards card to see it is on. A microphone that turns itself on
    /// because of something you did yesterday is not a setting, it is a surprise. Turning it on is
    /// cheap; noticing it turned itself on is not.
    ///
    /// **Should it default to ON?** It is the only sensor that can hear an ambulance behind the
    /// walker, which is the one hazard no other sensor here can reach — so the question is real,
    /// and the answer today is still no, on evidence rather than caution:
    ///   · With `.playAndRecord` + `.allowBluetoothA2DP` and no HFP (hard rule 7), AirPods stay an
    ///     *output*. The input is the phone's own microphone — clamped to a cane, near the ground,
    ///     swinging, in the wind. What the classifier hears on a real walk has never been measured,
    ///     so the false-alarm rate of a feature that now says "do not start crossing" is unknown.
    ///   · The route guard that reverts to `.playback` the moment the output moves was hardened on
    ///     2026-09-11 but has **not** been exercised with AirPods on a walk. If it is wrong, the
    ///     cost is the HRTF beacon and the natural voice — two primary channels — to gain one
    ///     advisory line.
    /// Flip it on by hand at the top of a demo walk (one switch, zero launch-time risk) until a
    /// 20-minute street recording with AirPods connected shows the route holding and the false
    /// alarms counted. Then default it on, and persist it in the same change or not at all.
    ///
    /// Writes from `SoundWatcher.onFailure` (a refused microphone, a degraded audio route, a dead
    /// analyser) go through `applyingDangerSounds`, exactly as `bothCamerasEnabled` uses
    /// `applyingBothCameras`: they only put the switch back on screen, they must not re-enter the
    /// off path of a watcher that has already stopped itself.
    var dangerSoundsEnabled: Bool = false {
        didSet {
            guard dangerSoundsEnabled != oldValue, !applyingDangerSounds else { return }
            if dangerSoundsEnabled { sounds.start() } else { sounds.stop() }
        }
    }

    /// True while a `SoundWatcher` failure is snapping `dangerSoundsEnabled` back to false, so
    /// that write cannot re-enter the `didSet` above. See `wireSounds()`.
    @ObservationIgnored private var applyingDangerSounds = false

    /// "Nod to talk" (Hazards card switch, disabled when `head.isAvailable` is false;
    /// `HandsFreeOption.nodToTalk` by voice): a double head nod on the AirPods starts voice input,
    /// so a walker with both hands busy can ask OpenCane a question without the phone, the watch
    /// or Siri. Default OFF. Plain stored property with no `didSet`: `wireHeadNod` reads it at
    /// each detected nod.
    ///
    /// ⚠ **Not persisted**, for the same reason as `dangerSoundsEnabled`: the gesture detector's
    /// numbers are untuned placeholders (`HeadNodDetector`, CaneKitLogic — nothing has been walked
    /// on the cane), and a false double nod opens the microphone. A feature that can open the
    /// microphone because of something you did yesterday is a surprise, not a setting. Persist it
    /// in the same change that tunes the thresholds from real `head_nod` trip-log events, or not
    /// at all (AGENTS.md "How we engineer" §6: new untuned features ship off).
    ///
    /// Scope: head tracking (`head`, the AirPods `HeadPoseTracker`) only runs while a route is
    /// active — `startRouteNow` starts it (and `wireAudioRoute` on a mid-route AirPods connect),
    /// `stopRoute` / `endRouteQuietly` / arrival / a headphone disconnect stop it — so the gesture only works
    /// on a route, and only with AirPods connected. It only ever *starts* listening
    /// (`startVoiceInput`), never toggles: a nod while already listening is ignored, so a nod
    /// cannot cut off the walker mid-sentence. Wired in `wireHeadNod()`.
    /// ⚠ Gesture pinned by HeadNodDetectorTests (`doubleNodFiresOnceOnTheSecondNod`,
    /// `walkingSwayIsSilent`, `aLargeSlowTiltIsSilent`, `refractoryHoldsAfterAFire`).
    var nodToTalkEnabled: Bool = false

    // MARK: Lifecycle

    /// Token for the `thermalStateDidChangeNotification` observer (kept alive for the process).
    @ObservationIgnored private var thermalObserver: NSObjectProtocol?
    /// Token for the `batteryLevelDidChangeNotification` observer (kept alive for the process).
    @ObservationIgnored private var batteryObserver: NSObjectProtocol?
    /// Token for the `didEnterBackgroundNotification` observer that marks this launch healthy
    /// (`observeLaunchHealth`). Kept alive for the process, like the two above.
    @ObservationIgnored private var backgroundObserver: NSObjectProtocol?

    /// The 10 Hz beacon-sync loop (`startTicker`); non-nil only while a route is active.
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// Builds `sceneContext`, the one shared VLM client, `describer` and `hazards` (they need
    /// `depth.processor` + `speech`) and `sounds`; pushes the persisted settings into the engines
    /// (property `didSet`s do not fire for initial values, and the first `Settings` read has
    /// already run `LaunchRecovery`); registers `shared`; and finally builds `conversation` and
    /// `voiceInput`, which must come after every stored property is set because the coordinator
    /// takes `self`. Starts nothing: engines start in `start()`, called from the root view's
    /// `.task`. ⚠ Any process that creates an `AppModel` without starting it (an App Intent wake,
    /// a torn-down XCUITest, a preview — see `Settings.launchMode`) runs this, so session starts,
    /// permission prompts and the launch marker belong in `start()`, never here.
    init() {
        // One vision client for "Where am I" and the hazard watch: cloud with on-device fallback
        // when a key is set, on-device otherwise — never nil, works with no network.
        let context = SceneContext()
        sceneContext = context
        let client = VLMClientFactory.resolved(context: context)
        describer = SceneDescriber(processor: depth.processor, speech: speech, client: client,
                                   context: context)
        hazards = HazardScanner(processor: depth.processor, watchClient: client)
        // Every stored property must be assigned before any `self` property is *read* below.
        sounds = SoundWatcher(speech: speech)
        hazards.signsEnabled = signsEnabled
        hazards.watchEnabled = hazardWatchEnabled
        applyCueRules()                               // the stored level / place into the engines
        context.setPeopleEnabled(namePeopleEnabled)
        pushDepthSettings()
        depth.setHighFrameRate(highFrameRateCamera)   // before start(): only sets the flag
        // Likewise the flag, not a session re-run. Always `false` now that the switch does not
        // persist (see the property): the app can no longer come up with the front camera on
        // because of a tap in a previous session.
        depth.setFaceTracking(faceHeadTrackingEnabled)
        haptics.silenced = hapticsSilenced
        logger.enabled = loggingEnabled
        beacon.enabled = beaconEnabled
        // didSet does not fire during init: push the stored opt-in through once.
        family.enabled = familyAlertsEnabled
        family.contextProvider = { [weak self] in self?.familyContext ?? AlertContext() }
        family.aiContextEnabled = familyAlertsAIContext
        fallWatcher.portraitMount = portraitMode
        fallWatcher.onFall = { [weak self] fall in self?.fallDetected(fall) }
        hazards.onThreat = { [weak self] sighting, _ in self?.threatSeen(sighting) }
        applyFallWatcher()            // didSet does not fire during init
        AppModel.shared = self
        self.conversation = ConversationCoordinator(appModel: self, client: client)
        self.voiceInput = VoiceInputEngine(speech: speech, beacon: beacon)
        // Every persisted write mirrors to the cloud, with no per-setting wiring — see
        // `Settings.onChange`. `CloudSync` coalesces the burst a single toggle can make (the cue
        // profile writes two keys) and does nothing at all when the project is unconfigured.
        Settings.onChange = { [weak self] in
            guard let self else { return }
            self.cloud.saveSettings(self.cloudSettings)
        }
    }

    /// The full settings snapshot for `device_settings`: one property per persisted
    /// `UserDefaults` key, in the order the Settings screen shows them.
    ///
    /// ⚠ Deliberately excludes the keys that do NOT persist (`liveViewEnabled`,
    /// `bothCamerasEnabled`, `faceHeadTrackingEnabled`, `dangerSoundsEnabled`, `nodToTalkEnabled`,
    /// `torchEnabled` — see `Settings`): a column for a switch that resets every launch would say
    /// something false about the phone. Add a key here when you add one to `Settings`.
    var cloudSettings: DeviceSettingsRow {
        DeviceSettingsRow(portraitMode: portraitMode,
                          mirrorLeftRight: mirrorLeftRight,
                          cueLevel: cueLevel.rawValue,
                          cuePlace: cuePlace.rawValue,
                          obstacleNamesEnabled: obstacleNamesEnabled,
                          hapticsSilenced: hapticsSilenced,
                          beaconEnabled: beaconEnabled,
                          fallbackToWatch: fallbackToWatch,
                          groundHazardsEnabled: groundHazardsEnabled,
                          signsEnabled: signsEnabled,
                          hazardWatchEnabled: hazardWatchEnabled,
                          namePeopleEnabled: namePeopleEnabled,
                          highFrameRateCamera: highFrameRateCamera,
                          familyAlertsEnabled: familyAlertsEnabled,
                          familyAlertsAIContext: familyAlertsAIContext,
                          fallDetectionEnabled: fallDetectionEnabled,
                          familyContactsRegistered: familyContactsRegistered,
                          loggingEnabled: loggingEnabled)
    }

    /// One call for every trigger: on-screen button, watch, Action button, Camera Control.
    /// Logs a `describe` event with the provider name, then hands off to `SceneDescriber`
    /// (which waits for a camera frame and speaks at `.scene` priority).
    /// - Returns: false when a description is already in flight (spoken "Still describing the
    ///   previous scene."); the result itself arrives later through `describe_result`.
    /// Callers: `GuideCard` "Where am I", `WhereAmIIntent`, `handleWatchCommand(.describe)`,
    /// `cameraControlPressed`, and the `describeEveryWaypoint` automation hook.
    @discardableResult
    func describeScene() -> Bool {
        logger.event("describe", ["provider": describer.providerName ?? "none"])
        return describer.describe()
    }

    /// Toggles push-to-talk voice recording: first press listens, second press submits what was
    /// heard so far (listening also ends on its own after 1.5 s of silence — `UtteranceEndDetector`).
    /// - Parameter source: who pressed — the on-screen button or the Action Button intent. Written
    ///   to the trip log, so a walk recording shows a press the walker made but never heard an
    ///   answer to (AGENTS.md "make the invisible visible").
    /// Callers: "Talk to OpenCane" (`GuideCard`), the Action Button intent.
    func toggleVoiceInput(source: String = "button") {
        logger.event("voice_toggle", ["source": source, "listening": !voiceInput.isListening])
        if voiceInput.isListening {
            voiceInput.stopListeningAndSubmit()
        } else {
            voiceInput.startListening()
        }
    }

    /// Starts listening for voice input; a no-op while already listening. Unlike
    /// `toggleVoiceInput`, it can never submit or cut off the walker mid-sentence, which is why the
    /// head-nod gesture uses it. Not logged here (the caller logs `head_nod`).
    /// Callers: `wireHeadNod` (double nod with `nodToTalkEnabled`).
    func startVoiceInput() {
        if !voiceInput.isListening {
            voiceInput.startListening()
        }
    }

    /// Handles a typed or dictated query from Shortcuts / Siri by forwarding it to
    /// `ConversationCoordinator.handleQuery` (fast-path commands first, then the model; answers at
    /// `.scene`). Returns silently if a previous query is still processing (the coordinator's
    /// `isProcessing` guard) — the push-to-talk path in `start()` speaks that case instead.
    /// - Parameter text: the query, already trimmed and non-empty.
    /// Callers: `TalkToOpenCaneIntent` (a query carried by the intent).
    func handleSpokenQuery(_ text: String) async {
        await conversation.handleQuery(text)
    }

    /// Automation hook (`CANEKIT_DESCRIBE_EVERY_WAYPOINT=1`, used by `make e2e SCENARIO=streetview`):
    /// ask "Where am I" at route start and at every waypoint, so the Street View mock logs what
    /// the describer says at each corner of the route. Off unless the variable is set.
    static let describeEveryWaypoint = ProcessInfo.processInfo.environment["CANEKIT_DESCRIBE_EVERY_WAYPOINT"] == "1"

    /// Logs every "Where am I" / "Ask OpenCane" outcome (sentence or error, latency, replay frame)
    /// as `describe_result`, so a walk log shows what was actually said. Wired once in `start()`.
    /// Fields: `text`, `error`, `ms` (−1 unknown), `gate`, `cloud_text`, `question`, `provider`,
    /// `frame`, `labels`, `vision_error`, `people` (the last three read from `OnDeviceVision`'s
    /// `Mutex`es, so they describe the most recent on-device pass).
    /// `gate` is the `CloudSceneGate` verdict ("spoken", "edited: dropped count …", "refused: …",
    /// "on-device") and `cloud_text` the cloud model's raw reply, so a refusal can be read back
    /// against what the model wanted to say. Neither field may be called `kind` or `t`
    /// (`TripLogRecord` owns those).
    private func wireDescriber() {
        describer.onResult = { [weak self] text, error, ms, frame, gate, cloudText in
            self?.logger.event("describe_result", [
                "text": text ?? "", "error": error ?? "", "ms": ms ?? -1,
                "gate": gate, "cloud_text": cloudText,
                // "" for a plain "Where am I"; the walker's words for an "Ask OpenCane" run, so a
                // walk log shows which question an answer belonged to (an answer with no question
                // beside it cannot be read back). Never `kind` or `t` — `TripLogRecord` owns those.
                "question": self?.describer.lastQuestion ?? "",
                "provider": self?.describer.providerName ?? "none",
                "frame": frame,
                "labels": OnDeviceVision.lastClassify.withLock { $0.labels },
                "vision_error": OnDeviceVision.lastClassify.withLock { $0.error ?? "" },
                // What the dedicated detectors saw ("2 person, 1 dog"), so a walk log shows
                // whether people were found even on the frames where the classifier said nothing.
                "people": OnDeviceVision.lastPeople.withLock { $0 },
            ])
        }
    }

    /// 10 Hz sync of the inputs the beacon needs that have no callback of their own
    /// (speech ducking, head yaw). Cheap; runs only while a route is active.
    /// Idempotent (`guard ticker == nil`). Started by `startRouteNow`, stopped by `stopRoute`,
    /// `endRouteQuietly` and on arrival. Pushes `speech.isSpeaking`, head yaw from
    /// `HeadYawSelector` (AirPods, else front camera, else 0; 0 while a recenter is pending) and
    /// the nav target bearing (nil = beacon silent) into `BeaconEngine`; logs `head_source` on
    /// every source change; and calls `nav.tick(now:)` with wall-clock time. The task inherits
    /// the main actor; `[weak self]` so a dropped model ends the loop.
    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.beacon.setSpeaking(self.speech.isSpeaking)
                // Head yaw: AirPods when they have data, else the front camera's face anchor, else
                // zero (compass only). The `recenterPending` rule is inside the selector: after a
                // turn either source's reference belongs to the *old* leg, and adding its yaw to
                // the phone heading would double-count the body turn.
                let yaw = HeadYawSelector.choose(airPodsYaw: self.head.headYawDeg,
                                                 faceYaw: self.faceHead.yawDeg,
                                                 recenterPending: self.recenterPending)
                self.beacon.setHeadYaw(yaw.degrees)
                if yaw.source != self.headYawSource {
                    self.headYawSource = yaw.source
                    self.logger.event("head_source", ["source": yaw.source.rawValue])
                }
                self.beacon.setTarget(bearing: self.nav.isNavigating ? self.nav.targetBearing : nil)
                // Clock-driven nav checks (arrival hint while standing still: no fixes arrive).
                self.nav.tick(now: Date().timeIntervalSinceReferenceDate)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Which sensor last supplied the beacon's head yaw. Shown on the Hazards card and written to
    /// the trip log on every change (`head_source {source}`), so a walk recording says why the
    /// beacon behaved as it did — AirPods, front camera, or compass only (`HeadYawSource`,
    /// CaneKitLogic). Updated only by the ticker, so it keeps its last value between routes.
    private(set) var headYawSource: HeadYawSource = .none

    /// Cancels the beacon-sync loop; safe to call when it is not running.
    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    /// Called once from the root view's `.task` (and by `IntentSupport.model()` if an intent's
    /// 2 s wait runs out first). Idempotent (`guard !started`), so `.task` re-entry is safe.
    ///
    /// Order: arm the launch marker → thermal / battery and launch-health observers → trip log →
    /// speech log hooks (`speech_suppressed`, `speech_dispatch`, `speech_end`) → audio session →
    /// audio route + head-nod wiring → haptics → watch → navigation wiring → GPS (from launch, not
    /// route start) + location prompt → depth callbacks → danger-sound wiring → `depth.start()`
    /// (or the debug sensor probe first) → hazards and describer wiring → voice-input wiring →
    /// the `start` log record → microphone watch if on → camera-denied check → warning-line and
    /// common-line prefetch → "OpenCane ready." → launch-recovery line → `--demo-route` hook →
    /// the detached multi-cam capability probe.
    /// ⚠ Do not reorder audio session → haptics → ARKit without a device test (AirPods route and
    /// Taptic engine ownership depend on it; AGENTS.md hard rule 7: one `.playback` session).
    func start() {
        guard !started else { return }
        started = true
        // Before a single engine runs: from here on, a launch that dies is a launch the next one
        // has to recover from. `Settings.launchMode` has already read (and cleared) the previous
        // launch's marker at the first settings read in `init`.
        Settings.armLaunchMarker()
        observeThermalAndBattery()
        observeLaunchHealth()
        logger.start()
        startCloudMirror()
        liveActivity.endAllOrphanedActivities()
        recordDeviceCapabilities()
        speech.onSuppressed = { [weak self] text, load, reason in
            self?.logger.event("speech_suppressed", [
                "text": text, "load": load.rawValue, "reason": reason.rawValue
            ])
        }
        // Every line handed to a voice backend, from any caller (`SpeechQueue.onDispatch`).
        // `resume_from` > 0: a cut line continuing from that UTF-16 offset (Step 37, `SpeechResume`).
        speech.onDispatch = { [weak self] text, priority, replays, resumeFrom in
            self?.logger.event("speech_dispatch", ["text": text, "priority": "\(priority)", "replays": replays,
                                                   "resume_from": resumeFrom])
        }
        // A line's natural end, so the audit measures end → next start (`SpeechQueue.onLineEnd`).
        speech.onLineEnd = { [weak self] priority in
            self?.logger.event("speech_end", ["priority": "\(priority)"])
        }
        speech.configureAudioSession()       // before ARKit and before the haptic engine
        wireAudioRoute()
        wireHeadNod()
        haptics.start()
        watch.onCommand = { [weak self] cmd in self?.handleWatchCommand(cmd) }
        watch.onStateChange = { [weak self] _ in self?.recordDeviceCapabilities() }
        watch.activate()
        wireNavigation()
        // GPS runs from launch, not from route start. Three reasons, in order of how much they
        // matter: the walker can SEE whether GPS is working before trusting it with a route (the
        // card said "Off", which reads as broken); a first fix takes seconds, so starting a route
        // used to begin with no fix at all and every GPS-health line lives behind a fix, which is
        // why a route started indoors went silent; and the permission prompt now happens while
        // someone is looking at the screen rather than in the first moments of a walk.
        // It is stopped when the app is backgrounded with no route running (`scenePhaseChanged`),
        // so an idle phone in a pocket is not holding the GPS on.
        location.start()
        // Location prompt at launch (a sighted helper is usually present then); Motion and
        // HealthKit prompt at route start, so no three-alert pile-up on the first walk.
        // (Skipped under XCUITest: the three-choice alert races the first tap.)
        if ProcessInfo.processInfo.environment["CANEKIT_UITEST"] != "1" {
            location.requestAuthorization()
        }
        depth.onReport = { [weak self] report in
            self?.handle(report)
        }
        depth.onReadinessChanged = { [weak self] state in
            self?.depthReadinessChanged(state)
        }
        depth.onSessionFailure = { [weak self] reason in
            self?.depthSessionFailed(reason)
        }
        depth.onSessionInterruption = { [weak self] interrupted in
            self?.depthSessionInterrupted(interrupted)
        }
        // Front-camera head yaw (no AirPods needed). Only ever fires while
        // `depth.faceTrackingEnabled`; `FaceHeadPose` drops samples while it is stopped.
        depth.onFaceYaw = { [weak self] worldYawDeg, now in
            self?.faceHead.ingest(worldYawDeg: worldYawDeg, now: now)
        }
        if faceHeadTrackingEnabled { faceHead.start() }
        wireSounds()
        // Debug only (`CANEKIT_SENSOR_PROBE=1` / `--sensor-probe`): measure what this phone
        // actually allows to run beside LiDAR, before our own ARSession exists, then start depth as
        // usual. On every normal launch this is a single `false` and `depth.start()` runs inline,
        // unchanged.
        // The probe holds the camera for ~40 s, so it says so out loud first: a tester who pressed
        // "Where am I" during a silent 13 s pause once concluded the app was broken, and a debug
        // run that steals the safety channel must announce itself rather than look like a fault.
        if SensorProbe.isEnabled {
            let probe = SensorProbe()
            probe.onEvent = { [weak self] kind, fields in self?.logger.event(kind, fields) }
            speech.say("Sensor probe running. Obstacle detection starts in about forty seconds.",
                       .nav, ttl: 40)
            Task { [weak self] in
                await probe.run()
                self?.depth.start()
                self?.speech.say("Sensor probe finished. Obstacle detection is on.", .nav, ttl: 10)
            }
        } else {
            depth.start()
        }
        wireHazards()
        wireDescriber()
        // A transcript always ends in something audible and in the engine leaving `.processing`:
        // `ConversationCoordinator.handleQuery` returns silently while a previous query is still
        // in flight (its `isProcessing` guard), so that case is spoken here, and `finishProcessing`
        // runs on every path so the next press starts from `.idle`.
        voiceInput.onTranscriptionFinalized = { [weak self] transcript in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.conversation.isProcessing {
                    self.speech.say("Still working on your last question.", .scene, ttl: 6)
                } else {
                    await self.conversation.handleQuery(transcript)
                }
                self.voiceInput.finishProcessing()
            }
        }
        voiceInput.shouldRestorePlaybackSession = { [weak self] in
            !(self?.sounds.ownsMicrophoneSession ?? false)
        }
        // `voice_start` / `voice_end`: what the recogniser saw and why listening stopped, so a
        // press that produced nothing can be read back from the walk log.
        voiceInput.onEvent = { [weak self] kind, fields in self?.logger.event(kind, fields) }
        logger.event("start", ["lidar": lidarSupported, "mesh": meshClassificationSupported,
                               "haptics": haptics.isHealthy,
                               // ⚠ `haptics: false` used to be the whole story, and it is not a
                               // story: on 2026-09-12 three consecutive launches logged it with no
                               // way to tell a dead Taptic Engine from a failed
                               // `CHHapticEngine.start()`. `HapticPlayer` already holds the
                               // reason — write it down (AGENTS.md "make the invisible visible").
                               "haptics_error": haptics.lastError ?? "",
                               // Which launch this is: `recovered` means the previous one never
                               // reported itself healthy and the optional features were cleared.
                               "launch": Settings.launchMode.rawValue,
                               "vision": describer.providerName ?? "none",
                               // What this phone can run alongside LiDAR (measured, not assumed).
                               "video_format": depth.chosenFormat,
                               "video_formats": DepthEngine.supportedFormats,
                               "front_camera_with_lidar": DepthEngine.supportsFrontCameraWithLiDAR,
                               // Which of the two new sensor paths this launch is using.
                               "face_head_tracking": depth.faceTrackingEnabled,
                               "danger_sounds": dangerSoundsEnabled,
                               "sound_classifier": SoundWatcher.isAvailable,
                               // Which cue profile this walk ran with (cue_audit.py compares walks).
                               "cue_level": cueLevel.rawValue, "cue_place": cuePlace.rawValue,
                               "obstacle_names": obstacleNamesEnabled])
        // The microphone watch starts only if the walker left it on; it is off by default.
        if dangerSoundsEnabled { sounds.start() }
        let cameraDenied = announceCameraDenied()
        // Every warning line the app can *generate* (`SpokenPhrases.warningLines`: 74 lines,
        // 1,718 characters, one-time — each is cached on disk forever after its first synthesis).
        // Warnings never wait for the network — a cache miss is spoken by the system voice at once
        // — so the only way a warning is ever heard in the natural voice is for it to be on disk
        // already. Without this the walker heard route lines in the ElevenLabs voice and warnings
        // in Apple's, alternating line by line (user report, 2026-09-11).
        // `backgroundLines` rather than one batch here because the first warning that misses the
        // cache calls `prefetch` itself, which would otherwise cancel this batch half-done; as a
        // standing tail it is resumed by every later batch instead. Fire-and-forget on a detached
        // utility task inside `prefetch`: it never touches the main actor and never delays launch,
        // and a failure only writes `speech.voiceError` (the system voice still speaks everything).
        speech.backgroundLines = SpokenPhrases.warningLines
        speech.prefetch(Self.commonLines)
        if !cameraDenied {
            // ⚠ "OpenCane ready." is also in `Self.commonLines` above; the two must stay
            // byte-identical or this first line misses the ElevenLabs disk cache and the walker
            // hears Apple's system voice instead. The product is called OpenCane to a human; the
            // code, module and bundle id are still CaneKit (AGENTS.md → "The name split").
            speech.say(lidarSupported ? "OpenCane ready." : "OpenCane. This phone has no LiDAR.", .nav)
        }
        announceLaunchRecovery()
        // Automation hook (simulator GPS replay, UI tests): `--demo-route` argument or the
        // CANEKIT_DEMO_ROUTE=1 environment variable starts guidance at launch.
        if CommandLine.arguments.contains("--demo-route")
            || ProcessInfo.processInfo.environment["CANEKIT_DEMO_ROUTE"] == "1" {
            startDemoRoute()
        }
        // What this phone's cameras could do *together* — a capability read, no session started,
        // off the main thread, one `multicam_depth` record. See `MultiCamDepthProbe`.
        logMultiCamDepthProbe()
    }

    // MARK: Launch health (an optional feature may never stop the app from starting)

    /// Arm the marker's removal: this launch counts as healthy once it has been alive for
    /// `LaunchRecovery.healthySeconds`, or the moment the walker deliberately sends the app to the
    /// background (locking the phone or switching away is something only a *running* app can have
    /// done, so it is proof the launch worked and it stops a quick, legitimate exit from being read
    /// as a crash).
    ///
    /// ⚠ Deliberately a `UIApplication` notification rather than a line in `scenePhaseChanged`:
    /// launch health has nothing to do with pausing engines, and keeping it here keeps the two
    /// concerns from growing into each other. Registered with `queue: .main`, so
    /// `MainActor.assumeIsolated` is sound (AGENTS.md hard rule 1), exactly like
    /// `observeThermalAndBattery`. Caller: `start()`.
    private func observeLaunchHealth() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Settings.markLaunchHealthy() }
        }
        Task {
            try? await Task.sleep(for: .seconds(LaunchRecovery.healthySeconds))
            Settings.markLaunchHealthy()
        }
    }

    /// Say, once, that the previous launch died and what this one turned off to come up.
    ///
    /// The walker cannot see that a switch moved, and an app that silently drops features is worse
    /// than one that admits it: `.nav` priority so it never steps on an obstacle warning, with a
    /// ttl so it is dropped rather than spoken late if the walker is already moving.
    /// Caller: `start()`, after "OpenCane ready."
    private func announceLaunchRecovery() {
        guard let line = LaunchRecovery.spokenLine(for: Settings.launchMode) else { return }
        logger.event("launch_recovery", ["cleared": LaunchRecovery.optionalFeatureKeys,
                                         "healthy_seconds": LaunchRecovery.healthySeconds])
        speech.say(line, .nav, ttl: 20)
    }

    // MARK: Sensor self-tests (debug controls — never automatic)

    /// Whether the Hazards card shows the sensor self-test buttons.
    ///
    /// ⚠ These self-tests used to run **automatically** at the end of `start()` whenever their
    /// launch flag was present, and the two-camera one pauses ARKit for 12 s. A tester who pressed
    /// "Where am I" inside that window got "Camera warming up. Try again." and reasonably concluded
    /// the app was broken: a launch flag is set once and then forgotten, while the app is launched
    /// again and again. Nothing may stop the safety channel without the walker asking for it *at
    /// that moment*, so the flag now only makes two **buttons** appear and a human has to press
    /// one. `false` on every normal launch, which is every launch of the demo build.
    static let selfTestControlsVisible: Bool =
        ProcessInfo.processInfo.environment["CANEKIT_SENSOR_SELFTEST"] == "1"
            || CommandLine.arguments.contains("--sensor-selftest")

    /// True while a sensor self-test is running, so the buttons disable themselves and the card can
    /// say what is happening. Never persisted.
    private(set) var selfTestRunning = false

    /// What the running (or last) self-test is doing, for the Hazards card's debug row. Empty
    /// before the first one.
    private(set) var selfTestStatus = ""

    /// Debug control: turn the front camera's face tracking on **without** touching the persisted
    /// setting, and after 15 s log what it actually delivered — face anchors ingested, whether a
    /// head pose is fresh, the yaw, and the depth rate and thermal state beside it. Restores the
    /// walker's own setting when it finishes.
    ///
    /// Why it exists: the *cost* of `userFaceTrackingEnabled` was measured by `SensorProbe`
    /// (60.0 fps with and without, thermal nominal), but whether the anchor → yaw plumbing in this
    /// app delivers needs a face in front of the phone, which no automated run can provide. This
    /// makes that a 20-second check with a log line instead of a guess: press the button, hold the
    /// phone facing you, pull the trip log and read `face_head_selftest`.
    /// It does **not** pause ARKit, so obstacle detection keeps running throughout.
    /// Caller: the Hazards card's "Front camera self test" button (visible only under
    /// `selfTestControlsVisible`).
    func startFaceTrackingSelfTest() {
        guard !selfTestRunning else { return }
<<<<<<< HEAD
        // It re-runs the AR session twice (on now, restore at 15 s); never start it on a route, and
        // a route begun during the 15 s defers the restore until it ends (below).
        switch FaceTrackingChange.decide(navigating: nav.isNavigating, routeStartWaiting: routeStartWaiting) {
        case .apply: break
        case .refusedRoute: selfTestStatus = "Not while a route is guiding you"; return
        case .refusedRouteStart: selfTestStatus = "Not while a route is starting"; return
=======
        guard !nav.isNavigating, !routeStartWaiting, sensorModeInterlock.phase == .idle else {
            selfTestStatus = sensorModeInterlock.phase == .finishing
                ? "Waiting for the camera transition to finish"
                : "Not while a route is starting or guiding you"
            return
>>>>>>> 21b1717 (Step 29: interlock AR sensor mode restarts during routes)
        }
        selfTestRunning = true
        selfTestStatus = "Front camera self test: 15 seconds, hold the phone facing you"
        let restore = faceHeadTrackingEnabled
        depth.setFaceTracking(true)
        faceHead.start()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self else { return }
            self.logger.event("face_head_selftest", [
                "supported": DepthEngine.supportsFrontCameraWithLiDAR,
                "requested": self.depth.faceTrackingEnabled,
                "anchor_seen": self.depth.faceAnchorSeen,
                "samples": self.faceHead.samples,
                "tracking": self.faceHead.isTracking,
                "yaw_deg": self.faceHead.yawDeg ?? -999,
                "readout": self.faceHead.readout,
                "depth_fps": Self.round1(self.depth.fps),
                "depth_running": self.depth.isRunning,
                "thermal": self.thermalName,
            ])
            // Put the walker's own setting back: a debug button must not leave the front camera on.
            // The restore re-runs the AR session, so a route started during the test defers it
            // until guidance ends, whichever way it ends (Stop, arrival) — polled, debug-only.
            // Logged once, not every second (a 15-minute route would write ~900 lines — Muse,
            // Step 34 final review); stops waiting if the task is cancelled.
            var deferred = false
            while FaceTrackingChange.decide(navigating: self.nav.isNavigating,
                                            routeStartWaiting: self.routeStartWaiting) != .apply,
                  !Task.isCancelled {
                if !deferred {
                    deferred = true
                    self.selfTestStatus = "Front camera self test: restore waits for the route to end"
                    self.logger.event("face_head_selftest", ["action": "restore_deferred_route"])
                }
                try? await Task.sleep(for: .seconds(1))
            }
            self.depth.setFaceTracking(restore)
            if !restore { self.faceHead.stop() }
            self.selfTestStatus = "Front camera self test finished: \(self.faceHead.readout)"
            self.selfTestRunning = false
        }
    }

    /// One `multicam_depth` record: could a future CaneKit show both cameras and *keep* a depth
    /// stream (AVFoundation) instead of pausing ARKit as this build does? Pure capability reading —
    /// no session, no camera, no permission — so it runs detached and never delays the launch.
    /// The verdict itself is `MultiCamDepth` in CaneKitLogic, with tests (`MultiCamDepthTests`).
    /// Caller: the last line of `start()`. The detached task hops back to the main actor only to log.
    private func logMultiCamDepthProbe() {
        Task.detached(priority: .utility) { [weak self] in
            let result = MultiCamDepthProbe.measure()
            await MainActor.run { self?.logger.event("multicam_depth", result.logFields) }
        }
    }

    /// Foreground/background transitions. ARKit pauses itself in the background; we pause the
    /// engine explicitly so the gyro stops too, and resume without resetting tracking. Core
    /// Haptics stops its engine on suspend, so it is restarted on `.active`.
    /// Called by `CaneKitApp`'s `.onChange(of: scenePhase)`; no-op until `start()` has run.
    /// `.active`: haptics, beacon engine and (if on) the microphone watch come back, ARKit-backed
    /// work resumes via `resumeARKitAfterCameraWork()`, GPS restarts. `.background`: the mid-route
    /// "Screen locked" line (once per route), hazard scanner off, GPS off unless a route runs,
    /// both-cameras torn down in place, microphone and face tracking off, scene context cleared,
    /// depth paused, cue state machines reset and the trip log flushed so nothing is lost if the
    /// process is suspended. `.inactive` does nothing (a notification pull-down must not pause).
    func scenePhaseChanged(_ phase: ScenePhase) {
        guard started else { return }
        switch phase {
        case .active:
            haptics.resume()
            beacon.resumeIfNeeded()          // the engine can die across a screen lock (Muse M4)
            if dangerSoundsEnabled { sounds.start() }
            // ⚠ Everything ARKit-backed — depth, the hazard scanner, the face anchor — resumes in
            // `resumeARKitAfterCameraWork()`, **not** here. Going to the background enqueues the
            // two-camera teardown on the serialised chain (`serializeBothCameras`, below), and a
            // lock followed by a quick unlock used to call `depth.resume()` while
            // `AVCaptureMultiCamSession` was still running: both pipelines then fought for the same
            // cameras and ARKit lost, exactly as the branch's own probe measured
            // (`probe_c_multicam`: ~30 fps per 4 s window collapsing to 8, with interruptions).
            // Lanes that look alive and are two seconds stale are the worst thing this app can do.
            resumeARKitAfterCameraWork()
            // Put GPS back if the background branch stopped it, so the card never reads "Off" on a
            // screen somebody is looking at. Idempotent when it is already running.
            location.start()
        case .inactive:
            break
        case .background:
            // Mid-route lock: ARKit pauses, so obstacle warnings stop while GPS guidance and the
            // beacon go on. Say so instead of letting confident guidance hide a dead safety
            // channel (Muse final review).
            // Once per route, and not over the current instruction's priority (Muse + Antigravity:
            // a pocket check spoke it at .safety every time and replayed the turn line after).
            if nav.isNavigating, !lockWarningGiven {
                lockWarningGiven = true
                depthSafetyDegraded = true
                speech.say("Screen locked. Obstacle warnings are paused until you unlock.", .nav, ttl: 10)
            }
            hazards.stop()                   // no scanning a frozen last frame in the background
            // GPS runs for the life of the FOREGROUND session. Backgrounded with no route running
            // there is nobody to guide, so holding the receiver on would just drain the battery in
            // a pocket. A running route keeps it: the walk continues with the screen locked, which
            // is the normal way this app is used.
            if !nav.isNavigating { location.stop() }
            // The two-camera spotter view must never survive a backgrounding: it would hold both
            // cameras with nothing on screen, and the walker would come back to an app whose
            // obstacle channel is silently off.
            // ⚠ Deliberately *not* `bothCamerasEnabled = false` here. That path resumes ARKit, and
            // it does so inside a `Task` that would run **after** the `depth.pause()` below — the
            // app would go to sleep with the AR session running. The switch is reset in place and
            // only the capture session is released; `.active` above resumes depth, the haptics and
            // the hazard scanner in the normal way.
            if bothCamerasEnabled {
                applyingBothCameras = true
                bothCamerasEnabled = false
                applyingBothCameras = false
                serializeBothCameras { [weak self] in await self?.bothCameras.stop() }
                logger.event("both_cameras", ["action": "off_background"])
            }
            // Give the microphone back and put the session on `.playback`: a suspended app must
            // not hold `.playAndRecord` (and the orange recording dot) while nothing listens.
            sounds.stop()
            faceHead.stop()                  // ARKit pauses: no face anchors, so no head pose
            sceneContext.set("")             // LiDAR facts from here are stale once we come back
            depth.pause()
            haptics.stopAll()
            decider.reset()
            cueSpeech.cleared()              // a new foreground is a new episode: speak the first head cue
            namer.reset()
            activeCue = .clear
            logger.flush()
            // Same reason as the disk flush: a backgrounded walk must still land. The queue keeps
            // its rows if the POST does not finish before the app is suspended.
            cloud.flushNow()
        @unknown default:
            break
        }
    }

    /// Bring the ARKit-backed safety path back on `.active`, **after** any two-camera work that is
    /// still in flight has finished.
    ///
    /// The teardown enqueued by `.background` runs on the serialised chain, so it can still be
    /// running when the walker unlocks a second later. Resuming ARKit then puts the AR session and
    /// a live `AVCaptureMultiCamSession` on the same cameras, and ARKit is the one that starves
    /// (measured: 30 fps → 8). So the resume waits for the chain — *without* blocking the main
    /// actor, and without waiting at all in the normal case: `bothCamerasWork` is nil unless
    /// two-camera work is genuinely outstanding (`serializeBothCameras` clears it when the last
    /// queued piece finishes), so an ordinary lock/unlock with the mode off resumes synchronously,
    /// in the same turn of the run loop as before. Nothing here can delay a warning that the
    /// system could otherwise have given: while the capture session holds the cameras there is no
    /// depth to warn from.
    /// Caller: `scenePhaseChanged(.active)`.
    private func resumeARKitAfterCameraWork() {
        guard let work = bothCamerasWork else {
            resumeARKitPipelines()
            return
        }
        Task { @MainActor [weak self] in
            await work.value
            self?.resumeARKitPipelines()
        }
    }

    /// The three engines that need ARKit frames, in the order the two-camera off path uses.
    /// `resume()` keeps the world map and does not reset tracking; the hazard scanner and the face
    /// anchor have nothing to read until it has. Idempotent: each engine ignores a second start.
    ///
    /// ⚠ Refuses while the two-camera session is still running, and that is the whole point. A
    /// scene phase can go `.inactive` → `.active` with no `.background` in between (a notification
    /// pulled down and dismissed, a control-centre peek), and there is then no queued camera work
    /// for `resumeARKitAfterCameraWork()` to wait on — but the mode may still be switched on, with
    /// `AVCaptureMultiCamSession` holding both cameras on purpose. `DepthEngine.resume()` only
    /// guards on `!isRunning`, so it would happily restart the AR session on top of the capture
    /// session: ARKit starved to 8 fps (`probe_c_multicam`), lanes that look alive and are two
    /// seconds stale, and a walker trusting them. Staying paused is not a lost safety channel here
    /// — the walker switched it off themselves and was told so out loud — and it comes back the
    /// moment the switch goes off (`setBothCameras(false)`) or the app is backgrounded (the
    /// teardown is queued, and the next `.active` waits for it and then lands here again).
    /// Logs `both_cameras {action: arkit_resume_skipped_session_running}` when it refuses.
    /// Caller: `resumeARKitAfterCameraWork` only (the two-camera off path resumes inline).
    private func resumeARKitPipelines() {
        guard !bothCameras.isRunning else {
            logger.event("both_cameras", ["action": "arkit_resume_skipped_session_running"])
            return
        }
        depth.resume()
        hazards.start()
        if faceHeadTrackingEnabled { faceHead.start() }
    }

    // MARK: Report routing (the "cue router")

    /// Every depth report lands here (~30 Hz normal / up to 60 Hz high-rate): decide → render on the phone (step 3);
    /// step 4 adds the ObstacleNamer, step 5 the watch mirror.
    /// In order: cue decision (haptics, wrist mirror, cue speech, `cue` log) → obstacle name if
    /// `obstacleNamesEnabled` and `cueRules.allowsName` (spoken with load class
    /// `.ambientObstacleName`, so `SpeechLoadPolicy` may suppress it; logged `speech` only when it
    /// was accepted) → ground hazard if enabled and `groundPolicy` agrees → `sceneContext` line →
    /// front-camera head pose aged on the AR clock → `logger.lanes` (throttled to 2 Hz there).
    /// Installed as `depth.onReport` in `start()`; always on the main actor.
    /// `now` is always `report.timestamp` (ARKit clock, seconds) — never wall time: the decider's
    /// repeat / 400 ms change intervals and `CueSpeechPolicy`'s intervals are in that clock.
    /// ⚠ Do not change the decider/`now` contract without re-running `CueDeciderTests`
    /// (`cueChangeNeeds400ms`, `hysteresisHoldsUntilPlusFifteenCentimetres`,
    /// `centerApproachFiresThenUpdatesDistance`).
    private func handle(_ report: LaneReport) {
        // A session interruption/failure can leave GPS guidance alive while depth has stopped.
        // Clear any latched obstacle cue immediately; recovery is announced only when this same
        // frame proves normal tracking, valid depth and the sweep trust bit.
        if depthSafetyDegraded,
           depth.isRunning,
           depth.status != "AR interrupted",
           report.trackingNormal,
           report.depthAvailable,
           report.isTrusted {
            depthSafetyDegraded = false
            if routeError == "Obstacle detection unavailable" { routeError = nil }
            speech.say("Obstacle detection is back.", .nav, ttl: 8)
            watch.send(status: nav.instruction, distanceM: nav.distanceToNext ?? -1)
            logger.event("depth_health", ["state": "recovered", "tracking": report.trackingNormal])
        }
        guard !depthSafetyDegraded else {
            // Do not let a partial/interrupted frame feed the decider, mesh namer or ground
            // hazard path while the safety channel is known degraded. Keep the trip log honest.
            sceneContext.set("")
            faceHead.refresh(now: report.timestamp)
            logger.lanes(report, cue: activeCue, thermal: thermalName, battery: batteryPercent, fps: depth.fps)
            return
        }
        if let output = decider.update(report, now: report.timestamp) {
            switch output {
            case .fire(let cue):
                activeCue = cue.kind
                haptics.play(cue)
                // Wrist mirror: whenever the phone cannot buzz (engine down *or* silenced), or
                // the user asked for both.
                let phoneCannotBuzz = !haptics.isHealthy || haptics.silenced
                if phoneCannotBuzz || fallbackToWatch {
                    watch.send(obstacle: cue.kind, now: report.timestamp)
                }
                speakCueIfNeeded(cue, phoneCannotBuzz: phoneCannotBuzz, now: report.timestamp)
                // Field "cue", not "kind": "kind" is the record type (TripLogRecord reserves it).
                var fields: [String: Any] = ["cue": cue.kind.rawValue, "ar_t": report.timestamp]
                if case .centerApproach(let d) = cue { fields["distance"] = Double(d) }
                logger.event("cue", fields)
            case .updateCenter(let d):
                // Continuous approach ramp: haptics only (no watch, no speech).
                activeCue = .center
                haptics.setApproach(distance: d)
            case .stop:
                activeCue = .clear
                haptics.stopAll()
                cueSpeech.cleared()              // the next head cue is a new episode
                logger.event("cue", ["cue": "clear"])
            }
        }
        let rules = cueRules
        let navigating = nav.isNavigating
        if obstacleNamesEnabled,
           let line = namer.update(report, now: report.timestamp,
                                   allows: { rules.allowsName($0, navigating: navigating) }) {
            if speech.say(line, .obstacle, ttl: 4, load: .ambientObstacleName) {
                logger.event("speech", ["text": line, "priority": "obstacle"])
            }
            // Deliberately outside the `speech.say` result: the family event reports the
            // DETECTION, not the utterance. Step 29-33's load policy can drop the spoken line
            // when the soundscape is busy, and a close obstacle still matters to family then.
            // The policy drops it unless it is close (≤ obstacleMaxDistanceM) and not
            // rate-limited. `centerHit` is the centre ray, hence direction "center".
            family.obstacle(kind: report.centerHit?.classification.spokenName,
                            distanceM: report.centerHit.map { Double($0.distance) },
                            direction: "center",
                            lat: location.fix?.coordinate.latitude,
                            lng: location.fix?.coordinate.longitude,
                            note: line, now: report.timestamp)
        }
        if groundHazardsEnabled, let g = report.groundHazard,
           groundPolicy.shouldAnnounce(g, now: report.timestamp) {
            groundHazardFound(g, now: report.timestamp)
        }
        sceneContext.set(Self.contextLine(report))
        // Age the front-camera head pose on the AR clock: face anchors stop arriving the moment
        // the walker looks away, and the card and the beacon must both see nil, not a stale angle.
        faceHead.refresh(now: report.timestamp)
        // Every report; the logger throttles `lanes` records to `laneRate` (2 Hz).
        logger.lanes(report, cue: activeCue, thermal: thermalName, battery: batteryPercent, fps: depth.fps)
    }

    /// Fail-safe route behavior for an AR session failure or an active-camera interruption. GPS
    /// guidance is intentionally preserved, but stale obstacle haptics/names are cleared and the
    /// existing safety speech/watch channels identify the missing capability. Caller: `DepthEngine`
    /// session callbacks, always on the main actor.
    private func depthSessionFailed(_ reason: String, announce: Bool = true) {
        guard nav.isNavigating else { return }
        depthSafetyDegraded = true
        decider.reset()
        cueSpeech.cleared()
        namer.reset()
        haptics.stopAll()
        activeCue = .clear
        routeError = "Obstacle detection unavailable"
        if announce {
            let line = "Obstacle detection unavailable. Guidance continues. \(reason)."
            speech.say(line, .safety, ttl: 30)
            watch.send(status: "Obstacle detection unavailable", distanceM: -1)
        }
        logger.event("depth_health", ["state": "failed", "reason": reason])
    }

    /// Treat an active AR interruption as degraded until a trusted frame returns. Background
    /// transitions already speak their dedicated lock warning, so this callback stays quiet while
    /// the application is not active; the first trusted foreground frame still announces recovery.
    private func depthSessionInterrupted(_ interrupted: Bool) {
        guard nav.isNavigating else { return }
        if interrupted {
            // The scene-phase handler already speaks "Screen locked…" while suspended; retain
            // degraded state for recovery evidence but do not duplicate or clear that cue.
            depthSessionFailed("camera session interrupted",
                               announce: UIApplication.shared.applicationState == .active)
        }
    }

    /// Which obstacle cues are also spoken (CaneKitLogic.CueSpeechPolicy, unit-tested).
    /// Replaced with a fresh value at every `startRouteNow`; `cleared()` on the decider's `.stop`,
    /// on `.background` and when both cameras pause ARKit.
    @ObservationIgnored private var cueSpeech = CueSpeechPolicy()

    /// Voice channel for obstacle cues. "Head height." is spoken once per obstacle episode (plan:
    /// "the .head cue must never be suppressed" — an overhanging sign has no mesh class and the
    /// clamp may damp the tap), never re-spoken every few seconds under the same branch (that
    /// cut crossing lines to pieces). Left / right / ahead are spoken only when the phone cannot
    /// buzz; otherwise the Taptic pattern is the channel.
    /// Tier `.safety` maps to `SpeechPriority.safety` (top of the queue, AGENTS.md hard rule 8);
    /// everything else to `.obstacle`. `now` is the AR clock.
    /// ⚠ Do not add a further suppression path for `.head` without a device head-height test and
    /// re-running `NavSupportTests` (`headHeightIsSpokenOncePerEpisode`,
    /// `headEpisodesAreRateLimitedAcrossEpisodes`, `sideCuesAreSpokenOnlyWhenThePhoneCannotBuzz`).
    private func speakCueIfNeeded(_ cue: HapticCue, phoneCannotBuzz: Bool, now: TimeInterval) {
        guard let (text, tier) = cueSpeech.line(for: cue, phoneCannotBuzz: phoneCannotBuzz, now: now) else { return }
        let priority: SpeechPriority = tier == .safety ? .safety : .obstacle
        // 6 s: long enough to survive queuing behind a crossing line, short enough to stay current.
        speech.say(text, priority, ttl: 6)
        logger.event("speech", ["text": text, "priority": "\(priority)"])
    }

    // MARK: Hazards the maps do not know about (LiDAR ground, signs, hazard watch)

    /// Wires the camera hazard scanner (signs + hazard watch) and starts it. Called once from
    /// `start()` after the depth engine, because the scanner reads its camera frames.
    /// Installs `isNavigating`, `currentSpeed` (0 for a fix older than 5 s), `onDiagnostic`
    /// (scanner events such as `scan` straight into the trip log) and `onHazard` (speak at
    /// `.obstacle`, 8 s TTL for a sign / 6 s for a caution, then `recordHazard`). Honours the
    /// `CANEKIT_HAZARD_WATCH=1` e2e hook.
    private func wireHazards() {
        hazards.isNavigating = { [weak self] in self?.nav.isNavigating ?? false }
        // Speed of a fix older than 5 s is not current: CoreLocation stops sending fixes while
        // the walker stands still, so the last walking speed would keep the hazard watch asking
        // at a curb (Antigravity final review).
        hazards.currentSpeed = { [weak self] in
            guard let f = self?.location.fix, Date().timeIntervalSinceReferenceDate - f.timestamp < 5 else { return 0 }
            return f.speed
        }
        hazards.onDiagnostic = { [weak self] kind, fields in self?.logger.event(kind, fields) }
        // Simulator e2e hook (`CANEKIT_HAZARD_WATCH=1`): run the hazard watch without touching the
        // persisted setting, so the Street View mock exercises the whole camera path.
        if ProcessInfo.processInfo.environment["CANEKIT_HAZARD_WATCH"] == "1" { hazards.watchEnabled = true }
        hazards.onHazard = { [weak self] text, source, jpeg in
            // Signs and vision cautions: obstacle priority (below route lines, above scene).
            // A sign line may wait a little longer than a caution (read from up to ~7 m ahead), but
            // not so long that it plays after the walker has passed the sign: 8 s ≈ 10 m at walking
            // pace (Claude workflow wanted longer than 6 s; Muse + Antigravity: 20 s was too long).
            self?.speech.say(text, .obstacle, ttl: source == .sign ? 8 : 6)
            let sev = (source == .sign) ? "info" : "warn"
            self?.recordHazard(
                kind: source.rawValue,
                text: text,
                source: source,
                jpeg: jpeg,
                direction: "center",
                whatItSaw: text,
                severity: sev
            )
        }
        hazards.start()
    }

    // MARK: Both cameras (front + back at once)

    /// Turn the two-camera spotter view on or off, and pay for it honestly.
    ///
    /// This is the only place in the app where the obstacle channel is switched off on purpose, so
    /// everything about the trade lives here:
    ///   1. **Never during a route.** A walking blind user does not lose obstacle warnings for a
    ///      picture. The switch snaps back and the app says why.
    ///   2. **Never silently.** Turning it on speaks "Both cameras on. Obstacle detection,
    ///      distance warnings and sign reading are paused." at `.nav`; turning it off speaks
    ///      "Both cameras off. Obstacle detection is restarting." and, 2 s later, "Obstacle
    ///      detection is back." only if depth is really delivering — otherwise "Obstacle detection
    ///      did not restart. Close and reopen OpenCane." at `.safety`. A refusal (route guiding or
    ///      starting, unsupported phone) snaps the switch back, sets `routeError` and says why.
    ///      A silent loss of the safety channel is
    ///      unacceptable in this app (AGENTS.md rule 6, "safety beats features").
    ///   3. **ARKit is paused, not starved.** Measured (`probe_c_multicam`): with a multi-cam
    ///      session running, ARKit fell from ~30 frames per 4 s window to 8. Lanes that look alive
    ///      and are two seconds stale are worse than lanes that are openly off, so `depth.pause()`
    ///      comes first and the haptics and cue state machines are reset with it.
    ///   4. **Restored on the way out** at route start (`beginRoute`, which calls this with
    ///      `false`). Backgrounding takes a different path on purpose — see `scenePhaseChanged`,
    ///      which must not resume ARKit on the way to being suspended.
    ///
    /// Everything is logged as `both_cameras` with the session's `hardwareCost`, so a trip log
    /// proves whether both cameras really ran and whether depth came back afterwards (`action`:
    /// `refused_route`, `refused_route_start`, `unsupported`, `start`, `start_failed_recovered`,
    /// `stop`, `depth_after`; plus `off_background`, `off_for_route`, `selftest_*` and
    /// `arkit_resume_skipped_session_running` from the other callers).
    /// - Parameter on: the switch's new value.
    /// Caller: only `bothCamerasEnabled`'s `didSet` (under `applyingBothCameras`); `beginRoute`
    /// and the self-test reach it by writing the property.
    private func setBothCameras(_ on: Bool) {
        if on, nav.isNavigating || routeStartWaiting || sensorModeInterlock.phase == .finishing {
            // `applyingBothCameras` is set by the `didSet` that called us, so this write only puts
            // the switch back on screen — it does not run the off path.
            bothCamerasEnabled = false
            if nav.isNavigating {
                routeError = "Stop the route before using both cameras"
                speech.say("Both cameras cannot run while a route is guiding you. Stop the route first.", .nav, ttl: 10)
                logger.event("both_cameras", ["action": "refused_route"])
            } else if sensorModeInterlock.phase == .finishing {
                routeError = "Wait for the camera transition to finish"
                speech.say("Wait for the camera transition to finish.", .nav, ttl: 10)
                logger.event("both_cameras", ["action": "refused_sensor_finish"])
            } else {
                routeError = "Wait for obstacle detection before using both cameras"
                speech.say("Both cameras cannot run while a route is starting. Wait for obstacle detection to be ready.", .nav, ttl: 10)
                logger.event("both_cameras", ["action": "refused_route_start"])
            }
            return
        }
        if on {
            guard DualCameraSession.isSupported else {
                bothCamerasEnabled = false
                routeError = "This phone cannot show two cameras at once"
                speech.say("This phone cannot show two cameras at once.", .nav, ttl: 10)
                logger.event("both_cameras", ["action": "unsupported"])
                return
            }
            // Say it before the cameras change hands, so the warning is never queued behind the
            // ~1 s of session set-up.
            speech.say("Both cameras on. Obstacle detection, distance warnings and sign reading are paused.",
                       .nav, ttl: 15)
            let fpsBefore = depth.fps
            // Every one of these goes INSIDE the serialised chain, with the resume on the off path.
            // They used to run synchronously here while the resume ran inside the chain, so ON →
            // OFF → ON pressed quickly ordered as: pause (sync), [stop + resume] (queued), pause
            // (sync), [start] (queued) — and the capture session started while ARKit was running
            // again. The device probe measured what that costs: ARKit collapses from 30 fps to 8
            // with session interruptions, i.e. obstacle detection degrades exactly when someone is
            // fiddling with the switch.
            serializeBothCameras { [weak self] in
                guard let self else { return }
                self.hazards.stop()             // no sign / hazard scanning without ARKit frames
                self.depth.pause()              // the AR session must let the cameras go
                self.haptics.stopAll()
                self.decider.reset()
                self.cueSpeech.cleared()
                self.namer.reset()
                self.activeCue = .clear
                self.sceneContext.set("")
                self.faceHead.stop()            // no ARKit frames means no face anchors
                await self.bothCameras.start()
                var fields = self.bothCameras.diagnostics
                fields["action"] = "start"
                fields["thermal"] = self.thermalName
                fields["depth_fps_before"] = Self.round1(fpsBefore)
                self.logger.event("both_cameras", fields)
                // A failed start had already paused depth, stopped the hazard scanner and killed
                // the haptic engine — and then only spoke the error, leaving the switch ON and the
                // walker with NO obstacle detection at all. Losing the picture is a disappointment;
                // losing the safety path silently is the worst outcome this app has. If the session
                // is not actually delivering, put everything back and say so.
                let running = self.bothCameras.isRunning
                    && (self.bothCameras.backConnected || self.bothCameras.frontConnected)
                if !running {
                    await self.bothCameras.stop()
                    self.depth.resume()
                    self.haptics.resume()
                    self.hazards.start()
                    if self.faceHeadTrackingEnabled { self.faceHead.start() }
                    self.applyingBothCameras = true
                    self.bothCamerasEnabled = false
                    self.applyingBothCameras = false
                    let why = self.bothCameras.lastError ?? "The cameras did not start."
                    self.routeError = why
                    self.speech.say("\(why) Obstacle detection is back on.", .nav, ttl: 12)
                    self.logger.event("both_cameras", ["action": "start_failed_recovered",
                                                       "why": why])
                } else if let error = self.bothCameras.lastError {
                    self.speech.say(error, .nav, ttl: 10)
                }
            }
        } else {
            let thermal = thermalName
            let cost = Double((bothCameras.hardwareCost * 100).rounded() / 100)
            serializeBothCameras { [weak self] in
                guard let self else { return }
                await self.bothCameras.stop()
                // ARKit comes back exactly as it was: `resume()` keeps the world map and does not
                // reset tracking, and the hazard scanner restarts with it.
                self.depth.resume()
                self.haptics.resume()
                self.hazards.start()
                if self.faceHeadTrackingEnabled { self.faceHead.start() }
                // "Restarting", not "back": resume() has been called but ARKit needs a second or
                // two to deliver frames again, and a walker who hears "back" steps off immediately.
                // The confirmation below is what says "back", and only if it is true.
                self.speech.say("Both cameras off. Obstacle detection is restarting.", .nav, ttl: 10)
                self.logger.event("both_cameras", ["action": "stop", "thermal": thermal,
                                                   "hardware_cost": cost])
                // Two seconds later, log the depth rate again: this is the evidence that the
                // safety path really restarted, not just that `resume()` was called. Outside the
                // serialised chain on purpose — a walker who flips the switch straight back on
                // must not wait 2 s for it.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self else { return }
                    let back = self.depth.isRunning && self.depth.fps > 0
                    self.logger.event("both_cameras", ["action": "depth_after",
                                                       "depth_fps": Self.round1(self.depth.fps),
                                                       "depth_running": self.depth.isRunning,
                                                       "status": self.depth.status,
                                                       "confirmed": back,
                                                       "thermal": self.thermalName])
                    // Say it only once it is true — and if it is NOT true, that silence would be
                    // the most dangerous moment in the app, so it becomes the loudest line instead.
                    if back {
                        self.speech.say("Obstacle detection is back.", .nav, ttl: 8)
                    } else {
                        self.speech.say("Obstacle detection did not restart. Close and reopen OpenCane.",
                                        .safety, ttl: 30)
                    }
                }
            }
        }
    }

    /// The chain of outstanding start/stop work for the two-camera session, or nil when nothing
    /// is in flight. `resumeARKitAfterCameraWork()` (on `.active`) reads it to decide whether
    /// resuming ARKit has to wait, and `queueRouteStart` waits on it before arming the readiness
    /// gate, so it **must** go back to nil when the chain drains — see `serializeBothCameras`.
    @ObservationIgnored private var bothCamerasWork: Task<Void, Never>?

    /// Bumped once per `serializeBothCameras` call, so the task that finishes can tell whether it
    /// was the last one queued (and may therefore clear `bothCamerasWork`) or whether newer work
    /// is already chained behind it.
    @ObservationIgnored private var bothCamerasGeneration = 0

    /// Run one piece of two-camera work **after** whatever is already in flight.
    ///
    /// `AVCaptureSession.startRunning()` takes about a second, so a walker who taps the switch
    /// twice would otherwise have a `start()` and a `stop()` racing: the stop could finish first and
    /// leave both cameras held with ARKit paused — the exact state this feature must never be left
    /// in. Chaining makes the last tap win, always.
    /// - Parameter body: main-actor work that starts or stops the session.
    /// Callers: `setBothCameras` (on and off paths), `scenePhaseChanged(.background)` (teardown
    /// only). Readers of the chain: `resumeARKitAfterCameraWork`, `queueRouteStart`.
    private func serializeBothCameras(_ body: @escaping @MainActor () async -> Void) {
        let previous = bothCamerasWork
        bothCamerasGeneration &+= 1
        let generation = bothCamerasGeneration
        bothCamerasWork = Task { @MainActor [weak self] in
            await previous?.value
            await body()
            // Clear the handle only if nothing newer was queued behind us. Without this the handle
            // stays non-nil for the life of the app after the first use, and every later unlock
            // would take `scenePhaseChanged`'s "wait for the camera work" path and resume ARKit one
            // run-loop hop late for no reason. With it, "camera work is in flight" is a fact rather
            // than a memory.
            guard let self, self.bothCamerasGeneration == generation else { return }
            self.bothCamerasWork = nil
        }
    }

    /// One decimal place, for fps fields in the trip log. A non-finite value becomes -1 (the
    /// `TripLogger.num` convention): `JSONSerialization` rejects NaN / ∞ and `TripLogger` would
    /// silently drop the whole record.
    private static func round1(_ v: Double) -> Double { v.isFinite ? (v * 10).rounded() / 10 : -1 }

    /// Debug control: switch the two-camera mode on for 12 s and off again, so the thermal /
    /// hardware cost **and** the proof that depth comes back land in the trip log from a single
    /// button press.
    ///
    /// ⚠ This is **not** started by `start()` any more, and must never be again. Run automatically
    /// at launch it paused ARKit for ~13 s before the walker had done anything, and a tester who
    /// pressed "Where am I" in that window heard "Camera warming up. Try again." and thought the
    /// app was dead. It pauses the safety channel, so a human asks for it, at a moment they choose,
    /// and only when `selfTestControlsVisible`.
    /// Caller: the Hazards card's "Both cameras self test" button.
    func startBothCamerasSelfTest() {
        guard !selfTestRunning else { return }
        guard !nav.isNavigating else {
            selfTestStatus = "Not while a route is guiding you"
            return
        }
        guard !routeStartWaiting, sensorModeInterlock.phase == .idle else {
            selfTestStatus = sensorModeInterlock.phase == .finishing
                ? "Waiting for the camera transition to finish"
                : "Not while obstacle detection is warming up"
            return
        }
        selfTestRunning = true
        selfTestStatus = "Both cameras self test: 12 seconds without obstacle detection"
        Task { [weak self] in
            guard let self else { return }
            self.logger.event("both_cameras", ["action": "selftest_before",
                                               "depth_fps": Self.round1(self.depth.fps),
                                               "thermal": self.thermalName])
            self.bothCamerasEnabled = true
            try? await Task.sleep(for: .seconds(12))
            self.logger.event("both_cameras", ["action": "selftest_during",
                                               "depth_fps": Self.round1(self.depth.fps),
                                               "depth_running": self.depth.isRunning,
                                               "thermal": self.thermalName,
                                               "front": self.bothCameras.frontConnected,
                                               "back": self.bothCameras.backConnected,
                                               "front_frames": self.bothCameras.diagnostics["front_frames"] ?? 0,
                                               "back_frames": self.bothCameras.diagnostics["back_frames"] ?? 0,
                                               "running": self.bothCameras.isRunning,
                                               "hardware_cost": Double((self.bothCameras.hardwareCost * 100).rounded() / 100)])
            self.bothCamerasEnabled = false
            self.selfTestStatus = "Both cameras self test finished; see the trip log"
            self.selfTestRunning = false
        }
    }

    // MARK: Danger sounds (microphone)

    /// Wires the microphone watch: what it says and what it logs. Called once from `start()`,
    /// before the setting is read, so nothing can fire unwired.
    ///
    /// The band a sound alert is spoken in comes from `DangerSound.urgency` and its TTL from
    /// `DangerSound.speechTTL` (both CaneKitLogic, both tested), so every number stays out of this
    /// file and this method is a mapping (AGENTS.md hard rule 3):
    ///   · `.emergency` — an emergency-vehicle siren — → `.nav`, the band route and crossing lines
    ///     use. What a siren tells a blind pedestrian *is* a crossing fact: it masks the traffic
    ///     sound they judge a crossable gap from, and the vehicle may cross against the signal.
    ///   · `.ambient` — horn, vehicle — → `.obstacle`, exactly as before.
    /// It is deliberately **not** `.safety`. Equal priorities queue FIFO in `SpeechQueue`, so a
    /// siren line in that band would *delay* "Head height." or a LiDAR drop-off by its own length;
    /// keeping it out is what protects the never-suppressed rule rather than weakening it. The
    /// full argument, with the accessibility research behind it, is in `SoundWatcher`'s file header
    /// and in SoundAlerts.swift. `.safety` still pre-empts `.nav` instantly and the haptic cue
    /// channel is untouched, so nothing here can delay an obstacle or head-height warning; the only
    /// line a siren can interrupt is an obstacle *name*, which is what every route line already
    /// does and which resumes afterwards.
    /// There is no haptic for sound alerts on purpose: the cane's taps mean "something is in your
    /// path", and borrowing them for something heard would make the safety channel ambiguous.
    ///
    /// It also wires `onFailure`, which is the *other* thing this feature can say. That line stays
    /// in the `.obstacle` band whatever the alerts do: a microphone that stopped working is never
    /// more urgent than an obstacle in the path or a crossing instruction. The watcher hands over a
    /// short hand-written sentence for speech and keeps the technical detail (`NSError`
    /// descriptions, audio port names) for `lastError` and the trip log.
    private func wireSounds() {
        sounds.onDiagnostic = { [weak self] kind, fields in self?.logger.event(kind, fields) }
        sounds.onAlert = { [weak self] sound in
            let priority: SpeechPriority = sound.urgency == .emergency ? .nav : .obstacle
            self?.speech.say(sound.spokenLine, priority, ttl: sound.speechTTL)
            self?.logger.event("speech", ["text": sound.spokenLine,
                                          "priority": sound.urgency == .emergency ? "nav" : "obstacle"])
        }
        // A failed start used to leave this switch ON: the watcher gave up, but every
        // foregrounding and every `start()` retried it, failed again, announced again and moved
        // the audio session again — with the UI showing a feature that does not exist. The switch
        // has to follow the watcher, and the reason has to be said once, here, not once per retry.
        sounds.onFailure = { [weak self] message in
            guard let self else { return }
            // Same guard as `setBothCameras`: this write is the switch moving on screen, not the
            // walker turning the feature off, so it must not run the off path again.
            self.applyingDangerSounds = true
            self.dangerSoundsEnabled = false
            self.applyingDangerSounds = false
            // `.obstacle`, not `.nav`: this is the sound feature's own band (docs/design.md §5),
            // so an explanation of why a *microphone* stopped can never cut an obstacle name or a
            // route instruction. It queues behind them and still arrives within its 10 s TTL.
            self.speech.say(message, .obstacle, ttl: 10)
            self.logger.event("sound_watch", ["action": "disabled_after_failure", "why": message])
        }
    }

    /// A confirmed LiDAR ground hazard worth saying: cane buzz (4 heavy taps), the wrist when the
    /// phone cannot buzz, a spoken line at safety priority (a drop-off is as urgent as head
    /// height), and a hazard-map entry with the frame.
    /// - Parameters:
    ///   - g: the hazard `groundPolicy` just approved (from `report.groundHazard`).
    ///   - now: the report's AR-clock timestamp (the watch mirror's rate limit uses it).
    /// TTL 3 s: a drop-off line that waited longer describes a place already reached. The JPEG
    /// (768 px) is encoded off the main actor in `frame(_:maxDimension:)` before `recordHazard`.
    /// Caller: `handle(_:)`.
    private func groundHazardFound(_ g: GroundHazard, now: TimeInterval) {
        lastGroundHazard = g.spokenLine
        haptics.playGroundHazard()
        if !haptics.isHealthy || haptics.silenced || fallbackToWatch {
            watch.send(obstacle: .center, now: now)
        }
        speech.say(g.spokenLine, .safety, ttl: 3)
        let processor = depth.processor
        let dist = Double(g.distance)
        let delta = Double(g.delta)
        let kind = g.kind.rawValue
        let text = g.spokenLine
        let what = "\(g.kind.shortNoun) (delta \(String(format: "%.2f", g.delta)) m)"
        let sev = (g.kind == .dropOff) ? "critical" : "warn"
        Task { @MainActor [weak self] in
            let jpeg = await Self.frame(processor, maxDimension: 768)
            self?.recordHazard(
                kind: kind,
                text: text,
                source: .ground,
                jpeg: jpeg,
                distanceM: dist,
                heightM: delta,
                direction: "center",
                whatItSaw: what,
                severity: sev
            )
        }
    }

    /// Hazard map + trip log entry for any hazard source.
    /// Uses the navigation engine's last fix when location has stopped (after arrival), so a
    /// sign read at the CIF door still lands at the door, not at 0, 0 (review round 5) — but only
    /// if that fix is under 2 minutes old; an older one could be a different place entirely
    /// (Muse round 6). The same age gate applies to the live fix (GPS lost under a roof keeps a
    /// stale one; Muse + Antigravity round 7). No fresh fix gives a null geometry.
    /// - Parameters:
    ///   - kind: the ground hazard's kind raw value ("dropOff", …) or, for camera hazards, the
    ///     `HazardSource` raw value ("sign" / "vision"); written to GeoJSON and to the log as `type`.
    ///   - text: the line that was spoken.
    ///   - source: `.ground`, `.sign` or `.vision` (the hazard watch).
    ///   - jpeg: the frame the hazard was seen in, or nil when none could be encoded.
    /// Callers: `groundHazardFound`, `hazards.onHazard` (wired in `wireHazards`).
    private func recordHazard(kind: String, text: String, source: HazardSource, jpeg: Data?,
                             distanceM: Double? = nil, heightM: Double? = nil,
                             direction: String? = nil, whatItSaw: String? = nil,
                             severity: String? = nil) {
        let now = Date().timeIntervalSinceReferenceDate
        let fix = [location.fix, nav.lastFix].compactMap { $0 }.first { now - $0.timestamp < 120 }
        let headingDeg = location.heading
        let speedMps = (fix?.speed ?? -1) >= 0 ? fix?.speed : nil
        let routeName = activeRouteName ?? nav.route?.name
        let instruction = nav.isNavigating ? nav.instruction : nil

        hazardLog.record(
            kind: kind,
            text: text,
            fix: fix,
            jpeg: jpeg,
            distanceM: distanceM,
            heightM: heightM,
            direction: direction,
            headingDeg: headingDeg,
            speedMps: speedMps,
            routeName: routeName,
            instruction: instruction,
            source: source.rawValue,
            whatItSaw: whatItSaw,
            severity: severity
        )
        // Field "type", not "kind": a "kind" field used to replace the record's own kind
        // ("hazard" → "sign"), so e2e.py never saw a hazard record (phone trip log, 2026-09-11).
        var eventFields: [String: Any] = ["type": kind, "text": text, "source": source.rawValue]
        if let distanceM { eventFields["distance_m"] = distanceM }
        if let heightM { eventFields["height_m"] = heightM }
        if let direction { eventFields["direction"] = direction }
        if let severity { eventFields["severity"] = severity }
        logger.event("hazard", eventFields)
        // The same record the GeoJSON just got, plus the frame. `HazardLog` may have refused this
        // one as jitter (its 3 s debounce), in which case `records.last` is the older hazard and
        // re-sending it is harmless: the cloud row is an insert of what was announced, and the
        // debounced duplicate was never announced twice either.
        if let record = hazardLog.records.last {
            cloud.recordHazard(record, jpeg: jpeg)
        }
    }

    /// The LiDAR facts the on-device describer may use ("1.4 meters ahead, obstacle. Two
    /// meters ahead, hole."). Distance first, matching the spoken warning lines. Empty when
    /// nothing is within 3 m.
    /// "Ahead" is the centre lane only (torso + head, filtered): side lanes and the unfiltered
    /// centre window made it true almost always on a sidewalk, which left the LiDAR gate for
    /// on-device hazard labels permanently open (review round 5).
    /// Pure (no `self`), so `static`: `handle(_:)` writes it into `sceneContext` on every report,
    /// and a non-empty line is also the on-device hazard watch's "LiDAR sees something" gate.
    /// Thresholds: 3 m for "ahead", 1.5 m for head height (the outdoor head threshold).
    static func contextLine(_ r: LaneReport) -> String {
        guard r.depthAvailable else { return "" }
        var parts: [String] = []
        let centre = [r.torso, r.head].compactMap { $0.count == 3 ? $0[1] : nil }
        let ahead = centre.min() ?? .infinity
        if ahead.isFinite, ahead < 3 {
            parts.append("\(SpokenDistance.leadingCapitalized(SpokenDistance.phrase(ahead))) ahead, obstacle.")
        }
        if r.head.count == 3, r.head[1].isFinite, r.head[1] < 1.5 { parts.append("Something at head height.") }
        if let g = r.groundHazard { parts.append(g.spokenLine) }
        if let hit = r.centerHit, let name = hit.classification.spokenName {
            parts.append("The obstacle ahead looks like a \(name).")
        }
        return parts.joined(separator: " ")
    }

    /// JPEG encode off the main actor (the ground-hazard photo for the hazard map). `@concurrent`
    /// runs it on the global executor, so a 768 px encode never stalls the 30 Hz cue router.
    /// Returns nil when the processor holds no frame. Caller: `groundHazardFound`.
    @concurrent
    private static func frame(_ p: DepthFrameProcessor, maxDimension: CGFloat) async -> Data? {
        p.jpegSnapshot(maxDimension: maxDimension, quality: 0.6)
    }

    /// Camera refused → the whole obstacle channel is dead; say so instead of "OpenCane ready."
    /// and silence (Muse H3). `.notDetermined` is fine: ARKit prompts on first run.
    /// - Returns: true when the camera is refused (so `start()` skips "OpenCane ready.", which
    ///   would contradict the warning; Antigravity docs review).
    /// Callers: `start()`, `beginRoute` (to choose the degraded no-interlock path) and
    /// `startRouteNow` (to put the error back on screen after its own clear). `routeError` is set
    /// every time; the spoken line at most once a minute.
    @discardableResult
    private func announceCameraDenied() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .denied || status == .restricted else { return false }
        routeError = "Camera is off for OpenCane"
        // Launch and route start both check: speak it once a minute, not twice in a row
        // (Antigravity, final review: the demo-route launch queued the 20 s warning twice).
        let now = Date()
        if now.timeIntervalSince(cameraDeniedSpokenAt) > 60 {
            cameraDeniedSpokenAt = now
            speech.say("Camera access is off, so obstacle warnings cannot work. Turn on Camera for OpenCane in Settings.", .nav, ttl: 20)
        }
        return true
    }

    /// The mid-route screen-lock warning was spoken on this route (at most once per route).
    /// Set in `scenePhaseChanged(.background)`; reset by `startRouteNow`.
    @ObservationIgnored private var lockWarningGiven = false

    /// Camera at 60 fps instead of 30 (Mount card, persisted, off by default: heat untested over a
    /// long walk). See `DepthEngine.setHighFrameRate`. `init` pushes the stored value before
    /// `start()` (only the flag); a change later re-runs the AR session inside `DepthEngine`.
    /// Also read by `HazardsCard` to render the live view at 60 fps.
    var highFrameRateCamera: Bool = Settings.bool("highFrameRateCamera", default: false) {
        didSet {
            guard !revertingSensorModeSetting else { return }
            let decision = sensorModeInterlock.request(.highFrameRate, source: .user)
            guard decision == .allowRestart else {
                revertingSensorModeSetting = true
                highFrameRateCamera = oldValue
                revertingSensorModeSetting = false
                Settings.set(oldValue, "highFrameRateCamera")
                rejectSensorModeChange(.highFrameRate, decision: decision)
                return
            }
            Settings.set(highFrameRateCamera, "highFrameRateCamera")
            depth.setHighFrameRate(highFrameRateCamera)
        }
    }

    /// When the camera-denied warning was last spoken (`announceCameraDenied`). Wall clock
    /// (`Date`), because it spans launch and route start, not AR frames.
    @ObservationIgnored private var cameraDeniedSpokenAt = Date.distantPast

    /// Stop the running route without speaking (used before starting another one).
    /// Caller: `beginRoute`, only when `nav.isNavigating` (a second start mid-route, Muse M5).
    /// Unlike `stopRoute` it says nothing, leaves GPS running, does not touch a pending route
    /// start or MapKit build (callers cancel those first), ends the Live Activity immediately
    /// (the next one starts at once) and cancels the trip tracker synchronously.
    private func endRouteQuietly() {
        speech.routeLines = []               // no route: nothing standing to re-request
        nav.stop()
<<<<<<< HEAD
        location.setNavigating(false)
=======
        finishSensorModeRoute()
>>>>>>> 21b1717 (Step 29: interlock AR sensor mode restarts during routes)
        beacon.stop()
        head.stop()
        stopTicker()
        trip.cancel()                        // synchronous: the new trip.start() must not be no-op'd
        liveActivity.end(immediate: true)
        speech.stopAll()
        logger.event("route", ["action": "restart"])
    }

<<<<<<< HEAD
    /// Thermal: was the phone already hot (`.serious` or `.critical`) at the last `updateThermal`,
    /// so "Phone is hot…" is spoken on the cool → hot transition only (Muse L5).
=======
    /// Translate a refused sensor setting into the existing route error + speech channels. The
    /// walker must hear why the switch snapped back; a settings-screen change must never be a
    /// silent no-op. Caller: the face-tracking and high-frame-rate setting observers.
    private func rejectSensorModeChange(_ mode: SensorMode, decision: SensorModeDecision) {
        let line: String
        switch decision {
        case .refuseWhileStarting:
            line = "Sensor settings cannot change while a route is starting. Wait for obstacle detection to be ready."
        case .refuseWhileNavigating:
            line = "Sensor settings cannot change while a route is guiding you. Stop the route first."
        case .refuseWhileFinishing:
            line = "Wait for the camera transition to finish."
        case .deferUntilRouteEnds, .allowRestart:
            // The caller only invokes this for a refusal. Keep a defensive line rather than
            // accidentally announcing a misleading state if a new decision is added later.
            line = "Sensor settings cannot change during this route."
        }
        routeError = line
        speech.say(line, .nav, ttl: 10)
        logger.event("sensor_mode", ["mode": mode.rawValue, "action": "refused",
                                      "phase": sensorModeInterlock.phase.rawValue])
    }

    /// Reserve the sensor configuration for the route-start freshness window. This is separate
    /// from `DepthReadiness`: the depth gate decides when ARKit is trustworthy, while this policy
    /// prevents settings from restarting that same session underneath the gate.
    private func reserveSensorModeRouteStart() {
        sensorModeFinishGeneration &+= 1
        sensorModeFinishTask?.cancel()
        sensorModeFinishTask = nil
        sensorModeInterlock.routeStartQueued()
        logger.event("sensor_mode", ["action": "route_start_reserved",
                                      "phase": sensorModeInterlock.phase.rawValue])
    }

    /// Mark the point at which navigation effects begin. Called immediately before `nav.start`.
    private func markSensorModeRouteStarted() {
        // A camera teardown may still be draining when a deliberate degraded route starts (for
        // example, camera permission is denied, so the depth gate is skipped). The old route-end
        // task must not release or apply a deferred mesh restart underneath this new route.
        sensorModeFinishGeneration &+= 1
        sensorModeFinishTask?.cancel()
        sensorModeFinishTask = nil
        sensorModeInterlock.routeStarted()
        logger.event("sensor_mode", ["action": "route_started",
                                      "phase": sensorModeInterlock.phase.rawValue])
    }

    /// Release the route reservation and apply any thermal mesh change that was deliberately held
    /// back. User setting changes never reach this path: they were refused at their property
    /// observer, so no AR restart can occur during guidance.
    private func finishSensorModeRoute() {
        guard sensorModeInterlock.phase != .idle else { return }
        sensorModeInterlock.routeFinishing()

        // `beginRoute` may have queued the two-camera teardown immediately before this route
        // timed out or was canceled. Never run ARKit beside that session: wait for the serialized
        // chain, and keep the policy non-idle until the wait completes. A newer route cancels this
        // task in `reserveSensorModeRouteStart()`; its own readiness window then owns the same
        // deferred mode instead of letting this old task restart ARKit mid-route.
        if let work = bothCamerasWork {
            sensorModeFinishGeneration &+= 1
            let generation = sensorModeFinishGeneration
            sensorModeFinishTask?.cancel()
            sensorModeFinishTask = Task { @MainActor [weak self] in
                await work.value
                guard !Task.isCancelled, let self,
                      self.sensorModeFinishGeneration == generation,
                      !self.bothCameras.isRunning else { return }
                self.sensorModeFinishTask = nil
                self.releaseSensorModeRoute()
            }
            logger.event("sensor_mode", ["action": "deferred_restart_waiting_for_camera_teardown"])
            return
        }
        // Defensive: `bothCamerasWork` should exist whenever MultiCam is running. If it does not,
        // leave the interlock finishing rather than ever starting ARKit on occupied cameras.
        guard !bothCameras.isRunning else {
            logger.event("sensor_mode", ["action": "deferred_restart_blocked_cameras_running"])
            return
        }
        releaseSensorModeRoute()
    }

    /// Complete a route-end release once no camera transition can contend with ARKit. Caller:
    /// `finishSensorModeRoute`; all state remains on the main actor.
    private func releaseSensorModeRoute() {
        let deferred = sensorModeInterlock.routeEnded()
        guard !deferred.isEmpty else { return }
        if deferred.contains(.meshClassification) {
            depth.applyPendingConfigurationIfNeeded()
        }
        logger.event("sensor_mode", ["action": "deferred_restart_applied",
                                      "modes": deferred.map(\.rawValue)])
    }

    /// Thermal: was the phone already hot at the last update (announce transitions only).
>>>>>>> 21b1717 (Step 29: interlock AR sensor mode restarts during routes)
    @ObservationIgnored private var wasHot = false

    // MARK: Headphones / watch presence

    /// Beacon only into headphones; say when they come and go so a blind user knows why the
    /// click vanished (and that speech is now coming out of the cane).
    /// Called once from `start()`. `onChange` fires only on a headphone state flip, so the initial
    /// state is seeded by hand after `audioRoute.start()`. A connect mid-route restarts head
    /// tracking and marks a recenter as pending (the new AirPods have no forward reference yet);
    /// a disconnect does not stop the head tracker.
    private func wireAudioRoute() {
        audioRoute.onChange = { [weak self] connected, name in
            guard let self else { return }
            self.beacon.headphonesConnected = connected
            self.logger.event("audioroute", ["connected": connected, "name": name])
            self.recordDeviceCapabilities()
            if connected {
                self.speech.say("\(name) connected.", .nav, ttl: 5)
                if self.nav.isNavigating { self.head.start(); self.recenterPending = true }
            } else {
                self.speech.say("Headphones disconnected. Beacon paused.", .nav, ttl: 5)
                self.head.stop()                 // no AirPods, no motion: stop the manager
            }
        }
        audioRoute.onImmediateChange = { [weak self] connected in
            self?.beacon.headphonesConnected = connected      // no debounce for silencing the click
        }
        audioRoute.start()
        beacon.headphonesConnected = audioRoute.headphonesConnected
    }

    /// Turns the AirPods double nod (`HeadPoseTracker.onDoubleNod`) into `startVoiceInput()` when
    /// `nodToTalkEnabled` is on. Called once from `start()`; the tracker itself only delivers nods
    /// while a route is running (see `nodToTalkEnabled`).
    ///
    /// Every detected double nod is logged as `head_nod` — **including ones ignored because the
    /// option is off** — with the pitch at the moment of the fire and whether voice input was
    /// already listening, so a walk with the switch off still measures the false-positive rate the
    /// untuned detector needs before it can ship on (AGENTS.md "make the invisible visible").
    private func wireHeadNod() {
        head.onDoubleNod = { [weak self] in
            guard let self else { return }
            self.logger.event("head_nod", ["pitch_deg": self.head.pitchDeg ?? 0,
                                           "listening": self.voiceInput.isListening,
                                           "enabled": self.nodToTalkEnabled])
            guard self.nodToTalkEnabled else { return }
            self.startVoiceInput()           // start only, never toggle: a nod cannot cut a sentence
        }
    }

    /// Spoken once at route start so the walker knows which channels are live before moving.
    /// Near-last step of `startRouteNow` (only the `describeEveryWaypoint` hook follows); each line
    /// is `.nav` with a 20 s TTL, queued after the intro. Lines: no headphones; a paired watch that
    /// is not reachable; unhealthy haptics (routed to the watch when reachable, else to speech).
    /// These lines are not written to the trip log as `speech` (only `speech_dispatch` sees them).
    private func announceChannels() {
        var lines: [String] = []
        if !audioRoute.headphonesConnected {
            lines.append("No headphones. Beacon paused until AirPods connect.")
        }
        if watch.isPaired, !watch.isReachable {
            lines.append("Watch not reachable. Open OpenCane on the watch.")
        }
        // Always say where obstacle cues went when the cane cannot buzz (Muse: with the watch
        // reachable this was silent, so cane silence read as "path clear").
        if !haptics.isHealthy {
            lines.append(watch.isReachable ? "Haptics unavailable. Obstacle cues on the watch."
                                           : "Haptics unavailable. Obstacle cues will be spoken.")
        }
        for line in lines { speech.say(line, .nav, ttl: 20) }
    }

    // MARK: Navigation (step 6)

    /// Installs every LocationService and NavigationEngine callback. Called once from `start()`.
    ///
    /// - `location.onFix`: feeds `nav` and `trip`; while navigating also updates the Live
    ///   Activity, pushes status to the watch (the link dedups) and tries an auto-recenter;
    ///   logs `gps`. Fix timestamps are wall clock (`timeIntervalSinceReferenceDate`).
    /// - `location.onHeading`: gyro-gated here (not in LocationService) — a compass reading taken
    ///   mid cane-sweep is noise; the gate only applies while depth is running. Uses wall-clock
    ///   `now`, the same clock as `GeoFix.timestamp` (distinct from the AR clock).
    /// - `nav.onSpeak` → `speech.say(ttl: 12)`; `nav.onRepeat` → `speech.sayAgain` (bypasses the
    ///   queue's coalescing: the line may still be playing — AGENTS.md "Repeat speaks the last
    ///   line actually spoken").
    /// - `nav.onNavCue` → watch tap, the same cue as long soft buzzes on the cane
    ///   (`haptics.playNav`, except `.obstacle`) + Live Activity glyph kind.
    /// - `nav.onWaypointAdvanced` → recenter becomes pending (re-zeroed only once walking
    ///   straight, never on a timer); the `describeEveryWaypoint` hook.
    /// - `nav.onArrived` → stops beacon/head/ticker (GPS stays on), ends the Live Activity, then
    ///   speaks the trip summary after `await trip.stop()` refreshes the step count.
    /// Every callback captures `[weak self]` and runs on the main actor (the engines call them there).
    private func wireNavigation() {
        location.onFix = { [weak self] fix in
            guard let self else { return }
            FrameReplay.shared.update(position: fix.coordinate)   // simulator Street View e2e only
            self.nav.update(fix: fix)
            self.trip.ingest(fix)
            if self.nav.isNavigating {
                let rep = self.depth.report
                let obsStatus: LiveActivityObstacleGlance
                let obsDist: Double
                let headM: Double
                if self.activeCue == .head {
                    let h0 = rep.grid.head[0]
                    let h1 = rep.grid.head[1]
                    let h2 = rep.grid.head[2]
                    let minH = min(h0.isFinite ? h0 : 99, h1.isFinite ? h1 : 99, h2.isFinite ? h2 : 99)
                    if minH < 90 {
                        obsStatus = .head
                        headM = Double(minH)
                        obsDist = headM
                    } else {
                        obsStatus = .clear
                        headM = 0.0
                        obsDist = 0.0
                    }
                } else if let hazard = rep.groundHazard {
                    obsStatus = .dropOff
                    obsDist = Double(hazard.distance)
                    headM = 0.0
                } else if self.activeCue != .clear {
                    let n0 = rep.grid.nearest(lane: 0)
                    let n1 = rep.grid.nearest(lane: 1)
                    let n2 = rep.grid.nearest(lane: 2)
                    let minD = min(n0.isFinite ? n0 : 99, n1.isFinite ? n1 : 99, n2.isFinite ? n2 : 99)
                    if minD < 90 {
                        obsStatus = .warning
                        obsDist = Double(minD)
                        headM = 0.0
                    } else {
                        obsStatus = .clear
                        obsDist = 0.0
                        headM = 0.0
                    }
                } else {
                    obsStatus = .clear
                    obsDist = 0.0
                    headM = 0.0
                }
                let acc = Int((fix.accuracy).rounded())
                let detail = acc > 0 && acc <= 50 ? "±\(acc)m GPS" : ""

                self.liveActivity.update(
                    instruction: self.nav.instruction,
                    distanceM: self.nav.distanceToNext ?? 0,
                    kind: self.lastNavKind,
                    obstacleStatus: obsStatus,
                    obstacleDistanceM: obsDist,
                    headClearanceM: headM,
                    statusDetail: detail
                )
                // The link dedups (same text and < 5 m change), so this is ~1 message / 5 s.
                self.pushStatusToWatch()
                self.autoRecenterIfWalkingStraight(fix)
            }
            self.logger.event("gps", ["lat": fix.coordinate.latitude, "lon": fix.coordinate.longitude,
                                      "acc": fix.accuracy, "speed": fix.speed])
            // Throttled to one every FamilyAlertLimits.locationInterval inside the policy.
            self.family.location(lat: fix.coordinate.latitude, lng: fix.coordinate.longitude,
                                 accuracyM: fix.accuracy, heading: self.location.heading,
                                 speedMps: Double(fix.speed), now: fix.timestamp)
        }
        location.onHeading = { [weak self] h, fromCourse in
            guard let self else { return }
            // Gyro gate the compass only: a compass reading taken mid-sweep is noise, but the GPS
            // course is immune to the sweep (Muse review H1 — gating it froze the heading while
            // walking with a normal sweep).
            guard fromCourse || self.depth.report.isTrusted || !self.depth.isRunning else { return }
            self.nav.update(heading: h, now: Date().timeIntervalSinceReferenceDate)
            self.beacon.setHeading(h)
        }
        nav.onSpeak = { [weak self] text, priority in
            self?.speech.say(text, priority, ttl: 12)
            self?.logger.event("speech", ["text": text, "priority": "nav"])
        }
        nav.onRepeat = { [weak self] text in
            self?.speech.sayAgain(text, .nav)
            self?.logger.event("speech", ["text": text, "priority": "nav", "repeat": true])
        }
        nav.onNavCue = { [weak self] cue in
            self?.watch.send(nav: cue)
            if cue != .obstacle { self?.haptics.playNav(cue) }   // felt on the cane too
            self?.lastNavKind = cue.rawValue
            self?.logger.event("navcue", ["cue": cue.rawValue])
        }
        nav.onWaypointAdvanced = { [weak self] in
            guard let self else { return }
            self.logger.event("waypoint", ["index": self.nav.waypointIndex])
            if Self.describeEveryWaypoint { self.describeScene() }
            self.pushStatusToWatch()
            // The head reference is re-zeroed on the new leg, but only once the user is
            // demonstrably walking it straight (never on a timer: at a curb they are stopped
            // with their head turned toward traffic).
            self.recenterPending = true
            self.straightWalk.reset()
        }
        nav.onArrived = { [weak self] in
            guard let self else { return }
            self.logger.event("arrived")
<<<<<<< HEAD
            self.family.tripEnded(destination: self.activeRouteName, arrived: true,
                                  lat: self.location.fix?.coordinate.latitude,
                                  lng: self.location.fix?.coordinate.longitude)
=======
            self.finishSensorModeRoute()
>>>>>>> 21b1717 (Step 29: interlock AR sensor mode restarts during routes)
            if Self.describeEveryWaypoint { self.describeScene() }
            self.beacon.stop()
            self.head.stop()
            self.location.setNavigating(false)
            // GPS deliberately stays on after arrival: it runs for the life of the foreground
            // session now (see `start()`), so the card keeps telling the truth and the next route
            // begins with a warm fix instead of a cold one.
            self.stopTicker()
            self.pushStatusToWatch()
            self.liveActivity.end(final: self.nav.instruction)
            // Arrival card, spoken after the waypoint's own line (same priority → queued),
            // once the step count has been refreshed.
            Task { [weak self] in
                guard let self else { return }
                await self.trip.stop()
                self.medicalProfile.recordCompletedTrip()
                self.medicalProfile.refreshMobilityStats()
                let destination = self.nav.route?.waypoints.last?.say ?? "Arrived"
                let summary = self.trip.spokenSummary(destination: destination)
                self.nav.appendToLastSpoken(summary)     // Repeat at the door includes the numbers
                self.speech.say(summary, .nav, ttl: 30)
                self.logger.event("speech", ["text": summary, "priority": "nav"])
                // Close the cloud walk with exactly the numbers the walker just heard, and
                // refresh the day's mobility row now that the trip count has gone up.
                self.cloud.endTrip(outcome: "arrived", elapsed: self.trip.elapsed,
                                   distanceM: self.trip.distanceM, steps: self.trip.steps,
                                   stepSource: self.trip.stepSource,
                                   waypointsReached: self.nav.route?.waypoints.count ?? 0,
                                   batteryPct: self.batteryPercent, spokenSummary: summary,
                                   end: self.location.fix)
                self.cloud.saveMobility(self.medicalProfile.mobilityStats)
            }
        }
    }

    /// Last wrist cue kind, for the Live Activity glyph.
    /// A `NavCue.rawValue` ("turnLeft" / "turnRight" / "crossing" / "arrived"); reset to
    /// "straight" at `startRouteNow`. A passed-by advance sends no cue, so the kind is kept.
    /// Any new value must also be handled by the widget's glyph switch (NavLiveActivity.swift).
    /// Name of the route being walked ("ISR to CIF"), or nil when idle. Only the family-alert
    /// context reads it; `nav` itself keeps no name.
    private(set) var activeRouteName: String?
    @ObservationIgnored private var lastNavKind = "straight"

    /// The user is facing the way to walk: zero the head yaw there.
    /// Manual trigger (`GuideCard` "Recenter" button, watch Recenter, `RecenterIntent`). Zeroes
    /// both head sources (AirPods and front camera). Clears `recenterPending`, so
    /// the beacon starts using head yaw again; speaks "Recentered." (2 s TTL) and logs `recenter`.
    func recenter() {
        head.recenter()
        faceHead.recenter()          // both sources, so switching between them needs no second press
        recenterPending = false
        speech.say("Recentered.", .nav, ttl: 2)
        logger.event("recenter")
    }

    /// Say the current instruction again (`GuideCard` Repeat and the arrival card's repeat,
    /// watch "Repeat", `RepeatInstructionIntent`). Logs `repeat`.
    /// Delegates to `nav.repeatInstruction()`, which speaks the last line actually spoken plus
    /// the distance to the next waypoint, through `onRepeat` (bypasses queue coalescing).
    func repeatInstruction() {
        nav.repeatInstruction()
        logger.event("repeat")
    }

    // MARK: Auto-recenter (README §3: "auto when walking straight for 3 s")

    /// Set at route start (`startRouteNow`) and after every waypoint; cleared once a recenter
    /// happens. While set, the beacon renders from the phone heading alone (see startTicker).
    /// Also set when headphones connect mid-route (`wireAudioRoute`).
    @ObservationIgnored private var recenterPending = false
    /// CaneKitLogic.StraightWalkDetector (unit-tested): 3 consecutive fixes (the first counts) at
    /// > 0.6 m/s with accuracy ≤ 20 m, course steady within 15° and head yaw within 8°.
    /// Library defaults are the source of truth (`StraightWalkDetector` in NavSupport.swift;
    /// AGENTS.md quotes the same 0.6 m/s).
    @ObservationIgnored private var straightWalk = StraightWalkDetector()
    /// After a crossing the user steps off the curb with the head still turned toward traffic:
    /// only re-zero once they are this far past the crossing waypoint.
    /// Metres. ⚠ AGENTS.md: never auto-recenter within 15 m of a crossing — do not lower this
    /// without a device walk test at a curb.
    private let recenterAfterCrossingM: Double = 15

    /// Walking straight on the new leg with a still head and no turn in progress: the head is
    /// straight, so this pose becomes the beacon's forward.
    /// Called per GPS fix while navigating (from `location.onFix`). Any failed guard resets the
    /// detector; never fires on a timer, while a turn is settling, without a head source (AirPods
    /// connected or the front camera tracking a face), or within `recenterAfterCrossingM` of a
    /// just-reached crossing. The still-head test uses `HeadYawSelector` with
    /// `recenterPending: false` (the raw yaw, since pending would force 0 and always pass).
    /// On success both sources are re-zeroed and `recenter {auto: true}` is logged; nothing is spoken.
    /// ⚠ Do not loosen the detector gates or the crossing exclusion without a device walk test
    /// (covered by `straightWalkNeedsThreeSteadyFixesCountingTheFirst`,
    /// `straightWalkRestartsOnATurnAStopOrAHeadTurn`).
    private func autoRecenterIfWalkingStraight(_ fix: GeoFix) {
        // Either head source qualifies: without one there is nothing to re-zero, and the front
        // camera's face anchor is as good a "the head is still" signal as the AirPods' yaw.
        let hasHeadSource = head.isConnected || faceHead.isTracking
        guard recenterPending, !nav.isSettling, hasHeadSource else { straightWalk.reset(); return }
        if let wp = nav.lastReached, wp.crossing,
           GeoMath.distanceMeters(fix.coordinate, wp.coordinate) < recenterAfterCrossingM {
            straightWalk.reset()
            return
        }
        let yaw = HeadYawSelector.choose(airPodsYaw: head.headYawDeg, faceYaw: faceHead.yawDeg,
                                         recenterPending: false)
        let straight = straightWalk.update(speed: fix.speed, accuracy: fix.accuracy,
                                           heading: location.heading, headYaw: yaw.degrees)
        guard straight else { return }
        head.recenter()
        faceHead.recenter()
        recenterPending = false
        logger.event("recenter", ["auto": true])
    }

    /// Start the bundled demo route (ISR Townsend Hall → CIF).
    /// Triggered by the "Start route to CIF" button, `StartDemoRouteIntent`, and at launch by the
    /// `--demo-route` / `CANEKIT_DEMO_ROUTE=1` automation hook. On failure sets `routeError` and
    /// says "Route file missing."
    /// ⚠ Abandons an in-flight MapKit build first: a "Take me to …" search that returned *after*
    /// the demo route started would otherwise call `beginRoute` again and silently swap the walker
    /// onto the searched route mid-walk. A route already queued behind the depth interlock is
    /// cancelled too, for the same reason (the newest request wins).
    /// The name inside `Resources/route_isr_cif.json`, so an uploaded route can be labelled
    /// `bundled` rather than `mapkit`. Read once (the file is in the app bundle and cannot
    /// change); "" when the file is missing, which simply makes every route read as `mapkit`.
    static let bundledRouteName: String = (try? RouteSource.bundled().name) ?? ""

    func startDemoRoute() {
        cancelRouteBuild()
        cancelPendingRouteStart()
        do {
            let route = try RouteSource.bundled()
            beginRoute(route)
        } catch {
            routeError = error.localizedDescription
            speech.say("Route file missing.", .nav)
        }
    }

    /// Build a live MapKit walking route to the typed `destinationQuery` ("Go" button / return
    /// key). Empty text → `routeError = "Type a destination first"` (⚠ UI-test string).
    /// A thin alias for `navigate(to: destinationQuery)`, which does the trimming, the empty
    /// check and the build. Caller: `DestinationField`.
    func startMapKitRoute() {
        navigate(to: destinationQuery)
    }

    /// Drop the route error line ("Type a destination first", "No GPS fix yet", a MapKit error).
    /// Called by `DestinationField` on every keystroke: an error about the *previous* attempt
    /// must not sit under a box the walker is already retyping (it reads as a permanent state).
    /// Also clears a leftover `routeStartStatus` (a timed-out or cancelled start) — but never while
    /// a route is still queued, whose warm-up status must stay visible.
    func clearRouteError() {
        routeError = nil
        if pendingRouteStart == nil { routeStartStatus = nil }
    }

    /// Walking route from the current fix to a spoken or typed place: the campus gazetteer
    /// first, then the nearest reasonable MKLocalSearch result (`RouteSource.walking(to: .query)`,
    /// which tries `CampusPlaces.match` and falls back to `RouteSource.mapKit(to:from:)`).
    /// Called by `startMapKitRoute()`, a tapped MapKit suggestion in `DestinationField`,
    /// `TakeMeToIntent` (Siri "Take me somewhere in OpenCane" → "Where do you want to go?") and
    /// `ConversationCoordinator` ("take me to …" by voice). Shows the text in the destination field.
    /// - Parameter query: free text; trimmed of spaces here.
    func navigate(to query: String) {
        let text = query.trimmingCharacters(in: .whitespaces)
        // Spoken as well as shown: this is the one failure on this path that said nothing, and the
        // person most likely to tap Go with an empty box is the one who cannot see that the box is
        // empty — or who meant to hit the clear button next to it. Idle-card only, so it can never
        // cut a route cue. The visible string is unchanged (hard rule 9's label contract).
        guard !text.isEmpty else {
            routeError = "Type a destination first"
            speech.say("Type a destination first.", .nav)
            return
        }
        destinationQuery = text
        buildRoute(to: .query(text), searchLine: "Finding a route to \(text).")
    }

    /// Walking route from the current fix to a gazetteer entrance, no search (Siri "Take me to
    /// Grainger in OpenCane" → `TakeMeToIntent` with a `CampusDestination`; a tapped CAMPUS row in
    /// `DestinationField`). Puts `place.name` in the destination field.
    /// - Parameter place: a `CampusPlaces` entry; its entrance coordinate is used as-is.
    func navigate(to place: CampusPlace) {
        destinationQuery = place.name
        buildRoute(to: .place(name: place.name, coordinate: place.coordinate),
                   searchLine: "Finding a route to \(place.name).")
    }

    /// "Navigate to CIF from here": Apple Maps walking directions from the live GPS fix to the
    /// CIF east entrance — the last waypoint of the bundled route file, as a coordinate (no
    /// search, so MapKit cannot pick a different "CIF"). GuideCard button and
    /// `NavigateToCIFIntent`. Missing route file → `routeError` + "Route file missing."
    func navigateToCIFFromHere() {
        guard let entrance = try? RouteSource.bundled().waypoints.last else {
            routeError = RouteError.missingBundledRoute.localizedDescription
            speech.say("Route file missing.", .nav)
            return
        }
        buildRoute(to: .place(name: entrance.placeName, coordinate: entrance.coordinate),
                   searchLine: "Finding a walking route to CIF from here.")
    }

    /// The in-flight MapKit build (fix wait + search + directions). Cancelled by `stopRoute()` and
    /// `startDemoRoute()` and replaced by a newer request, so a Stop said while "Finding a route…"
    /// plays cannot be followed by the old route starting anyway.
    @ObservationIgnored private var routeBuildTask: Task<Void, Never>?
    /// Bumped by every new build and by `cancelRouteBuild()`; a build whose number is no longer
    /// current never starts its route or touches `isBuildingRoute`/`routeError`.
    @ObservationIgnored private var routeBuildGeneration = 0

    /// Shared MapKit path for the typed field, Siri and "Navigate to CIF from here".
    /// Location refused → spoken now (not after a 15 s wait for a fix that never comes). Else
    /// starts location, says `searchLine`, waits up to 30 × 500 ms (15 s) for a first fix, asks
    /// `RouteSource.walking(to:from:)`, then `beginRoute(_:announce:)` with "Walking to <place>,
    /// N meters." (`WalkingIntro`) so a wrong pick can be stopped. Errors are shown
    /// (`routeError`) and spoken. `isBuildingRoute` is cleared on every exit of the current build.
    /// A route still queued behind the depth interlock is cancelled first (newest request wins).
    /// Logs `destination {name, meters, waypoints}` once MapKit answers.
    /// - Parameters:
    ///   - destination: free text (gazetteer, then search) or a known entrance.
    ///   - searchLine: spoken at `.nav` as soon as the build starts ("Finding a route to …").
    /// Callers: both `navigate(to:)` overloads and `navigateToCIFFromHere`.
    private func buildRoute(to destination: RouteDestination, searchLine: String) {
        cancelPendingRouteStart()
        guard !announceLocationDenied() else { return }
        cancelRouteBuild()
        let generation = routeBuildGeneration
        location.start()
        isBuildingRoute = true
        routeError = nil
        speech.say(searchLine, .nav)
        routeBuildTask = Task { [weak self] in
            guard let self else { return }
            let isCurrent = { !Task.isCancelled && self.routeBuildGeneration == generation }
            defer { if isCurrent() { self.isBuildingRoute = false; self.routeBuildTask = nil } }
            // Wait briefly for a first fix if we have none yet. (`try?` swallows cancellation, so
            // the loop checks it: a cancelled sleep returns at once.)
            var tries = 0
            while self.location.fix == nil, tries < 30, isCurrent() {
                try? await Task.sleep(for: .milliseconds(500))
                tries += 1
            }
            guard isCurrent() else { return }
            guard let fix = self.location.fix else {
                self.routeError = "No GPS fix yet"
                self.speech.say("No GPS fix yet. Try again outside.", .nav)
                return
            }
            do {
                let origin = CLLocationCoordinate2D(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
                let planned = try await RouteSource.walking(to: destination, from: origin)
                guard isCurrent() else { return }
                self.logger.event("destination", ["name": planned.placeName, "meters": planned.walkingMeters,
                                                  "waypoints": planned.route.waypoints.count])
                self.beginRoute(planned.route,
                                announce: WalkingIntro.line(place: planned.placeName, meters: planned.walkingMeters,
                                                            accuracyM: fix.accuracy))
            } catch {
                guard isCurrent() else { return }
                self.routeError = error.localizedDescription
                self.speech.say("Could not build a route. \(error.localizedDescription)", .nav)
            }
        }
    }

    /// Abandons any in-flight MapKit build (`stopRoute`, or a newer request): cancels the task,
    /// invalidates its generation and clears `isBuildingRoute`.
    private func cancelRouteBuild() {
        routeBuildTask?.cancel()
        routeBuildTask = nil
        routeBuildGeneration += 1
        isBuildingRoute = false
    }

    /// Skip to the next waypoint (`GuideCard` Next, Siri `NextWaypointIntent`, watch Next / crown).
    /// Says "No route running." (`.nav`, 2 s TTL) when idle, like the watch always did.
    func nextWaypoint() {
        if nav.isNavigating { nav.next() } else { speech.say("No route running.", .nav, ttl: 2) }
    }

    /// Stop guidance ("Stop route" button, `StopRouteIntent`, `ConversationCoordinator`). Abandons
    /// an in-flight MapKit build and a route queued behind the depth interlock first, then tears
    /// down nav, beacon, head tracking, the ticker, the trip tracker (fire-and-forget) and the Live
    /// Activity — but **not** GPS, which belongs to the foreground session — clears the speech
    /// queue and `speech.routeLines` so queued waypoint lines cannot play after Stop, says
    /// "Route stopped.", logs `route {action: stop}` and pushes the idle status to the watch.
    /// Speaks even with no route running (it doubles as "cancel whatever I asked for").
    func stopRoute() {
        stopSimulatedWalk()
        cancelRouteBuild()
        cancelPendingRouteStart()
        // Before `activeRouteName` is cleared, and only when a walk was actually under way, so
        // pressing Stop on an idle guide does not email the family about a trip that never began.
        if nav.isNavigating {
            family.tripEnded(destination: activeRouteName, arrived: false,
                             lat: location.fix?.coordinate.latitude,
                             lng: location.fix?.coordinate.longitude)
        }
        nav.stop()
<<<<<<< HEAD
        activeRouteName = nil
=======
        finishSensorModeRoute()
>>>>>>> 21b1717 (Step 29: interlock AR sensor mode restarts during routes)
        // Not `location.stop()`: GPS belongs to the foreground session, not to the route. Stopping
        // it here made the card read "Off" the moment a route ended and made the next Start begin
        // with no fix.
        location.setNavigating(false)
        beacon.stop()
        head.stop()
        stopTicker()
        Task { [weak self] in await self?.trip.stop() }
        liveActivity.end(immediate: true)
        speech.stopAll()                     // queued waypoint lines must not play after Stop
        speech.routeLines = []               // and nothing of that route stays on the prefetch list
        speech.say("Route stopped.", .nav)
        logger.event("route", ["action": "stop"])
        // Closed as `stopped`, not `arrived`: the distinction is the whole point of the column.
        // `trip.stop()` above is fire-and-forget, so these are the numbers as of this moment —
        // the same ones the arrival card would show.
        cloud.endTrip(outcome: "stopped", elapsed: trip.elapsed, distanceM: trip.distanceM,
                      steps: trip.steps, stepSource: trip.stepSource,
                      waypointsReached: nav.waypointIndex, batteryPct: batteryPercent,
                      spokenSummary: nil, end: location.fix)
        pushStatusToWatch()
    }

    /// Starts an on-device walk simulation along the active route (or starts the bundled demo route if idle).
    /// Advances synthesized GPS fixes between waypoints at `simulationSpeedMps` (default 1.4 m/s).
    func startSimulatedWalk(speedMps: Double? = nil) {
        stopSimulatedWalk()
        simulatedWalkGeneration &+= 1
        let generation = simulatedWalkGeneration
        if let s = speedMps { simulationSpeedMps = s }
        isSimulatingWalk = true

        if !nav.isNavigating {
            startDemoRoute()
        }

        simulatedWalkTask = Task { @MainActor [weak self] in
            // Wait up to 10 seconds for route to start (covers readiness check & fallback)
            var waits = 0
            while waits < 50 {
                guard let self, !Task.isCancelled, self.simulatedWalkGeneration == generation, self.isSimulatingWalk else { return }
                if self.nav.isNavigating { break }
                try? await Task.sleep(for: .milliseconds(200))
                waits += 1
            }
            guard let self, !Task.isCancelled, self.simulatedWalkGeneration == generation, self.isSimulatingWalk, self.nav.isNavigating else {
                self?.isSimulatingWalk = false
                return
            }

            // Get route waypoints to walk
            guard let waypoints = self.nav.route?.waypoints, waypoints.count >= 2 else {
                self.isSimulatingWalk = false
                return
            }

            let effectiveSpeed = min(8.0, max(0.8, self.simulationSpeedMps))
            var currentIdx = max(0, min(self.nav.waypointIndex, waypoints.count - 2))

            while !Task.isCancelled, self.simulatedWalkGeneration == generation, self.isSimulatingWalk, self.nav.isNavigating, currentIdx < waypoints.count - 1 {
                let fromCoord = waypoints[currentIdx].coordinate
                let toCoord = waypoints[currentIdx + 1].coordinate

                let legDist = GeoMath.distanceMeters(fromCoord, toCoord)
                let bearing = GeoMath.bearingDegrees(from: fromCoord, to: toCoord)

                let stepM = max(0.5, effectiveSpeed)
                let steps = max(1, Int(ceil(legDist / stepM)))

                for s in 0...steps {
                    guard !Task.isCancelled, self.simulatedWalkGeneration == generation, self.isSimulatingWalk, self.nav.isNavigating else { break }
                    let frac = Double(s) / Double(steps)
                    let lat = fromCoord.latitude + frac * (toCoord.latitude - fromCoord.latitude)
                    let lon = fromCoord.longitude + frac * (toCoord.longitude - fromCoord.longitude)
                    let stepCoord = Coordinate(latitude: lat, longitude: lon)

                    let fix = GeoFix(coordinate: stepCoord,
                                     accuracy: 2.0,
                                     speed: effectiveSpeed,
                                     timestamp: Date().timeIntervalSinceReferenceDate)
                    self.location.ingest(fix: fix, course: bearing)
                    try? await Task.sleep(for: .seconds(1))
                }
                currentIdx += 1
            }

            // Final arrival fix at destination
            if let last = waypoints.last, !Task.isCancelled, self.simulatedWalkGeneration == generation, self.isSimulatingWalk, self.nav.isNavigating {
                let fix = GeoFix(coordinate: last.coordinate,
                                 accuracy: 2.0,
                                 speed: 0.0,
                                 timestamp: Date().timeIntervalSinceReferenceDate)
                self.location.ingest(fix: fix, course: 0)
            }
            if self.simulatedWalkGeneration == generation {
                self.isSimulatingWalk = false
            }
        }
    }

    /// Stops the in-progress simulated walk.
    func stopSimulatedWalk() {
        simulatedWalkGeneration &+= 1
        isSimulatingWalk = false
        simulatedWalkTask?.cancel()
        simulatedWalkTask = nil
    }

    /// Lines the natural voice should have ready before they are needed.
    /// Prefetched in `start()` and again in `startRouteNow`, ahead of `speech.backgroundLines`
    /// (`SpokenPhrases.warningLines`, which every batch carries as its tail).
    /// ⚠ Must stay byte-identical to the strings spoken in NavigationEngine, CueSpeechPolicy and
    /// this file, or the prefetch cache misses and the line waits for synthesis. Fixed strings
    /// only: the *generated* warning lines (obstacle names, approach cues, signs, ground hazards)
    /// are enumerated by `SpokenPhrases` in CaneKitLogic, which owns their templates so they
    /// cannot drift by a byte.
    /// ⚠ The product name a human hears is **OpenCane**; the code/module/bundle id stay CaneKit
    /// (AGENTS.md → "The name split"). If the spoken name ever changes again, change it here and
    /// at the `speech.say` call in `start()` in the same edit — they are matched by bytes, not by
    /// a constant, so a half-rename is silent and only shows up as a line in the wrong voice.
    /// Contents: 24 literal lines below, then every `CueRules.allSpokenLines` and every
    /// `TorchSwitch.allSpokenLines` entry appended. ("Route started." and "Next." are not spoken
    /// on their own today; the intro "Route started. <name>. First: …" is prefetched separately.)
    static let commonLines = [
        "OpenCane ready.", "Route started.", "Route stopped.", "Next.", "Recentered.",
        "Veer left.", "Veer right.", "GPS weak. Waypoint cues paused until it recovers.", "GPS back.",
        "No route running.", "No GPS fix yet. Try again outside.",
        "Head height.", "Left.", "Right.", "Passed one waypoint.",
        "Obstacle detection warming up. Route will start when it is ready.", "Route start canceled.",
<<<<<<< HEAD
        "Obstacle detection warming up. Guiding with GPS.",
        // Refusals of the modes that re-run or pause ARKit (`setBothCameras`,
        // `faceHeadTrackingEnabled`): spoken at `.nav`, so a cache miss would hold route and
        // obstacle speech behind a fetch. ⚠ Keep byte-identical to those `speech.say` calls.
        "Both cameras cannot run while a route is guiding you. Stop the route first.",
        "Both cameras cannot run while a route is starting. Wait for obstacle detection to be ready.",
        "Head tracking without AirPods cannot change while a route is guiding you. Stop the route first.",
        "Head tracking without AirPods cannot change while a route is starting. Wait for obstacle detection to be ready.",
=======
        "Finish the sensor self-test before starting a route.",
        "Obstacle detection is back.",
        "Wait for the camera transition to finish.",
        "Sensor settings cannot change while a route is starting. Wait for obstacle detection to be ready.",
        "Sensor settings cannot change while a route is guiding you. Stop the route first.",
>>>>>>> 21b1717 (Step 29: interlock AR sensor mode restarts during routes)
        // Danger-sound lines (DangerSound.spokenLine, CaneKitLogic): a siren must not wait for a
        // synthesis round-trip. ⚠ Keep byte-identical to `DangerSound.spokenLine` — pinned by
        // `SoundAlertsTests.spokenLinesAreThePrefetchedOnes`.
        "Siren. Do not start crossing.", "Horn nearby.", "Vehicle sound nearby.",
    ]
        // Cue level / place change lines (`CueRules.allSpokenLines`, pinned by
        // `CueProfileTests.profileChangeLines`).
        + CueRules.allSpokenLines
        // Every flashlight line (`TorchSwitch.allSpokenLines`, pinned to the outcomes by
        // `TorchSwitchTests.allSpokenLinesMatchOutcomes`): toggle feedback never waits on a fetch.
        + TorchSwitch.allSpokenLines

    /// Shared entry for both route sources (the bundled demo route and every MapKit build).
    /// Order: tear down a route already guiding (`endRouteQuietly`) → refuse a denied Location
    /// (spoken, returns) → switch the two-camera view off (its teardown is serialised) → on a LiDAR
    /// phone with camera access, `queueRouteStart` (wait for `DepthReadiness`) → otherwise, the
    /// degraded paths (no LiDAR, camera denied — warned loudly), `startRouteNow` at once.
    /// The effects of actually starting guidance live in `startRouteNow`.
    /// - Parameters:
    ///   - route: the waypoints to guide along.
    ///   - announce: MapKit routes' "Walking to Grainger Engineering Library, 750 meters.", said
    ///     when the route really starts and before the intro, so the walker hears what was chosen
    ///     first and can say Stop if it is wrong; nil for the demo route.
    /// Callers: `startDemoRoute`, `buildRoute`.
    private func beginRoute(_ route: Route, announce: String? = nil) {
        // Sensor self-tests deliberately re-run ARKit / MultiCam outside the route pipeline. Do
        // not let a route begin while their delayed cleanup could restart a camera underneath it;
        // the existing speech + route-error channels make the refusal explicit to a blind walker.
        guard !selfTestRunning else {
            let line = "Finish the sensor self-test before starting a route."
            routeError = line
            speech.say(line, .nav, ttl: 10)
            logger.event("sensor_mode", ["action": "route_refused_self_test"])
            return
        }
        // A second start mid-route (Action button / Siri) restarts cleanly (Muse M5).
        if nav.isNavigating { endRouteQuietly() }
        // Location refused: say so instead of "Route started" followed by silence (Muse H2).
        if announceLocationDenied() { return }
        // A route needs the obstacle channel, so the two-camera spotter view cannot survive into
        // it. `setBothCameras(false)` resumes ARKit and already speaks "Both cameras off. Obstacle
        // detection is restarting." (then "…is back." once depth is confirmed) — a second line
        // here would only add noise in front of the route
        // instructions, so this records the *reason* in the log and says nothing extra.
        if bothCamerasEnabled {
            bothCamerasEnabled = false
            logger.event("both_cameras", ["action": "off_for_route"])
        }
        // On a LiDAR phone with camera access, route guidance must not begin in the short window
        // where ARKit is still warming or recovering from the two-camera transition. Camera denial
        // is the one deliberate degraded path: AGENTS.md requires GPS guidance to continue while
        // loudly admitting that obstacle warnings cannot work.
        let cameraDenied = announceCameraDenied()
        if lidarSupported, !cameraDenied {
            queueRouteStart(route, announce: announce)
            return
        }
        startRouteNow(route, announce: announce)
    }

    /// Queue a route until `DepthEngine` reports the pure freshness bar as ready. Waiting is
    /// bounded and observable; the request is resumed automatically on the first ready transition.
    ///
    /// Why (Step 22/25): right after launch, an unlock or the two-camera view, ARKit needs a moment
    /// before its lanes are real; starting guidance in that window meant route lines with a dead
    /// obstacle channel behind them. The bar (`DepthReadiness.standardConfiguration`): 3
    /// consecutive same-frame reports with `.normal` tracking, scene depth and sweep trust, no gap
    /// over 0.5 s, all within 5 s.
    ///
    /// Effects: stores `pendingRouteStart`, sets `routeStartWaiting` / `routeStartStatus`, speaks
    /// "Obstacle detection warming up. Route will start when it is ready." (`.nav`, 8 s), sends
    /// the watch a status, logs `route_readiness {state: warming, timeout_s, required_frames}`,
    /// then starts the two tasks (`routeReadinessTimeoutTask`, `routeReadinessTask`). A newer call
    /// supersedes an older one via `routeStartGeneration`. Outcome arrives in
    /// `depthReadinessChanged` (ready / timed out) or `failQueuedRouteStart` (request deadline).
    /// - Parameters: the same `route` / `announce` `startRouteNow` will receive.
    /// Caller: `beginRoute`.
    private func queueRouteStart(_ route: Route, announce: String?) {
        routeReadinessTask?.cancel()
        routeReadinessTimeoutTask?.cancel()
        routeStartGeneration &+= 1
        let generation = routeStartGeneration
        pendingRouteStart = PendingRouteStart(route: route, announce: announce)
        reserveSensorModeRouteStart()
        routeStartWaiting = true
        routeStartStatus = "Obstacle detection warming up. Route will start when it is ready."
        routeError = nil
        speech.say("Obstacle detection warming up. Route will start when it is ready.", .nav, ttl: 8)
        watch.send(status: "Obstacle detection warming up", distanceM: -1)
        logger.event("route_readiness", ["state": "warming", "timeout_s": DepthReadiness.standardConfiguration.timeout,
                                           "required_frames": DepthReadiness.standardConfiguration.requiredFrames])

        // Turning two-camera mode off is serialized. Begin the frame clock only after that chain
        // drains so pre-transition reports cannot be mistaken for recovery evidence. This separate
        // request timer also bounds a camera operation that never drains; the route must not wait
        // forever before the pure gate has even received its first frame.
        let cameraWork = bothCamerasWork
        routeReadinessTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(DepthReadiness.standardConfiguration.timeout + 2.0))
            guard !Task.isCancelled,
                  let self,
                  self.routeStartGeneration == generation,
                  self.pendingRouteStart != nil else { return }
            // If the camera chain has not started the gate yet, poll is a no-op; the shared
            // failure path still reports the bounded request timeout explicitly.
            self.depth.pollReadiness(at: ProcessInfo.processInfo.systemUptime)
            if self.pendingRouteStart != nil { self.failQueuedRouteStart() }
        }
        routeReadinessTask = Task { @MainActor [weak self] in
            if let cameraWork { await cameraWork.value }
            guard let self,
                  self.routeStartGeneration == generation,
                  self.pendingRouteStart != nil else { return }
            self.depth.beginReadiness(at: ProcessInfo.processInfo.systemUptime)
            // Poll rather than sleeping until one fixed deadline. An interruption, pause, or
            // session reconfiguration resets only the consecutive-frame run; polling lets the
            // pure gate retain one bounded five-second deadline while the camera recovers. The
            // 100 ms cadence is only a main-actor clock check and adds no delay to the frame-driven
            // ready transition.
            while !Task.isCancelled,
                  self.routeStartGeneration == generation,
                  self.pendingRouteStart != nil {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled,
                      self.routeStartGeneration == generation,
                      self.pendingRouteStart != nil else { return }
                self.depth.pollReadiness(at: ProcessInfo.processInfo.systemUptime)
                if self.depth.readinessState != .warming { return }
            }
        }
    }

    /// Respond to a readiness transition from the depth adapter (`depth.onReadinessChanged`, wired
    /// in `start()`; main actor). Ignored unless a route is queued. `.ready` clears the queue and
    /// both tasks, logs `route_readiness {state: ready}` and calls `startRouteNow`; `.timedOut`
    /// goes to `failQueuedRouteStart`; `.idle` / `.warming` change nothing.
    private func depthReadinessChanged(_ state: DepthReadinessState) {
        guard pendingRouteStart != nil else { return }
        switch state {
        case .ready:
            guard let pending = pendingRouteStart else { return }
            pendingRouteStart = nil
            routeStartWaiting = false
            routeReadinessTask?.cancel()
            routeReadinessTask = nil
            routeReadinessTimeoutTask?.cancel()
            routeReadinessTimeoutTask = nil
            routeStartStatus = nil
            depth.cancelReadiness()
            logger.event("route_readiness", ["state": "ready"])
            startRouteNow(pending.route, announce: pending.announce)
        case .timedOut:
            failQueuedRouteStart()
        case .idle, .warming:
            break
        }
    }

    /// Gracefully fall back to GPS navigation if depth readiness times out.
    /// Never leaves the walker stranded (AGENTS.md: "Never trade guidance away for a stricter check —
    /// a refused camera warns loudly but still guides").
    /// Speaks "Obstacle detection warming up. Guiding with GPS." (.safety, 15 s TTL), logs
    /// `route_readiness {state: timed_out_fallback_gps}` and starts GPS guidance immediately.
    /// Callers: `depthReadinessChanged(.timedOut)`, `routeReadinessTimeoutTask`.
    private func failQueuedRouteStart() {
        guard let pending = pendingRouteStart else { return }
        routeStartGeneration &+= 1
        pendingRouteStart = nil
        routeStartWaiting = false
        routeReadinessTask?.cancel()
        routeReadinessTask = nil
        routeReadinessTimeoutTask?.cancel()
        routeReadinessTimeoutTask = nil
        depth.cancelReadiness()
<<<<<<< HEAD
        routeStartStatus = nil
        routeError = nil
        speech.say("Obstacle detection warming up. Guiding with GPS.", .safety, ttl: 15)
        watch.send(status: "Guiding with GPS", distanceM: -1)
        logger.event("route_readiness", ["state": "timed_out_fallback_gps"])
        startRouteNow(pending.route, announce: pending.announce)
=======
        finishSensorModeRoute()
        routeStartStatus = "Obstacle detection is not ready. Route did not start."
        routeError = "Obstacle detection is not ready"
        speech.say("Obstacle detection is not ready. Route did not start. Check the camera and reopen OpenCane.",
                   .safety, ttl: 30)
        watch.send(status: "Obstacle detection not ready", distanceM: -1)
        logger.event("route_readiness", ["state": "timed_out"])
>>>>>>> 21b1717 (Step 29: interlock AR sensor mode restarts during routes)
    }

    /// Cancel a queued route-start request. Called by Stop and by a newer MapKit/destination
    /// request so an older route can never auto-start after the user has changed their mind.
    /// Silent (the caller speaks); no-op when nothing is queued; logs
    /// `route_readiness {state: cancelled}`. Callers: `stopRoute`, `startDemoRoute`,
    /// `buildRoute`, `cancelRouteStart`.
    private func cancelPendingRouteStart() {
        let hadPendingRoute = pendingRouteStart != nil
        guard hadPendingRoute || routeReadinessTask != nil else { return }
        // A superseding destination or demo-route tap must not leave the old warm-up sentence in
        // SpeechQueue. The explicit phone Cancel action also stops the queue before calling here;
        // this covers the internal replacement path as well.
        if hadPendingRoute { speech.stopAll() }
        routeStartGeneration &+= 1
        pendingRouteStart = nil
        routeStartWaiting = false
        routeReadinessTask?.cancel()
        routeReadinessTask = nil
        routeReadinessTimeoutTask?.cancel()
        routeReadinessTimeoutTask = nil
        routeStartStatus = nil
        depth.cancelReadiness()
<<<<<<< HEAD
        location.setNavigating(false)
=======
        finishSensorModeRoute()
>>>>>>> 21b1717 (Step 29: interlock AR sensor mode restarts during routes)
        logger.event("route_readiness", ["state": "cancelled"])
    }

    /// Cancel a queued route-start request from the phone UI. A pending request has not started
    /// guidance, so it needs a distinct confirmation line rather than `stopRoute`'s "Route
    /// stopped." Caller: GuideCard's visible cancel button while depth is warming.
    func cancelRouteStart() {
        guard routeStartWaiting else { return }
        // Remove the queued warm-up line before confirming cancellation; otherwise the walker
        // could hear "Route will start" after the button has already canceled it.
        speech.stopAll()
        cancelPendingRouteStart()
        routeStartStatus = "Route start canceled."
        speech.say("Route start canceled.", .nav, ttl: 4)
        watch.send(status: "Route start canceled", distanceM: -1)
    }

    /// The existing route-start effects, reached only after the interlock has cleared (or through
    /// the intentional no-LiDAR / camera-denied degraded path).
    ///
    /// Order matters: clear the waiting state → speak `announce` (20 s TTL) → camera-denied warning
    /// again → reset ground-hazard policy, lock warning and `lastGroundHazard` → set
    /// `speech.routeLines` and prefetch route lines + `commonLines` + the intro → GPS → `nav.start`
    /// (speaks the intro) → beacon, AirPods head tracking and (if on) face head pose → recenter
    /// pending → fresh `CueSpeechPolicy` → ticker → trip tracker (Motion + HealthKit prompts
    /// appear here, by design) → Live Activity → log `route {action: start, name, waypoints,
    /// headphones, watch}` → watch status → channel announcements (queued after the intro) → the
    /// `describeEveryWaypoint` hook.
    /// - Parameters:
    ///   - route: the route to guide along.
    ///   - announce: optional "Walking to …" line (see `beginRoute`).
    /// Callers: `beginRoute` (degraded paths), `depthReadinessChanged(.ready)`.
    private func startRouteNow(_ route: Route, announce: String? = nil) {
        markSensorModeRouteStarted()
        // A previous route's AR failure must not make the first trusted frame of this new route
        // speak a stale recovery line while the route intro is still being delivered.
        depthSafetyDegraded = false
        routeStartWaiting = false
        routeStartStatus = nil
        routeError = nil
        if let announce {
            // 20 s: it queues behind "Finding a route…" and must not expire before it plays.
            speech.say(announce, .nav, ttl: 20)
            logger.event("speech", ["text": announce, "priority": "nav"])
        }
        // Camera refused: warn loudly (and keep the error on screen: it is set after the clear
        // above), but still guide. GPS, the beacon and the watch work without the camera, and a
        // blind walker is better off with guidance and no obstacle cues than with nothing.
        announceCameraDenied()
        groundPolicy.reset()
        lockWarningGiven = false
        lastGroundHazard = nil               // a new route must not show the last route's drop-off
        // Every waypoint line and the route intro, synthesized now so they play instantly. The
        // route's own lines go first because waypoint 1 is needed in seconds; whatever is left of
        // `speech.backgroundLines` (the warning set) follows on the same two-request budget.
        // Standing for the whole walk, not just this batch: `prefetch` cancels the batch before it,
        // and every obstacle warning that misses the cache starts a new one. Without this the first
        // warning the walker hears would throw away every waypoint line still unsynthesized, and the
        // next turn instruction would arrive late, in the wrong voice, at a street corner.
        speech.routeLines = route.waypoints.map(\.say)
        speech.prefetch(route.waypoints.map(\.say) + Self.commonLines
                        + ["Route started. \(route.name). First: \(route.waypoints.first?.say ?? "")"])
        location.start()
        location.setNavigating(true)
        nav.start(route)
        activeRouteName = route.name
        fallWatcher.reset()
        family.tripStarted(destination: route.name,
                           lat: location.fix?.coordinate.latitude,
                           lng: location.fix?.coordinate.longitude)
        // New walk: forget the breadcrumb / obstacle rate limits so the first fix goes out
        // promptly. Battery arming deliberately survives (FamilyAlertPolicy.reset).
        family.reset()
        beacon.start()
        head.start()
        if faceHeadTrackingEnabled { faceHead.start() }   // the no-AirPods head source
        recenterPending = true               // first straight stretch zeroes the head reference
        straightWalk.reset()
        cueSpeech = CueSpeechPolicy()
        startTicker()
        trip.start()
        lastNavKind = "straight"
        liveActivity.start(routeName: route.name, instruction: nav.instruction, distanceM: nav.distanceToNext ?? 0)
        if let err = liveActivity.lastError {
            logger.event("live_activity", ["action": "error", "error": err])
        } else {
            logger.event("live_activity", ["action": "start", "active": liveActivity.isActive])
        }
        logger.event("route", ["action": "start", "name": route.name, "waypoints": route.waypoints.count,
                               "headphones": audioRoute.outputName, "watch": watch.isReachable])
        // Open the cloud walk and upload the waypoints. Everything the logger queues from here on
        // is stamped with this trip, so `trip_summary` reads as one walk rather than loose lines.
        cloud.beginTrip(destination: route.name, cueLevel: cueLevel.rawValue,
                        cuePlace: cuePlace.rawValue, batteryPct: batteryPercent,
                        logFileName: logger.fileName, start: location.fix)
        // `bundled` = the hand-recorded campus demo route (the only route with a fixed waypoint
        // `id` sequence and 12 m turn fences); anything else came from MapKit walking directions.
        cloud.uploadRoute(route, source: Self.bundledRouteName == route.name ? "bundled" : "mapkit")
        pushStatusToWatch()
        announceChannels()
        if Self.describeEveryWaypoint { describeScene() }   // the start (ISR) is a corner too
    }

    // MARK: Cloud mirror

    /// Register the cane, push everything the phone already holds, and start mirroring the log.
    ///
    /// Called once from `start()`, after `logger.start()` so the `session` record is the first
    /// line the cloud sees too. Every step is a no-op when `Secrets.plist` has no Supabase keys,
    /// which is what makes the cloud genuinely optional: with no project configured OpenCane
    /// behaves exactly as it did before step 45.
    ///
    /// ⚠ Order matters. The `onRecord` hook goes on *before* the registration RPC is awaited, so
    /// the lines logged during launch are queued rather than lost; `CloudSync` stamps the walker
    /// id onto them when registration lands.
    private func startCloudMirror() {
        guard cloud.isConfigured else { return }
        // Every line the trip log writes, mirrored. Cheap and synchronous — it appends to a queue.
        logger.onRecord = { [weak self] kind, t, fields in
            self?.cloud.logEvent(kind: kind, tSeconds: t, fields: fields)
        }
        // Every family alert and what the webhook answered. ⚠ `accepted` means the bot STARTED a
        // run, not that anyone was emailed — `delivery_status` is worded that way in the schema
        // too, and no view may "improve" it into "family notified".
        family.onDelivered = { [weak self] event, result in
            switch result {
            case .accepted:
                self?.cloud.recordAlert(event, status: "posted", httpStatus: 200, error: nil)
            case .rejected(let status, let body):
                self?.cloud.recordAlert(event, status: "failed", httpStatus: status,
                                        error: body.isEmpty ? "rejected" : body)
            case .failed(let message):
                self?.cloud.recordAlert(event, status: "failed", httpStatus: nil, error: message)
            case .notConfigured:
                break            // nothing was sent, so there is no alert to record
            }
        }
        // The Medical ID and the day's mobility numbers, on every edit / pedometer refresh.
        medicalProfile.onProfileSaved = { [weak self] profile in
            self?.cloud.saveMedicalProfile(profile)
        }
        medicalProfile.onMobilityRefreshed = { [weak self] stats in
            self?.cloud.saveMobility(stats)
        }
        cloud.start(CloudSync.RegistrationFacts(
            displayName: medicalProfile.profile.name,
            caneID: family.caneID ?? "opencane-01",
            hasLiDAR: DepthEngine.supportsMesh,
            watchPaired: watch.isPaired,
            airPodsPaired: audioRoute.headphonesConnected))
        // What the phone already holds, pushed once the registration returns ids. The 2 s wait is
        // the registration round trip; a failure just leaves the next settings write to carry it.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.cloud.isRegistered else { return }
            self.cloud.saveSettings(self.cloudSettings)
            self.cloud.saveMedicalProfile(self.medicalProfile.profile)
            self.cloud.saveMobility(self.medicalProfile.mobilityStats)
            self.cloud.saveFamilyContacts(self.familyEmails, registered: self.familyContactsRegistered)
            self.cloud.recordLaunch(mode: Settings.launchMode,
                                    clearedKeys: LaunchRecovery.optionalFeatureKeys)
        }
    }

    /// Refresh the `devices` row's hardware facts. The watch and the AirPods come and go mid-session
    /// and which cues are possible depends on them, so the row must not freeze at launch values.
    /// Callers: `start()`, `watch.onStateChange`, the audio-route change. A no-op before the cane
    /// has registered, and before that the launch values are already on their way.
    private func recordDeviceCapabilities() {
        cloud.updateDeviceFacts(CloudSync.RegistrationFacts(
            displayName: medicalProfile.profile.name,
            caneID: family.caneID ?? "opencane-01",
            hasLiDAR: DepthEngine.supportsMesh,
            watchPaired: watch.isPaired,
            airPodsPaired: audioRoute.headphonesConnected))
    }

    /// When location access is refused: shows and speaks how to fix it, returns true (the caller
    /// stops). Shared by `beginRoute` and `buildRoute` — the latter so a typed or spoken
    /// destination fails now rather than after a 15 s wait for a fix that never comes (Muse H2,
    /// review round 5). Not rate-limited: each attempt is a fresh request that deserves an answer.
    private func announceLocationDenied() -> Bool {
        guard location.authorizationDenied else { return false }
        routeError = "Location is off for OpenCane"
        speech.say("Location access is off. Turn on Location for OpenCane in Settings to navigate.", .nav, ttl: 20)
        return true
    }

    /// Sends the current instruction + distance to the watch. `-1` means "no distance" (the watch
    /// maps it to nil). `PhoneWatchLink` drops same-text updates that moved < 5 m.
    /// Callers: every GPS fix while navigating, waypoint advance, arrival, `stopRoute`,
    /// `startRouteNow`.
    private func pushStatusToWatch() {
        watch.send(status: nav.instruction, distanceM: nav.distanceToNext ?? -1)
    }

    // MARK: Watch commands

    /// Next / Describe / Recenter / Repeat from the wrist (buttons and the crown "Next" gesture).
    /// Installed as `watch.onCommand` in `start()`; logs a `watch` event first.
    /// ⚠ `WatchToPhone` lives in CaneKitLogic (WatchMessage.swift): adding a case requires
    /// updating this `switch` and re-running `WatchMessageTests.watchToPhoneRoundTrips`.
    private func handleWatchCommand(_ cmd: WatchToPhone) {
        logger.event("watch", ["command": cmd.rawValue])
        switch cmd {
        case .nextWaypoint: nextWaypoint()
        case .describe: describeScene()
        case .recenter: recenter()
        case .repeatLast: repeatInstruction()
        }
    }

    /// Debug buttons on the Watch card (`WatchCard`).
    /// Sends a raw `NavCue` tap to the watch and logs `watch {test}`. No phone haptic, no speech.
    func watchTest(_ cue: NavCue) {
        watch.send(nav: cue)
        logger.event("watch", ["test": cue.rawValue])
    }

    /// Debug button (`HapticsCard` "Speech test"): prove the audio route (AirPods) and the
    /// queue/interrupt behaviour. Queues a `.scene` line then an `.obstacle` line; the obstacle
    /// line should interrupt it, and (Step 37) the scene line should resume from its clause after
    /// the 0.35 s cross-band pause.
    func speechTest() {
        speech.say("Scene test: sidewalk ahead, bike rack at ten o'clock, two meters.", .scene)
        speech.say("One meter ahead, door.", .obstacle)
    }


    /// Camera Control / volume press reached the app while ARKit owns the camera.
    /// Logged (`describe {source: cameraControl}` in the trip log is the step-2 spike readout),
    /// then treated like "Where am I" (so one press writes two `describe` records).
    /// Caller: `ContentView`'s `CameraControlInteraction` background.
    func cameraControlPressed() {
        logger.event("describe", ["source": "cameraControl"])
        describeScene()
    }

    // MARK: Private

    /// Pushes `portraitMode` / `mirrorLeftRight` into the depth engine's lane remap (with
    /// `groundHazardsEnabled`, which turns the ground sampler on in the processor), and the
    /// mirror into `sceneContext` as well: the camera image is never mirrored, so a mirrored
    /// mount has to swap left and right in *speech* (`PeopleAhead.bearing`), exactly as the lane
    /// grid swaps them in the haptics.
    /// Callers: `init` and the `didSet`s of `portraitMode`, `mirrorLeftRight`, `groundHazardsEnabled`.
    private func pushDepthSettings() {
        depth.apply(portrait: portraitMode, mirror: mirrorLeftRight, groundHazards: groundHazardsEnabled)
        sceneContext.setMirrored(mirrorLeftRight)
    }

    /// Enables battery monitoring, reads the initial values and subscribes to thermal / battery
    /// notifications for the process lifetime. Called once from `start()`. The observers capture
    /// `[weak self]` and are never removed (the model lives as long as the process).
    private func observeThermalAndBattery() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        updateBattery()
        updateThermal()
        // `.main` queue + assumeIsolated: the closures are @Sendable but provably on main.
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateThermal() }
        }
        batteryObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateBattery() }
        }
    }

    /// Maps the thermal state to `thermalName` and applies the cheapest downgrade: mesh
    /// classification off at `.serious` or `.critical` (obstacle names then go silent; the lane
    /// haptics keep running), and the camera hazard scanner paused (`hazards.paused`: signs and
    /// the hazard watch; the live view shows "phone is hot"). LiDAR ground hazards are not paused.
    /// The spoken notice is gated on `started`, which `start()` sets before its first
    /// `observeThermalAndBattery()` read — so a phone that launches hot says so once, at launch.
    /// Callers: `observeThermalAndBattery` (initial read and every thermal notification).
    private func updateThermal() {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermalName = "nominal"
        case .fair: thermalName = "fair"
        case .serious: thermalName = "serious"
        case .critical: thermalName = "critical"
        @unknown default: thermalName = "unknown"
        }
        // Step 2 already honours the cheapest downgrade: no mesh at .serious or worse.
        let hot = ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
        let desiredMesh = !hot
        if desiredMesh != depth.meshEnabled {
            let decision = sensorModeInterlock.request(.meshClassification, source: .thermal)
            switch decision {
            case .allowRestart:
                depth.setMeshClassification(desiredMesh)
            case .deferUntilRouteEnds:
                // Mesh lookup is a non-safety enhancement. Turn it off in the processor now to
                // reduce heat, but do not pause/re-run ARKit while the walker is guided.
                depth.setMeshClassification(desiredMesh, restartSession: false)
                logger.event("sensor_mode", ["mode": SensorMode.meshClassification.rawValue,
                                              "action": "thermal_deferred",
                                              "desired": desiredMesh,
                                              "phase": sensorModeInterlock.phase.rawValue])
            case .refuseWhileStarting, .refuseWhileNavigating, .refuseWhileFinishing:
                // Thermal requests are never refused; this defensive branch preserves the
                // cheapest downgrade if the policy gains another phase in the future.
                depth.setMeshClassification(desiredMesh, restartSession: false)
            }
        }
        // Say it once per transition: names going silent without a word is confusing (Muse L5).
        hazards.paused = hot                 // camera extras off while hot; lanes + haptics stay
        if hot, !wasHot, started { speech.say("Phone is hot. Door and wall names and sign reading paused.", .nav, ttl: 10) }
        wasHot = hot
    }

    /// Adds one address to the family list.
    /// - Returns: nil on success, or a spoken-style reason the entry was refused. The reason is
    ///   returned rather than swallowed because a typo here costs a real alert later.
    @discardableResult
    func addFamilyEmail(_ raw: String) -> String? {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !address.isEmpty else { return "Type an email address first." }
        guard FamilyContacts.isValid(address) else { return "That does not look like an email address." }
        guard !familyEmails.contains(address) else { return "That address is already on the list." }
        guard familyEmails.count < FamilyContacts.maxContacts else {
            return "The list is full at \(FamilyContacts.maxContacts) addresses."
        }
        setFamilyEmails(familyEmails + [address])
        return nil
    }

    /// Removes one address. Leaving the list empty is allowed: an empty registration is how a
    /// walker tells the bot to stop emailing anyone.
    func removeFamilyEmail(_ address: String) {
        setFamilyEmails(familyEmails.filter { $0 != address })
    }

    /// Stores the normalised list and marks it as needing a Save.
    private func setFamilyEmails(_ list: [String]) {
        let normalized = FamilyContacts.normalize(list)
        guard normalized != familyEmails else { return }
        familyEmails = normalized
        Settings.set(familyEmails, "familyContactEmails")
        familyContactsNeedSave = true
    }

    /// Registers the current list with the Grok Bot routine and speaks the answer.
    ///
    /// `send_test` is set only while `familyContactsRegistered` is false, so the bot emails its
    /// confirmation once, on the first list that it accepts — not on every later edit.
    /// The flag is set only on acceptance, so a failed first Save still tests next time.
    ///
    /// ⚠ Says the bot **accepted** the list. It never says an email was sent: the bot sends it,
    /// afterwards, and the app has no way to know that it worked.
    func saveFamilyContacts() async {
        guard allowWebhookAction("save_contacts") else { return }
        let sendTest = !familyContactsRegistered
        let result = await family.registerContacts(familyEmails, sendTest: sendTest)
        let line: String
        switch result {
        case .accepted:
            familyContactsNeedSave = false
            if sendTest {
                familyContactsRegistered = true
                Settings.set(true, "familyContactsRegistered")
            }
            let count = familyEmails.count
            line = count == 0
                ? "Family list cleared. Grok Bot accepted it."
                : "Grok Bot accepted \(count) address\(count == 1 ? "" : "es")."
                  + (sendTest ? " Each one gets a confirmation email." : "")
        default:
            line = result.summary
        }
        speech.say(line, .nav, ttl: 10)
        // ⚠ The ONLY path by which a family address reaches the cloud (`save_family_contacts`).
        // Never put one in a trip-log payload or an alert row — see `CloudSync`.
        cloud.saveFamilyContacts(familyEmails, registered: familyContactsRegistered)
        logger.event("family_contacts", ["count": familyEmails.count, "send_test": sendTest,
                                         "result": result.summary])
    }

    /// Spam guard for the buttons that POST to the Grok Bot webhook.
    ///
    /// Each tap starts a *bot run*, and Save can email the whole family, so a held finger would
    /// burn the routine's quota and mail everyone repeatedly. `ActionRateLimit` (CaneKitLogic)
    /// spaces each action 10 s apart.
    ///
    /// ⚠ A refused tap **says so out loud** rather than doing nothing: a button that silently
    /// ignores you reads as a broken button, and the walker cannot see a greyed-out control.
    /// - Returns: true when the action may run; false when it was refused (and already announced).
    private func allowWebhookAction(_ action: String) -> Bool {
        let now = Date().timeIntervalSinceReferenceDate
        if actionLimit.allow(action, now: now) { return true }
        let wait = actionLimit.secondsRemaining(action, now: now)
        speech.say("Just a moment. Try again in \(wait) second\(wait == 1 ? "" : "s").", .nav, ttl: 4)
        family.noteThrottled(secondsRemaining: wait)
        return false
    }

    /// Runs the fall watcher only when it can do something: both switches on.
    ///
    /// Not gated on `started` — a cane can go over while the walker is standing still with the app
    /// open and no route running, which is exactly when nobody else would notice.
    private func applyFallWatcher() {
        if fallDetectionEnabled && familyAlertsEnabled {
            fallWatcher.portraitMount = portraitMode
            fallWatcher.start()
        } else {
            fallWatcher.stop()
        }
    }

    /// The cane went over and stayed down: tell the family, and say so out loud in case the walker
    /// is fine and wants to cancel by picking it up (the detector re-arms when it is upright).
    private func fallDetected(_ fall: Fall) {
        family.fall(lat: location.fix?.coordinate.latitude,
                    lng: location.fix?.coordinate.longitude,
                    note: "Possible fall: the cane went over and stayed down.")
        speech.say("Possible fall detected. Telling your family.", .nav, ttl: 10)
        logger.event("fall", ["impact_g": fall.impactG, "rest_tilt": fall.restTiltDegrees,
                              "ar_t": fall.at])
    }

    /// The vision model described a weapon or an attacker ahead.
    ///
    /// The walker is told as well as the family. It may be a false positive — but a blind person
    /// walking toward something the camera thinks is a knife should hear about it, and the wording
    /// quotes the camera rather than asserting it.
    private func threatSeen(_ sighting: ThreatSighting) {
        family.threat(sighting, lat: location.fix?.coordinate.latitude,
                      lng: location.fix?.coordinate.longitude,
                      now: Date().timeIntervalSinceReferenceDate)
        speech.say("Careful. The camera described a possible \(sighting.term) ahead.", .obstacle, ttl: 8)
        logger.event("threat", ["term": sighting.term, "text": sighting.text])
    }

    /// Everything the phone knows that a family member would want with an alert: where the walker
    /// was going, what they were being told, how fast, how much battery, how hot, what the cane
    /// had just found.
    ///
    /// Read synchronously at the moment an event fires (`FamilyAlerts.prepare`), never later, so
    /// it describes the detection rather than whenever the network got around to it.
    var familyContext: AlertContext {
        var context = AlertContext()
        context.navigating = nav.isNavigating
        context.destination = activeRouteName
        context.instruction = nav.isNavigating ? nav.instruction : nil
        context.distanceToNextM = nav.distanceToNext.map(Double.init)
        context.batteryPct = batteryPercent
        context.thermalState = thermalName
        context.speedMps = location.fix.map { Double($0.speed) }
        context.headingDeg = location.heading
        context.activeCue = activeCue.rawValue
        context.lastGroundHazard = lastGroundHazard
        context.hasFix = location.fix != nil
        return context
    }

    /// Debug "Send test event": posts one sample `fall` event to the Grok Bot routine and speaks
    /// what came back, so the chain can be checked before a walk without looking at the screen.
    ///
    /// Works even while `familyAlertsEnabled` is off — checking the wiring is exactly what a
    /// family member does *before* switching it on.
    ///
    /// ⚠ It reports that the bot **accepted** the event. It never says family was texted: the bot
    /// decides that later, and claiming it here would be a lie the walker might rely on.
    func sendFamilyTestEvent() async {
        guard allowWebhookAction("test_event") else { return }
        let line = await family.sendTestEvent(lat: location.fix?.coordinate.latitude,
                                              lng: location.fix?.coordinate.longitude)
        speech.say(line, .nav, ttl: 10)
        logger.event("family_test", ["result": line])
    }

    /// `batteryLevel` is 0…1, or negative when unknown (simulator) → `batteryPercent` 0–100 / -1.
    /// Callers: `observeThermalAndBattery` (initial read and every battery-level notification).
    private func updateBattery() {
        let level = UIDevice.current.batteryLevel
        batteryPercent = level < 0 ? -1 : Int((level * 100).rounded())
        // Once per discharge; the policy re-arms only after a real recharge.
        family.lowBattery(pct: batteryPercent)
    }
}

/// Thin UserDefaults wrapper so settings stay one-liners above.
/// Keys are the AppModel property names; main-actor by the target default.
///
/// Persisted keys today: `portraitMode`, `mirrorLeftRight`, `hapticsSilenced`, `loggingEnabled`,
/// `obstacleNamesEnabled`, `cueLevel`, `cuePlace` (String raw values), `beaconEnabled`,
/// `fallbackToWatch`, `groundHazardsEnabled`, `signsEnabled`, `hazardWatchEnabled`,
/// `namePeopleEnabled`, `highFrameRateCamera`. Deliberately NOT persisted: `liveViewEnabled`,
/// `bothCamerasEnabled`, `faceHeadTrackingEnabled`, `dangerSoundsEnabled`, `nodToTalkEnabled`,
/// `torchEnabled`. The launch marker is a file, not a key (see `markerURL`).
/// Tests: `LaunchRecoveryTests` (the recovery rule and its key list).
enum Settings {

    /// How this launch is running — and the side effect that makes it true.
    ///
    /// Reading this the first time is what performs the crash-loop recovery: it looks for the
    /// marker the previous launch should have removed and, when the marker is still there, clears
    /// every key in `LaunchRecovery.optionalFeatureKeys` before any of them can be read.
    ///
    /// ⚠ It has to run **before the first setting is read**, because a stored property's default
    /// value is evaluated before `AppModel.init`'s body ever runs — by the time the body could
    /// call anything, `groundHazardsEnabled` and friends already hold the values that killed the
    /// last launch. `bool(_:default:)` therefore forces it, and Swift's `static let` gives that
    /// exactly-once, thread-safe semantics for free.
    ///
    /// Why a recovery at all: on 2026-09-12 a persisted optional feature (front-camera head
    /// tracking) made the app die ~2–4 s into launch, on every launch, with the switch that would
    /// have turned it off on a screen the app never reached. `LaunchRecovery` (CaneKitLogic, with
    /// the trip-log evidence and the tests) is the rule that no optional feature may ever hold the
    /// app's start hostage again.
    ///
    /// ⚠ Reading this only *reads and clears*. Arming the marker for this launch is
    /// `armLaunchMarker()`, called from `AppModel.start()` — deliberately not from here (Muse M1).
    /// A process that builds an `AppModel` and never starts its engines (an App Intent waking the
    /// app on the lock screen, an XCUITest that is torn down, a SwiftUI preview) would otherwise
    /// arm a marker nothing ever clears, and the next real launch would throw away the walker's
    /// settings for a crash that never happened. Only a launch that actually reached `start()` —
    /// the launch that can be killed by a feature — arms it.
    static let launchMode: LaunchMode = {
        let defaults = UserDefaults.standard
        // Absent marker = the previous launch removed it = the previous launch was healthy.
        let previousCompleted = !FileManager.default.fileExists(atPath: markerURL.path)
        let mode = LaunchRecovery.mode(previousLaunchCompleted: previousCompleted)
        if mode == .recovered {
            // Remove rather than write `false`: the walker gets the built-in default back
            // (sign reading on, drop-offs off), not a value the app invented.
            for key in LaunchRecovery.optionalFeatureKeys { defaults.removeObject(forKey: key) }
        }
        return mode
    }()

    /// Where the "a launch is in progress" marker lives: an empty file in Application Support.
    ///
    /// ⚠ A file, not a `UserDefaults` key (see `LaunchRecovery.markerName`): the marker has to
    /// survive a process that dies two seconds after writing it, and `UserDefaults` only promises
    /// to flush "at appropriate intervals". Application Support rather than Caches (the system may
    /// purge Caches, which would silently disarm the guard) and rather than Documents (that folder
    /// is the walker's, and the trip logs they AirDrop live there).
    private static let markerURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL.documentsDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(LaunchRecovery.markerName)
    }()

    /// This launch has begun starting engines: if it dies before it is healthy, the next one
    /// recovers. Caller: `AppModel.start()`, before anything is started.
    static func armLaunchMarker() {
        FileManager.default.createFile(atPath: markerURL.path, contents: nil)
    }

    /// This launch got far enough to be trusted: drop the marker so the next launch is normal.
    /// Called from `AppModel.observeLaunchHealth()` (armed by `start()`): after
    /// `LaunchRecovery.healthySeconds` (10 s), and at once when the walker deliberately backgrounds
    /// the app (an app someone is using is an app that started). Idempotent (`try?` remove).
    static func markLaunchHealthy() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    /// Called after every persisted write, so the cloud copy of the settings never drifts from
    /// the phone's. Installed once by `AppModel.init` (`self.cloud.saveSettings(…)`, debounced
    /// there); nil in a preview, a UI test or any process that never builds an `AppModel`.
    ///
    /// ⚠ A hook on `set`, not eighteen calls in eighteen `didSet`s, and deliberately so: a setting
    /// added later is mirrored with no extra wiring, and there is no way to add a persisted key
    /// that silently fails to sync. Keep it cheap — `set` runs on the main actor from a `didSet`.
    static var onChange: (() -> Void)?

    /// Stored Bool for `key`, or `d` when the key has never been written (not `false`).
    static func bool(_ key: String, default d: Bool) -> Bool {
        _ = launchMode              // ⚠ forces the recovery above before any setting is read
        return UserDefaults.standard.object(forKey: key) as? Bool ?? d
    }
    /// Persists `value` under `key` in `UserDefaults.standard`, then tells `onChange`.
    static func set(_ value: Bool, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        onChange?()
    }

    /// Stored String for `key` (a persisted enum's raw value), or `d` when never written.
    static func string(_ key: String, default d: String) -> String {
        _ = launchMode              // ⚠ forces the recovery above before any setting is read
        return UserDefaults.standard.string(forKey: key) ?? d
    }
    /// Persists `value` under `key` in `UserDefaults.standard`, then tells `onChange`.
    static func set(_ value: String, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        onChange?()
    }

    /// String list for `key`, or `d`. Anything that is not a `[String]` (a key written by an
    /// older build, or hand-edited) reads as the default rather than crashing the launch.
    static func strings(_ key: String, default d: [String]) -> [String] {
        _ = launchMode              // ⚠ same ordering rule as `bool`
        return UserDefaults.standard.object(forKey: key) as? [String] ?? d
    }
    /// Persists a string list under `key`, then tells `onChange`.
    static func set(_ value: [String], _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        onChange?()
    }
}
