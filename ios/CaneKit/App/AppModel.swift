//
//  AppModel.swift
//  CaneKit
//
//  Purpose: central owner of every engine and of the user settings, and the glue between them:
//  the depth "cue router" (LaneReport → haptics / watch / speech / log), navigation and
//  headphone-route wiring, the route start/stop sequence, watch commands, auto-recenter of the
//  AirPods head reference, and thermal/battery observation.
//
//  Owner: `CaneKitApp` creates exactly one instance (`@State`) for the process lifetime and
//  injects it into SwiftUI with `.environment(model)`; App Intents reach it via `AppModel.shared`.
//  Module `app-core` in docs/CODE_REFERENCE.md.
//
//  Threading / isolation: `@MainActor` (the project default, SWIFT_DEFAULT_ACTOR_ISOLATION =
//  MainActor). Engines that run off-main (DepthEngine's ARKit queue, CoreLocation) publish
//  Sendable value types (`LaneReport`, `GeoFix`) back through closures installed here, which are
//  always invoked on the main actor. `MainActor.assumeIsolated` is used only inside
//  NotificationCenter observers registered with `queue: .main` (AGENTS.md hard rule 1).
//
//  Key invariants:
//    · `start()` runs once; its order (audio session → haptics → ARKit) is load-bearing.
//    · Cue-router timing uses the ARKit clock (`report.timestamp`), never wall time.
//    · The `.head` cue is never suppressed (AGENTS.md hard rule 8); "Head height." is spoken
//      once per obstacle episode, never every second.
//    · Decisions with numbers in them live in CaneKitLogic (CueDecider, CueSpeechPolicy,
//      StraightWalkDetector); this class only owns state, timing and effects (hard rule 3).
//    · `commonLines` must stay byte-identical to the strings spoken elsewhere (prefetch cache).
//
//  Engines by step:
//    step 2 DepthEngine · step 3 HapticPlayer · step 4 SpeechQueue/ObstacleNamer ·
//    step 5 PhoneWatchLink · step 6 NavigationEngine · step 7 BeaconEngine ·
//    step 8 SceneDescriber · step 9 TripTracker/LiveActivity/ThermalWatchdog.
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
    /// GPS + compass (step 6).
    let location = LocationService()
    /// Waypoint navigation (step 6).
    let nav = NavigationEngine()
    /// Spatial-audio beacon (step 7).
    let beacon = BeaconEngine()
    /// AirPods head yaw (step 7).
    let head = HeadPoseTracker()
    /// Headphones present? (beacon gate, spoken connect/disconnect lines).
    let audioRoute = AudioRouteMonitor()
    /// "Where am I" (step 8). Built in `init` because it needs `depth.processor` and `speech`.
    let describer: SceneDescriber
    /// Elapsed / distance / steps for the arrival card (step 9).
    let trip = TripTracker()
    /// Dynamic Island / lock screen (step 9).
    let liveActivity = LiveActivityController()
    /// LiDAR facts handed to the on-device describer ("Obstacle ahead at 1.4 meters.").
    let sceneContext: SceneContext
    /// Camera hazards: signs (on-device) + hazard watch (cloud → on-device, or on-device).
    let hazards: HazardScanner
    /// Hazard map: every announced hazard with GPS + photo → Documents/hazards/*.geojson.
    let hazardLog = HazardLog()
    /// Last LiDAR ground hazard spoken ("Drop-off ahead, two meters."), for the Hazards card.
    private(set) var lastGroundHazard: String?
    /// When a confirmed ground hazard is worth saying again (CaneKitLogic, HazardTests).
    @ObservationIgnored private var groundPolicy = GroundHazardPolicy()

    /// Route picker state: the destination text typed in the route field (read/write from the UI).
    var destinationQuery = ""
    /// Last route-building failure shown under the route picker; nil when there is none.
    /// "Type a destination first" is also an accessibility/test string (AGENTS.md hard rule 9).
    private(set) var routeError: String?
    /// True while a MapKit build (`buildRoute`: typed field, Siri, "Navigate to CIF from here")
    /// waits for a fix and MapKit directions (UI shows progress, Go / CIF buttons disabled).
    private(set) var isBuildingRoute = false

    /// Decides which cue fires from each lane report (pure logic, CaneKitLogic).
    /// ⚠ Its timing contract is the AR clock; see `handle(_:)`.
    @ObservationIgnored private let decider = CueDecider()
    /// "door ahead, two meters" from the mesh classification (step 4).
    @ObservationIgnored private let namer = ObstacleNamer()
    /// Kind currently decided as active (for the UI); `.clear` when nothing is in range.
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
    private(set) var started = false
    /// Thermal state name; the watchdog (step 9) acts on it.
    /// One of `nominal|fair|serious|critical|unknown`; also written into every `lanes` log line.
    private(set) var thermalName = "nominal"
    /// 0–100, or -1 when unknown (simulator).
    private(set) var batteryPercent = -1

    // MARK: Settings (persisted; each `didSet` pushes into the engines that care)
    //
    // Each setting is a UserDefaults key of the same name (see `Settings`). `didSet` does not run
    // for the initial value, so `init()` pushes the loaded values into the engines once.

    /// Phone mounted upright (portrait, camera at the top). See ios/README.md §6 for the remap.
    /// Pushed to `depth.apply(portrait:mirror:)` via `pushDepthSettings()`.
    var portraitMode: Bool = Settings.bool("portraitMode", default: true) {
        didSet { Settings.set(portraitMode, "portraitMode"); pushDepthSettings() }
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
    /// Speak obstacle names ("door ahead, two meters"). Off = haptics only.
    /// Read on every report in `handle(_:)`; not pushed anywhere.
    var obstacleNamesEnabled: Bool = Settings.bool("obstacleNamesEnabled", default: true) {
        didSet { Settings.set(obstacleNamesEnabled, "obstacleNamesEnabled") }
    }
    /// Spatial click toward the next waypoint while navigating. Mirrored into `beacon.enabled`.
    var beaconEnabled: Bool = Settings.bool("beaconEnabled", default: true) {
        didSet { Settings.set(beaconEnabled, "beaconEnabled"); beacon.enabled = beaconEnabled }
    }
    /// Mirror every obstacle cue to the watch even while the phone engine is healthy.
    /// Read in `handle(_:)` only.
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
    var liveViewEnabled = false

    // MARK: Lifecycle

    /// Token for the `thermalStateDidChangeNotification` observer (kept alive for the process).
    @ObservationIgnored private var thermalObserver: NSObjectProtocol?
    /// Token for the `batteryLevelDidChangeNotification` observer (kept alive for the process).
    @ObservationIgnored private var batteryObserver: NSObjectProtocol?

    /// The 10 Hz beacon-sync loop (`startTicker`); non-nil only while a route is active.
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// Builds `describer` (needs `depth.processor` + `speech`), pushes the persisted settings into
    /// the engines (property `didSet`s do not fire for initial values) and registers `shared`.
    /// Starts nothing: engines start in `start()`, called from the root view's `.task`.
    init() {
        // One vision client for "Where am I" and the hazard watch: cloud with on-device fallback
        // when a key is set, on-device otherwise — never nil, works with no network.
        let context = SceneContext()
        sceneContext = context
        let client = VLMClientFactory.resolved(context: context)
        describer = SceneDescriber(processor: depth.processor, speech: speech, client: client,
                                   context: context)
        hazards = HazardScanner(processor: depth.processor, watchClient: client)
        hazards.signsEnabled = signsEnabled
        hazards.watchEnabled = hazardWatchEnabled
        context.setPeopleEnabled(namePeopleEnabled)
        pushDepthSettings()
        depth.setHighFrameRate(highFrameRateCamera)   // before start(): only sets the flag
        haptics.silenced = hapticsSilenced
        logger.enabled = loggingEnabled
        beacon.enabled = beaconEnabled
        AppModel.shared = self
    }

    /// One call for every trigger: on-screen button, watch, Action button, Camera Control.
    /// Logs a `describe` event with the provider name, then hands off to `SceneDescriber`
    /// (which waits for a camera frame and speaks at `.scene` priority).
    func describeScene() {
        logger.event("describe", ["provider": describer.providerName ?? "none"])
        describer.describe()
    }

    /// Automation hook (`CANEKIT_DESCRIBE_EVERY_WAYPOINT=1`, used by `make e2e SCENARIO=streetview`):
    /// ask "Where am I" at route start and at every waypoint, so the Street View mock logs what
    /// the describer says at each corner of the route. Off unless the variable is set.
    static let describeEveryWaypoint = ProcessInfo.processInfo.environment["CANEKIT_DESCRIBE_EVERY_WAYPOINT"] == "1"

    /// Logs every "Where am I" outcome (sentence or error, latency, replay frame) as
    /// `describe_result`, so a walk log shows what was actually said. Wired once in `start()`.
    /// `gate` is the `CloudSceneGate` verdict ("spoken", "edited: dropped count …", "refused: …",
    /// "on-device") and `cloud_text` the cloud model's raw reply, so a refusal can be read back
    /// against what the model wanted to say. Neither field may be called `kind` or `t`
    /// (`TripLogRecord` owns those).
    private func wireDescriber() {
        describer.onResult = { [weak self] text, error, ms, frame, gate, cloudText in
            self?.logger.event("describe_result", [
                "text": text ?? "", "error": error ?? "", "ms": ms ?? -1,
                "gate": gate, "cloud_text": cloudText,
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
    /// Idempotent (`guard ticker == nil`). Started by `beginRoute`, stopped by `stopRoute` and
    /// on arrival. Pushes `speech.isSpeaking`, head yaw (0 while a recenter is pending) and the
    /// nav target bearing (nil = beacon silent) into `BeaconEngine`.
    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.beacon.setSpeaking(self.speech.isSpeaking)
                // After a turn the AirPods yaw (relative to the *old* reference) contains the body
                // turn that the phone heading already has: adding both double-counts it. Until
                // the reference is re-zeroed on the new leg, render from the heading alone.
                self.beacon.setHeadYaw(self.recenterPending ? 0 : (self.head.headYawDeg ?? 0))
                self.beacon.setTarget(bearing: self.nav.isNavigating ? self.nav.targetBearing : nil)
                // Clock-driven nav checks (arrival hint while standing still: no fixes arrive).
                self.nav.tick(now: Date().timeIntervalSinceReferenceDate)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Cancels the beacon-sync loop; safe to call when it is not running.
    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    /// Called once from the root view's `.task`. Starts the engines that exist at this step.
    /// Idempotent (`guard !started`), so `.task` re-entry is safe.
    /// ⚠ Do not reorder audio session → haptics → ARKit without a device test (AirPods route and
    /// Taptic engine ownership depend on it; AGENTS.md hard rule 7: one `.playback` session).
    func start() {
        guard !started else { return }
        started = true
        observeThermalAndBattery()
        logger.start()
        speech.configureAudioSession()       // before ARKit and before the haptic engine
        wireAudioRoute()
        haptics.start()
        watch.onCommand = { [weak self] cmd in self?.handleWatchCommand(cmd) }
        watch.activate()
        wireNavigation()
        // Location prompt at launch (a sighted helper is usually present then); Motion and
        // HealthKit prompt at route start, so no three-alert pile-up on the first walk.
        // (Skipped under XCUITest: the three-choice alert races the first tap.)
        if ProcessInfo.processInfo.environment["CANEKIT_UITEST"] != "1" {
            location.requestAuthorization()
        }
        depth.onReport = { [weak self] report in
            self?.handle(report)
        }
        depth.start()
        wireHazards()
        wireDescriber()
        logger.event("start", ["lidar": lidarSupported, "mesh": meshClassificationSupported,
                               "haptics": haptics.isHealthy, "vision": describer.providerName ?? "none",
                               // What this phone can run alongside LiDAR (measured, not assumed).
                               "video_format": depth.chosenFormat,
                               "video_formats": DepthEngine.supportedFormats,
                               "front_camera_with_lidar": DepthEngine.supportsFrontCameraWithLiDAR])
        let cameraDenied = announceCameraDenied()
        speech.prefetch(Self.commonLines)
        if !cameraDenied {
            speech.say(lidarSupported ? "CaneKit ready." : "CaneKit. This phone has no LiDAR.", .nav)
        }
        // Automation hook (simulator GPS replay, UI tests): `--demo-route` argument or the
        // CANEKIT_DEMO_ROUTE=1 environment variable starts guidance at launch.
        if CommandLine.arguments.contains("--demo-route")
            || ProcessInfo.processInfo.environment["CANEKIT_DEMO_ROUTE"] == "1" {
            startDemoRoute()
        }
    }

    /// Foreground/background transitions. ARKit pauses itself in the background; we pause the
    /// engine explicitly so the gyro stops too, and resume without resetting tracking. Core
    /// Haptics stops its engine on suspend, so it is restarted on `.active`.
    /// Called by `CaneKitApp`'s `.onChange(of: scenePhase)`; no-op until `start()` has run.
    /// On `.background` the cue state machines are reset and the trip log is flushed so nothing
    /// is lost if the process is suspended.
    func scenePhaseChanged(_ phase: ScenePhase) {
        guard started else { return }
        switch phase {
        case .active:
            haptics.resume()
            depth.resume()
            beacon.resumeIfNeeded()          // the engine can die across a screen lock (Muse M4)
            hazards.start()
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
                speech.say("Screen locked. Obstacle warnings are paused until you unlock.", .nav, ttl: 10)
            }
            hazards.stop()                   // no scanning a frozen last frame in the background
            sceneContext.set("")             // LiDAR facts from here are stale once we come back
            depth.pause()
            haptics.stopAll()
            decider.reset()
            cueSpeech.cleared()              // a new foreground is a new episode: speak the first head cue
            namer.reset()
            activeCue = .clear
            logger.flush()
        @unknown default:
            break
        }
    }

    // MARK: Report routing (the "cue router")

    /// Every depth report lands here (~15 Hz): decide → render on the phone (step 3);
    /// step 4 adds the ObstacleNamer, step 5 the watch mirror.
    /// Installed as `depth.onReport` in `start()`; always on the main actor.
    /// `now` is always `report.timestamp` (ARKit clock, seconds) — never wall time: the decider's
    /// repeat / 400 ms change intervals and `CueSpeechPolicy`'s intervals are in that clock.
    /// ⚠ Do not change the decider/`now` contract without re-running `CueDeciderTests`
    /// (`cueChangeNeeds400ms`, `hysteresisHoldsUntilPlusFifteenCentimetres`,
    /// `centerApproachFiresThenUpdatesDistance`).
    private func handle(_ report: LaneReport) {
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
        if obstacleNamesEnabled, let line = namer.update(report, now: report.timestamp) {
            speech.say(line, .obstacle, ttl: 4)      // > namer interval + one utterance
            logger.event("speech", ["text": line, "priority": "obstacle"])
        }
        if groundHazardsEnabled, let g = report.groundHazard,
           groundPolicy.shouldAnnounce(g, now: report.timestamp) {
            groundHazardFound(g, now: report.timestamp)
        }
        sceneContext.set(Self.contextLine(report))
        // Every report; the logger throttles `lanes` records to `laneRate` (2 Hz).
        logger.lanes(report, cue: activeCue, thermal: thermalName, battery: batteryPercent, fps: depth.fps)
    }

    /// Which obstacle cues are also spoken (CaneKitLogic.CueSpeechPolicy, unit-tested).
    /// Replaced with a fresh value at every `beginRoute`; `cleared()` on the decider's `.stop`.
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
            self?.recordHazard(kind: source.rawValue, text: text, source: source, jpeg: jpeg)
        }
        hazards.start()
    }

    /// A confirmed LiDAR ground hazard worth saying: cane buzz (4 heavy taps), the wrist when the
    /// phone cannot buzz, a spoken line at safety priority (a drop-off is as urgent as head
    /// height), and a hazard-map entry with the frame.
    private func groundHazardFound(_ g: GroundHazard, now: TimeInterval) {
        lastGroundHazard = g.spokenLine
        haptics.playGroundHazard()
        if !haptics.isHealthy || haptics.silenced || fallbackToWatch {
            watch.send(obstacle: .center, now: now)
        }
        speech.say(g.spokenLine, .safety, ttl: 3)
        let processor = depth.processor
        Task { [weak self] in
            let jpeg = await Self.frame(processor, maxDimension: 768)
            self?.recordHazard(kind: g.kind.rawValue, text: g.spokenLine, source: .ground, jpeg: jpeg)
        }
    }

    /// Hazard map + trip log entry for any hazard source.
    /// Uses the navigation engine's last fix when location has stopped (after arrival), so a
    /// sign read at the CIF door still lands at the door, not at 0, 0 (review round 5) — but only
    /// if that fix is under 2 minutes old; an older one could be a different place entirely
    /// (Muse round 6). The same age gate applies to the live fix (GPS lost under a roof keeps a
    /// stale one; Muse + Antigravity round 7). No fresh fix gives a null geometry.
    private func recordHazard(kind: String, text: String, source: HazardSource, jpeg: Data?) {
        let now = Date().timeIntervalSinceReferenceDate
        let fix = [location.fix, nav.lastFix].compactMap { $0 }.first { now - $0.timestamp < 120 }
        hazardLog.record(kind: kind, text: text, fix: fix, jpeg: jpeg)
        // Field "type", not "kind": a "kind" field used to replace the record's own kind
        // ("hazard" → "sign"), so e2e.py never saw a hazard record (phone trip log, 2026-09-11).
        logger.event("hazard", ["type": kind, "text": text, "source": source.rawValue])
    }

    /// The LiDAR facts the on-device describer may use ("Obstacle ahead at 1.4 meters. Hole
    /// ahead, two meters."). Empty when nothing is within 3 m.
    /// "Ahead" is the centre lane only (torso + head, filtered): side lanes and the unfiltered
    /// centre window made it true almost always on a sidewalk, which left the LiDAR gate for
    /// on-device hazard labels permanently open (review round 5).
    static func contextLine(_ r: LaneReport) -> String {
        guard r.depthAvailable else { return "" }
        var parts: [String] = []
        let centre = [r.torso, r.head].compactMap { $0.count == 3 ? $0[1] : nil }
        let ahead = centre.min() ?? .infinity
        if ahead.isFinite, ahead < 3 { parts.append("Obstacle ahead at \(SpokenDistance.phrase(ahead)).") }
        if r.head.count == 3, r.head[1].isFinite, r.head[1] < 1.5 { parts.append("Something at head height.") }
        if let g = r.groundHazard { parts.append(g.spokenLine) }
        if let hit = r.centerHit, let name = hit.classification.spokenName {
            parts.append("The obstacle ahead looks like a \(name).")
        }
        return parts.joined(separator: " ")
    }

    /// JPEG encode off the main actor (the ground-hazard photo for the hazard map).
    @concurrent
    private static func frame(_ p: DepthFrameProcessor, maxDimension: CGFloat) async -> Data? {
        p.jpegSnapshot(maxDimension: maxDimension, quality: 0.6)
    }

    /// Camera refused → the whole obstacle channel is dead; say so instead of "CaneKit ready."
    /// and silence (Muse H3). `.notDetermined` is fine: ARKit prompts on first run.
    /// - Returns: true when the camera is refused (so `start()` skips "CaneKit ready.", which
    ///   would contradict the warning; Antigravity docs review).
    @discardableResult
    private func announceCameraDenied() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .denied || status == .restricted else { return false }
        routeError = "Camera is off for CaneKit"
        // Launch and route start both check: speak it once a minute, not twice in a row
        // (Antigravity, final review: the demo-route launch queued the 20 s warning twice).
        let now = Date()
        if now.timeIntervalSince(cameraDeniedSpokenAt) > 60 {
            cameraDeniedSpokenAt = now
            speech.say("Camera access is off, so obstacle warnings cannot work. Turn on Camera for CaneKit in Settings.", .nav, ttl: 20)
        }
        return true
    }

    /// The mid-route screen-lock warning was spoken on this route (at most once per route).
    @ObservationIgnored private var lockWarningGiven = false

    /// Camera at 60 fps instead of 30 (Mount card, persisted, off by default: heat untested over a
    /// long walk). See `DepthEngine.setHighFrameRate`.
    var highFrameRateCamera: Bool = Settings.bool("highFrameRateCamera", default: false) {
        didSet { Settings.set(highFrameRateCamera, "highFrameRateCamera"); depth.setHighFrameRate(highFrameRateCamera) }
    }

    /// When the camera-denied warning was last spoken (`announceCameraDenied`).
    @ObservationIgnored private var cameraDeniedSpokenAt = Date.distantPast

    /// Stop the running route without speaking (used before starting another one).
    private func endRouteQuietly() {
        nav.stop()
        beacon.stop()
        head.stop()
        stopTicker()
        trip.cancel()                        // synchronous: the new trip.start() must not be no-op'd
        liveActivity.end()
        speech.stopAll()
        logger.event("route", ["action": "restart"])
    }

    /// Thermal: was the phone already hot at the last update (announce transitions only).
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

    /// Spoken once at route start so the walker knows which channels are live before moving.
    /// Last step of `beginRoute`; each line is `.nav` with a 20 s TTL, queued after the intro.
    /// These lines are not written to the trip log.
    private func announceChannels() {
        var lines: [String] = []
        if !audioRoute.headphonesConnected {
            lines.append("No headphones. Beacon paused until AirPods connect.")
        }
        if watch.isPaired, !watch.isReachable {
            lines.append("Watch not reachable. Open CaneKit on the watch.")
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
    /// - `nav.onNavCue` → watch tap + Live Activity glyph kind.
    /// - `nav.onWaypointAdvanced` → recenter becomes pending (re-zeroed only once walking
    ///   straight, never on a timer).
    /// - `nav.onArrived` → stops beacon/head/ticker, ends the Live Activity, then speaks the trip
    ///   summary after `await trip.stop()` refreshes the step count.
    private func wireNavigation() {
        location.onFix = { [weak self] fix in
            guard let self else { return }
            FrameReplay.shared.update(position: fix.coordinate)   // simulator Street View e2e only
            self.nav.update(fix: fix)
            self.trip.ingest(fix)
            if self.nav.isNavigating {
                self.liveActivity.update(instruction: self.nav.instruction,
                                         distanceM: self.nav.distanceToNext ?? 0, kind: self.lastNavKind)
                // The link dedups (same text and < 5 m change), so this is ~1 message / 5 s.
                self.pushStatusToWatch()
                self.autoRecenterIfWalkingStraight(fix)
            }
            self.logger.event("gps", ["lat": fix.coordinate.latitude, "lon": fix.coordinate.longitude,
                                      "acc": fix.accuracy, "speed": fix.speed])
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
            if Self.describeEveryWaypoint { self.describeScene() }
            self.beacon.stop()
            self.head.stop()
            self.location.stop()                 // GPS off after arrival (Muse M2)
            self.stopTicker()
            self.pushStatusToWatch()
            self.liveActivity.end(final: self.nav.instruction)
            // Arrival card, spoken after the waypoint's own line (same priority → queued),
            // once the step count has been refreshed.
            Task { [weak self] in
                guard let self else { return }
                await self.trip.stop()
                let destination = self.nav.route?.waypoints.last?.say ?? "Arrived"
                let summary = self.trip.spokenSummary(destination: destination)
                self.nav.appendToLastSpoken(summary)     // Repeat at the door includes the numbers
                self.speech.say(summary, .nav, ttl: 30)
                self.logger.event("speech", ["text": summary, "priority": "nav"])
            }
        }
    }

    /// Last wrist cue kind, for the Live Activity glyph.
    /// A `NavCue.rawValue` ("turnLeft" / "turnRight" / "crossing" / "arrived"); reset to
    /// "straight" at `beginRoute`. A passed-by advance sends no cue, so the kind is kept.
    /// Any new value must also be handled by the widget's glyph switch (NavLiveActivity.swift).
    @ObservationIgnored private var lastNavKind = "straight"

    /// The user is facing the way to walk: zero the head yaw there.
    /// Manual trigger (phone "Recenter" button, watch Recenter). Clears `recenterPending`, so
    /// the beacon starts using head yaw again; speaks "Recentered." (2 s TTL) and logs `recenter`.
    func recenter() {
        head.recenter()
        recenterPending = false
        speech.say("Recentered.", .nav, ttl: 2)
        logger.event("recenter")
    }

    /// Say the current instruction again (phone button, watch "Repeat", Siri).
    /// Delegates to `nav.repeatInstruction()`, which speaks the last line actually spoken plus
    /// the distance to the next waypoint, through `onRepeat` (bypasses queue coalescing).
    func repeatInstruction() {
        nav.repeatInstruction()
        logger.event("repeat")
    }

    // MARK: Auto-recenter (README §3: "auto when walking straight for 3 s")

    /// Set at route start and after every waypoint; cleared once a recenter happens. While set,
    /// the beacon renders from the phone heading alone (see startTicker).
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
    /// detector; never fires on a timer, while a turn is settling, without AirPods, or within
    /// `recenterAfterCrossingM` of a just-reached crossing.
    /// ⚠ Do not loosen the detector gates or the crossing exclusion without a device walk test
    /// (covered by `straightWalkNeedsThreeSteadyFixesCountingTheFirst`,
    /// `straightWalkRestartsOnATurnAStopOrAHeadTurn`).
    private func autoRecenterIfWalkingStraight(_ fix: GeoFix) {
        guard recenterPending, !nav.isSettling, head.isConnected else { straightWalk.reset(); return }
        if let wp = nav.lastReached, wp.crossing,
           GeoMath.distanceMeters(fix.coordinate, wp.coordinate) < recenterAfterCrossingM {
            straightWalk.reset()
            return
        }
        let straight = straightWalk.update(speed: fix.speed, accuracy: fix.accuracy,
                                           heading: location.heading, headYaw: head.headYawDeg ?? 0)
        guard straight else { return }
        head.recenter()
        recenterPending = false
        logger.event("recenter", ["auto": true])
    }

    /// Start the bundled demo route (ISR Townsend Hall → CIF).
    /// Triggered by the "Start demo route" button, `StartDemoRouteIntent`, and at launch by the
    /// `--demo-route` / `CANEKIT_DEMO_ROUTE=1` automation hook. On failure sets `routeError` and
    /// says "Route file missing."
    /// ⚠ Abandons an in-flight MapKit build first: a "Take me to …" search that returned *after*
    /// the demo route started would otherwise call `beginRoute` again and silently swap the walker
    /// onto the searched route mid-walk.
    func startDemoRoute() {
        cancelRouteBuild()
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
    func startMapKitRoute() {
        navigate(to: destinationQuery)
    }

    /// Drop the route error line ("Type a destination first", "No GPS fix yet", a MapKit error).
    /// Called by `DestinationField` on every keystroke: an error about the *previous* attempt
    /// must not sit under a box the walker is already retyping (it reads as a permanent state).
    func clearRouteError() {
        routeError = nil
    }

    /// Walking route from the current fix to a spoken or typed place: the campus gazetteer
    /// first, then the nearest reasonable MKLocalSearch result (`RouteSource.mapKit(to:from:)`).
    /// Called by `startMapKitRoute()` and `TakeMeToIntent` (Siri "Take me somewhere in
    /// CaneKit" → "Where do you want to go?"). Shows the text in the destination field.
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
    /// Grainger in CaneKit" → `TakeMeToIntent` with a `CampusDestination`).
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

    /// The in-flight MapKit build (fix wait + search + directions). Cancelled by `stopRoute()`
    /// and replaced by a newer request, so a Stop said while "Finding a route…" plays cannot be
    /// followed by the old route starting anyway.
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
    private func buildRoute(to destination: RouteDestination, searchLine: String) {
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
                                announce: WalkingIntro.line(place: planned.placeName, meters: planned.walkingMeters))
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

    /// Skip to the next waypoint (Siri `NextWaypointIntent`, watch Next / crown). Says "No route
    /// running." when idle, like the watch always did.
    func nextWaypoint() {
        if nav.isNavigating { nav.next() } else { speech.say("No route running.", .nav, ttl: 2) }
    }

    /// Stop guidance ("Stop route" button, `StopRouteIntent`). Abandons an in-flight MapKit build
    /// first, then tears down nav, location, beacon, head tracking, the ticker, the trip tracker
    /// (fire-and-forget) and the Live Activity, clears the speech queue so queued waypoint lines
    /// cannot play after Stop, and says "Route stopped."
    func stopRoute() {
        cancelRouteBuild()
        nav.stop()
        location.stop()
        beacon.stop()
        head.stop()
        stopTicker()
        Task { [weak self] in await self?.trip.stop() }
        liveActivity.end()
        speech.stopAll()                     // queued waypoint lines must not play after Stop
        speech.say("Route stopped.", .nav)
        logger.event("route", ["action": "stop"])
        pushStatusToWatch()
    }

    /// Lines the natural voice should have ready before they are needed.
    /// Prefetched in `start()` and again in `beginRoute`.
    /// ⚠ Must stay byte-identical to the strings spoken in NavigationEngine, CueSpeechPolicy and
    /// this file, or the prefetch cache misses and the line waits for synthesis.
    static let commonLines = [
        "CaneKit ready.", "Route started.", "Route stopped.", "Next.", "Recentered.",
        "Veer left.", "Veer right.", "GPS weak. Waypoint cues paused until it recovers.", "GPS back.",
        "No route running.", "No GPS fix yet. Try again outside.",
        "Head height.", "Left.", "Right.", "Passed one waypoint.",
    ]

    /// Shared start sequence for both route sources. Order matters: prefetch → location →
    /// `nav.start` (speaks the intro) → beacon/head → recenter pending → fresh cue-speech policy
    /// → ticker → trip tracker (Motion + HealthKit prompts appear here, by design) → Live
    /// Activity → log → watch status → channel announcements (queued after the intro).
    /// `announce` (MapKit routes: "Walking to Grainger Engineering Library, 750 meters.") is said
    /// after a running route is torn down and before the intro, so the walker hears what was
    /// chosen first and can say Stop if it is wrong.
    private func beginRoute(_ route: Route, announce: String? = nil) {
        // A second start mid-route (Action button / Siri) restarts cleanly (Muse M5).
        if nav.isNavigating { endRouteQuietly() }
        // Location refused: say so instead of "Route started" followed by silence (Muse H2).
        if announceLocationDenied() { return }
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
        // Every waypoint line and the route intro, synthesized now so they play instantly.
        speech.prefetch(route.waypoints.map(\.say) + Self.commonLines
                        + ["Route started. \(route.name). First: \(route.waypoints.first?.say ?? "")"])
        location.start()
        nav.start(route)
        beacon.start()
        head.start()
        recenterPending = true               // first straight stretch zeroes the head reference
        straightWalk.reset()
        cueSpeech = CueSpeechPolicy()
        startTicker()
        trip.start()
        lastNavKind = "straight"
        liveActivity.start(routeName: route.name, instruction: nav.instruction, distanceM: nav.distanceToNext ?? 0)
        logger.event("route", ["action": "start", "name": route.name, "waypoints": route.waypoints.count,
                               "headphones": audioRoute.outputName, "watch": watch.isReachable])
        pushStatusToWatch()
        announceChannels()
        if Self.describeEveryWaypoint { describeScene() }   // the start (ISR) is a corner too
    }

    /// When location access is refused: shows and speaks how to fix it, returns true (the caller
    /// stops). Shared by `beginRoute` and `startMapKitRoute` (Muse H2, review round 5).
    private func announceLocationDenied() -> Bool {
        guard location.authorizationDenied else { return false }
        routeError = "Location is off for CaneKit"
        speech.say("Location access is off. Turn on Location for CaneKit in Settings to navigate.", .nav, ttl: 20)
        return true
    }

    /// Sends the current instruction + distance to the watch. `-1` means "no distance" (the watch
    /// maps it to nil). `PhoneWatchLink` drops same-text updates that moved < 5 m.
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

    /// Debug buttons on the Watch card.
    /// Sends a raw `NavCue` tap to the watch and logs `watch {test}`.
    func watchTest(_ cue: NavCue) {
        watch.send(nav: cue)
        logger.event("watch", ["test": cue.rawValue])
    }

    /// Debug button: prove the audio route (AirPods) and the queue/interrupt behaviour.
    /// Queues a `.scene` line then an `.obstacle` line; the obstacle line should interrupt it.
    func speechTest() {
        speech.say("Scene test: sidewalk ahead, bike rack at ten o'clock, two meters.", .scene)
        speech.say("Door ahead, one meter.", .obstacle)
    }


    /// Camera Control / volume press reached the app while ARKit owns the camera.
    /// Logged (`describe {source: cameraControl}` in the trip log is the step-2 spike readout),
    /// then treated like "Where am I".
    func cameraControlPressed() {
        logger.event("describe", ["source": "cameraControl"])
        describeScene()
    }

    // MARK: Private

    /// Pushes `portraitMode` / `mirrorLeftRight` into the depth engine's lane remap, and the
    /// mirror into `sceneContext` as well: the camera image is never mirrored, so a mirrored
    /// mount has to swap left and right in *speech* (`PeopleAhead.bearing`), exactly as the lane
    /// grid swaps them in the haptics.
    private func pushDepthSettings() {
        depth.apply(portrait: portraitMode, mirror: mirrorLeftRight, groundHazards: groundHazardsEnabled)
        sceneContext.setMirrored(mirrorLeftRight)
    }

    /// Enables battery monitoring, reads the initial values and subscribes to thermal / battery
    /// notifications for the process lifetime. Called once from `start()`.
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
    /// haptics keep running).
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
        depth.setMeshClassification(!hot)
        // Say it once per transition: names going silent without a word is confusing (Muse L5).
        hazards.paused = hot                 // camera extras off while hot; lanes + haptics stay
        if hot, !wasHot, started { speech.say("Phone is hot. Door and wall names and sign reading paused.", .nav, ttl: 10) }
        wasHot = hot
    }

    /// `batteryLevel` is 0…1, or negative when unknown (simulator) → `batteryPercent` 0–100 / -1.
    private func updateBattery() {
        let level = UIDevice.current.batteryLevel
        batteryPercent = level < 0 ? -1 : Int((level * 100).rounded())
    }
}

/// Thin UserDefaults wrapper so settings stay one-liners above.
/// Keys are the AppModel property names; main-actor by the target default.
enum Settings {
    /// Stored Bool for `key`, or `d` when the key has never been written (not `false`).
    static func bool(_ key: String, default d: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? d
    }
    /// Persists `value` under `key` in `UserDefaults.standard`.
    static func set(_ value: Bool, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
