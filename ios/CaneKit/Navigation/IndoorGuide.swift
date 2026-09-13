//
//  IndoorGuide.swift
//  CaneKit
//
//  The indoor leg of "take me from ISR to CIF" (Step 62): walks a recorded step script from a room to
//  the building's exit door, then hands over to the outdoor GPS route once the walker is outside.
//  Also the Settings "Record indoor route" mode a sighted teammate uses once to make that script.
//
//  Purpose:
//    · Loads the scripts: bundled `indoor_*.json` plus Documents/indoor/*.json (a recorded file wins
//      by id — `IndoorScriptCatalog.merged`); an invalid file is skipped and logged.
//    · Walking: `start(script:destination:source:)` feeds CMPedometer (or synthetic steps) into
//      `IndoorProgress`, speaks every `.say` at `.nav` ttl 20 through `AppModel.speech`, forwards
//      every GPS fix to `IndoorHandover`, and on the handover starts the outdoor leg
//      (`IndoorScriptCatalog.outdoorLeg`: the CIF demo route, else `navigate(to:)`).
//    · Recording: CMPedometer + CMDeviceMotion (`xArbitraryZVertical`, 10 Hz, unwrapped by
//      `IndoorYawUnwrapper`) into `IndoorRecorder`; "Add landmark" arms a one-shot transcript hook
//      (`takeTranscript`) and opens push-to-talk; "Finish at the exit" averages fixes
//      (`IndoorExitAverager`); Save writes Documents/indoor/<id>.json with `walked: true`.
//
//  Rules kept here (the numbers live in CaneKitLogic IndoorRoute.swift, pinned by IndoorRouteTests):
//    · Script lines are human-authored route facts: `.nav`, like a waypoint `say` — never the scene /
//      obstacle path, and never a `speech` log record (e2e.py asserts on `speech`). Every line and
//      decision is logged as `indoor {action, index, count, steps, walked, script, …}` instead.
//    · ⚠ The CMPedometer handlers are explicitly `@Sendable` and hop to main (TripTracker's crash note:
//      an inferred `@MainActor` closure called on CoreMotion's queue trapped the app 2026-09-11).
//    · The device-motion handler is delivered `to: .main`, so `MainActor.assumeIsolated` is provably
//      correct there (AGENTS.md hard rule 1, the HeadPoseTracker pattern).
//    · Simulator / demo: `CANEKIT_INDOOR_ROUTE=1` starts the ISR script at launch;
//      `CANEKIT_INDOOR_SIM_STEPS_PER_S` (or the Guide's "Simulate walk" while
//      indoors) replaces the pedometer with floor(rate·t) steps; at the exit the simulation feeds
//      fixes at the exit coordinate through `LocationService.ingest`, so the handover and the
//      outdoor route run in the simulator too.
//
//  Owner: `AppModel.indoor` (attached in `AppModel.start()`). Callers: `AppModel+Indoor.swift`
//  (voice, next / repeat / Stop route / simulate hooks), `AppModel.wireNavigation` (`ingest`),
//  the transcript hook in `AppModel.start()` (`takeTranscript`), `GuideCard` (status line, compact
//  row), the Settings `IndoorRecordCard` in ContentView.swift.
//  Steps 62 + 64 review round: the landmark hook lets commands through (`IndoorRecorder.isLandmarkText`);
//  the Live Activity is requested at `start` (`LiveActivityController.beginIndoor`) and reused by
//  the outdoor leg; a locked phone logs `paused_background` / `resumed` (`sceneChanged`) and the
//  handover can fire GPS-only (`IndoorHandover.gpsOnly…`) when the paused pedometer never reaches
//  the exit; the exit fallback must be ≤ 30 m and ≤ 20 s old; `pedometer_nil` is logged at most
//  every 10 s; the recording card speaks a refusal instead of ignoring a tap.
//  Tests: the pure halves in IndoorRouteTests.swift; this class has no unit test (app target) —
//  device test in CHANGELOG Step 62.
//

import CaneKitLogic
import CoreMotion
import Foundation
import Observation

/// Walks and records indoor step scripts. One instance, `AppModel.indoor`; main actor.
@MainActor
@Observable
final class IndoorGuide {

    // MARK: - Walking state (read by GuideCard, status, the island)

    /// An indoor script is being walked (from `start` until the handover or `stop`).
    private(set) var isActive = false
    /// Current step, 0-based (`IndoorProgress.index`).
    private(set) var stepIndex = 0
    /// Steps in the active script.
    private(set) var stepCount = 0
    /// The last step is done; waiting for the GPS handover.
    private(set) var atExit = false
    /// "I'm outside" came without a usable fix; the next qualifying fix hands over.
    private(set) var waitingForGPS = false
    /// The line "repeat" says: the current step's `say`, or the exit line. "" when idle.
    private(set) var currentSay = ""
    /// Spoken name of the active script, nil when idle.
    private(set) var scriptName: String?
    /// Synthetic steps are being fed instead of the pedometer.
    private(set) var isSimulating = false
    /// The catalog: bundled scripts with recorded files merged over them by id.
    private(set) var scripts: [IndoorScript] = []

    /// "Indoors · step 3 of 5" for the Guide card.
    var guideLine: String { IndoorStatus.guideLine(index: stepIndex, count: stepCount, atExit: atExit) }
    /// "Indoors: step 3 of 5." for the status report (`StatusFacts.indoorClause`), nil when idle.
    var statusClause: String? {
        isActive ? IndoorStatus.statusClause(index: stepIndex, count: stepCount, atExit: atExit) : nil
    }

    // MARK: - Recording state (read by the Settings card)

    /// "Start recording" was pressed and neither Save nor Cancel has ended it.
    private(set) var isRecording = false
    /// Pedometer steps per recorded step so far (`IndoorRecorder.stepCountsSoFar`).
    private(set) var recordedStepCounts: [Int] = []
    /// Landmarks added so far.
    private(set) var recordedLandmarkCount = 0
    /// "Finish at the exit" stored the exit coordinate; Save is possible.
    private(set) var recordingFinished = false
    /// The exit fix window is open.
    private(set) var isFinishingExit = false
    /// "Add landmark" armed the transcript hook and it has not fired or expired.
    private(set) var awaitingLandmark = false
    /// Last recording line shown on the card (what was also spoken), nil before any.
    private(set) var recordingStatus: String?
    /// The file id a recording is saved under (typed on the card; sanitized at Save).
    var recordingID = IndoorScriptCatalog.defaultRecordingID

    // MARK: - Private

    /// The owner, for speech, the logger, GPS and the outdoor route. Weak: the model owns this.
    @ObservationIgnored private weak var model: AppModel?
    /// The step machine of the active walk.
    @ObservationIgnored private var progress: IndoorProgress?
    /// The GPS gate of the active walk.
    @ObservationIgnored private var handover: IndoorHandover?
    /// The script being walked.
    @ObservationIgnored private var activeScript: IndoorScript?
    /// The "to" of "take me from A to B", nil from the Settings test button.
    @ObservationIgnored private var destination: String?
    /// Bumped by every start / stop, so a late pedometer or simulation callback of an old walk is dropped.
    @ObservationIgnored private var generation: UInt64 = 0
    /// Highest cumulative step count fed to the active walk.
    @ObservationIgnored private var lastSteps = 0
    /// Live step counts while walking.
    @ObservationIgnored private let pedometer = CMPedometer()
    /// The synthetic-step loop.
    @ObservationIgnored private var simTask: Task<Void, Never>?
    /// Problems found while loading, logged on `attach`.
    @ObservationIgnored private var loadProblems: [[String: Any]] = []

    /// The pure recorder of the current recording.
    @ObservationIgnored private var recorder = IndoorRecorder()
    /// Live step counts while recording (separate from the walking one).
    @ObservationIgnored private let recordPedometer = CMPedometer()
    /// Device yaw while recording.
    @ObservationIgnored private let motion = CMMotionManager()
    /// Unwraps the yaw samples.
    @ObservationIgnored private var yawUnwrapper = IndoorYawUnwrapper()
    /// Bumped by every recording start / cancel / save.
    @ObservationIgnored private var recordGeneration: UInt64 = 0
    /// The exit fix window while "Finish at the exit" runs.
    @ObservationIgnored private var exitAverager: IndoorExitAverager?
    /// Polls the exit window.
    @ObservationIgnored private var exitTask: Task<Void, Never>?
    /// When the landmark hook expires (monotonic seconds).
    @ObservationIgnored private var landmarkDeadline: Double?
    /// `indoor {action: pedometer_nil, source}` at most once per `ActionRateLimit.defaultInterval`
    /// (10 s) per source ("walking" / "recording") — a nil CMPedometer update is otherwise invisible.
    @ObservationIgnored private var pedometerNilLog = ActionRateLimit()

    /// `CANEKIT_INDOOR_SIM_STEPS_PER_S` as a rate, or nil (real pedometer).
    static let environmentSimRate = IndoorSimSteps.rate(
        from: ProcessInfo.processInfo.environment["CANEKIT_INDOOR_SIM_STEPS_PER_S"])

    /// TTL of every indoor line, seconds (spec: a script line waits behind warnings up to 20 s).
    private static let lineTTL: TimeInterval = 20

    /// Documents/indoor — where recorded scripts live.
    static var recordedDirectory: URL {
        URL.documentsDirectory.appendingPathComponent("indoor", isDirectory: true)
    }

    /// Monotonic seconds (recording events, exit window, landmark hook).
    private static func clock() -> Double { ProcessInfo.processInfo.systemUptime }
    /// Wall-clock seconds, the clock of `GeoFix.timestamp` (handover `now`).
    private static func wallClock() -> Double { Date().timeIntervalSinceReferenceDate }

    /// Loads the catalog (no logging yet: the model is not attached).
    init() {
        reloadScripts()
    }

    /// Connects the owner and logs the catalog. Caller: `AppModel.start()`, once.
    /// - Parameter model: the app model.
    func attach(_ model: AppModel) {
        self.model = model
        for problem in loadProblems { model.logger.event("indoor", problem) }
        model.logger.event("indoor", ["action": "catalog", "scripts": scripts.map(\.id).joined(separator: ","),
                                      "walked": scripts.filter(\.walked).map(\.id).joined(separator: ","),
                                      "sim_rate": Self.environmentSimRate ?? 0])
        // Automation hook (simulator evidence): `CANEKIT_INDOOR_ROUTE=1` starts the ISR indoor route
        // 2 s after launch, like the Settings "Start indoor route" button. Pair it with
        // `CANEKIT_INDOOR_SIM_STEPS_PER_S` to walk it and hand over without moving. Skipped (logged
        // `auto_start_skipped`) when a route runs, waits or an indoor walk is already active by then
        // — `startIndoor` would stop that route (review round 9d).
        if ProcessInfo.processInfo.environment["CANEKIT_INDOOR_ROUTE"] == "1" {
            Task { @MainActor [weak model] in
                try? await Task.sleep(for: .seconds(2))
                guard let model else { return }
                guard !model.nav.isNavigating, !model.routeStartWaiting, !model.indoor.isActive else {
                    model.logger.event("indoor", ["action": "auto_start_skipped"])
                    return
                }
                model.startIndoorRouteForTesting()
            }
        }
    }

    // MARK: - Catalog

    /// Re-reads bundled `indoor_*.json` and Documents/indoor/*.json; invalid or unreadable files are
    /// skipped and remembered as `indoor {action: load_failed, file, problems}`. Callers: `init`,
    /// `saveRecording`.
    func reloadScripts() {
        loadProblems = []
        let bundledURLs = (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("indoor_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let recordedURLs = ((try? FileManager.default.contentsOfDirectory(at: Self.recordedDirectory,
                                                                         includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        scripts = IndoorScriptCatalog.merged(bundled: bundledURLs.compactMap(load),
                                             recorded: recordedURLs.compactMap(load))
    }

    /// One file → a valid script, or nil (and a remembered problem).
    private func load(_ url: URL) -> IndoorScript? {
        do {
            let script = try IndoorScript.load(from: Data(contentsOf: url))
            let problems = script.validate()
            guard problems.isEmpty else {
                loadProblems.append(["action": "load_failed", "file": url.lastPathComponent,
                                     "problems": problems.joined(separator: " ")])
                model?.logger.event("indoor", loadProblems.last!)
                return nil
            }
            return script
        } catch {
            loadProblems.append(["action": "load_failed", "file": url.lastPathComponent,
                                 "problems": error.localizedDescription])
            model?.logger.event("indoor", loadProblems.last!)
            return nil
        }
    }

    // MARK: - Walking

    /// Starts walking `script` (replacing an active walk silently). Speaks the draft caveat (if not
    /// walked) and step 0 at `.nav`, prefetches every line into the natural voice, and starts the
    /// step source: the environment simulation rate if set, else CMPedometer (unavailable → "next"
    /// only, logged). Logs `indoor {action: start, source, destination, pedometer}`.
    /// - Parameters:
    ///   - script: the script to walk.
    ///   - destination: where the outdoor leg goes, nil = the CIF demo route.
    ///   - source: "voice" / "settings", for the log.
    func start(script: IndoorScript, destination: String?, source: String) {
        guard let model else { return }
        if isActive { teardown() }
        generation &+= 1
        activeScript = script
        progress = IndoorProgress(script: script)
        handover = IndoorHandover(exit: script.exit)
        self.destination = destination
        lastSteps = 0
        isActive = true
        stepCount = script.steps.count
        scriptName = script.name
        var lines = script.steps.map(\.say) + script.steps.compactMap(\.landmark) + [script.exit.say]
        if !script.walked { lines.insert(IndoorProgress.notWalkedLine, at: 0) }
        model.speech.prefetch(lines)
        log("start", ["source": source, "destination": destination ?? "",
                      "pedometer": CMPedometer.isStepCountingAvailable()])
        var p = progress!
        let events = p.start()
        progress = p
        // Review round item 3: the island for the whole trip, before the first `setIndoor`. Its
        // static name is the trip's, because the outdoor leg reuses this activity after the handover.
        let tripName: String
        switch IndoorScriptCatalog.outdoorLeg(destination: destination) {
        case .demoRoute: tripName = AppModel.bundledRouteName.isEmpty ? script.name : AppModel.bundledRouteName
        case .navigate(let text): tripName = "To \(text)"
        }
        model.liveActivity.beginIndoor(name: tripName, say: p.currentSay, stepIndex: p.index,
                                       stepCount: script.steps.count)
        perform(events)
        if let rate = Self.environmentSimRate {
            simulate(rate: rate)
        } else {
            startPedometer()
        }
    }

    /// Ends the walk without speaking (Stop route speaks "Route stopped." itself). Logs
    /// `indoor {action: stop, reason}`. No-op when idle. Callers: `AppModel.stopRoute`.
    /// - Parameter reason: why, for the log.
    func stop(reason: String) {
        guard isActive else { return }
        log("stop", ["reason": reason])
        teardown()
    }

    /// "next" / watch Next / crown / the Guide's Next: advance one step whatever the count. At the
    /// exit it says the exit line again. Logs `indoor {action: next}`.
    func next() {
        guard isActive, var p = progress else { return }
        let events = p.next()
        progress = p
        log("next")
        if events.isEmpty {
            model?.speech.sayAgain(p.currentSay, .nav)
        } else {
            perform(events)
        }
    }

    /// "repeat" / watch Repeat / the Guide's Repeat: the current step's line (or the exit line)
    /// again, bypassing coalescing (`sayAgain`). Logs `indoor {action: repeat}`.
    func repeatLine() {
        guard isActive, !currentSay.isEmpty else { return }
        model?.speech.sayAgain(currentSay, .nav)
        log("repeat")
    }

    /// What "I'm outside" did.
    enum OutsideResult {
        /// No indoor walk is running.
        case notActive
        /// A recent good fix existed: the outdoor leg has started.
        case handedOver
        /// No usable fix yet: the next fix ≤ 20 m within the radius hands over.
        case waiting
    }

    /// "I'm outside" (`IndoorHandover.forced(now:)`). Speaks nothing; the caller speaks "Waiting
    /// for GPS outside." for `.waiting`. Logs `indoor {action: forced | forced_waiting}`.
    func walkerIsOutside() -> OutsideResult {
        guard isActive, var h = handover else { return .notActive }
        let done = h.forced(now: Self.wallClock())
        handover = h
        waitingForGPS = h.waitingForGPS
        log(done ? "forced" : "forced_waiting")
        if done {
            handOver(by: "forced")
            return .handedOver
        }
        return .waiting
    }

    /// Scene phase while walking (hook in `AppModel.scenePhaseChanged`): logs
    /// `indoor {action: paused_background}` / `resumed`. Speaks nothing and changes nothing: the
    /// pedometer pauses on its own while locked, GPS keeps running (`scenePhaseChanged` keeps it
    /// while `isActive`), and `IndoorHandover`'s GPS-only run can hand over without the exit.
    /// No-op when idle.
    /// - Parameter active: true on `.active`, false on `.background`.
    func sceneChanged(active: Bool) {
        guard isActive else { return }
        log(active ? "resumed" : "paused_background")
    }

    /// Every GPS fix (one hook line in `AppModel.wireNavigation`): feeds the exit window while
    /// recording and the handover gate while walking.
    /// - Parameter fix: the fix, `timestamp` on the wall clock.
    func ingest(_ fix: GeoFix) {
        if var a = exitAverager {
            a.add(lat: fix.coordinate.latitude, lon: fix.coordinate.longitude, accuracyM: fix.accuracy,
                  t: Self.clock())
            exitAverager = a
        }
        guard isActive, var h = handover else { return }
        let done = h.fix(lat: fix.coordinate.latitude, lon: fix.coordinate.longitude,
                         accuracyM: fix.accuracy, now: fix.timestamp)
        handover = h
        waitingForGPS = h.waitingForGPS
        if done { handOver(by: "gps") }
    }

    /// The Guide's "Simulate walk" while indoors, or the environment rate at start: synthetic
    /// cumulative steps (continuing from the last count) every 0.5 s instead of the pedometer; on a
    /// step with no count, "next" after `IndoorSimSteps.nextOnlyWaitS`; at the exit, a 5 m fix at the
    /// exit coordinate every second so the handover runs. Logs
    /// `indoor {action: sim_start, rate}`.
    /// - Parameter rate: steps per second.
    func simulate(rate: Double = IndoorSimSteps.defaultRate) {
        guard isActive else { return }
        pedometer.stopUpdates()
        simTask?.cancel()
        let gen = generation
        let base = lastSteps
        let started = Self.clock()
        isSimulating = true
        log("sim_start", ["rate": rate])
        simTask = Task { @MainActor [weak self] in
            var sinceFix = 0.0
            var stalledSteps = 0.0       // seconds on a step with no count
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled, self.isActive, self.generation == gen else { return }
                if self.atExit, let exit = self.activeScript?.exit {
                    sinceFix += 0.5
                    if sinceFix >= 1 {
                        sinceFix = 0
                        self.model?.location.ingest(fix: GeoFix(coordinate: exit.coordinate, accuracy: 5, speed: 0,
                                                                timestamp: Self.wallClock()), course: nil)
                    }
                } else if let p = self.progress, p.script.steps.indices.contains(p.index),
                          p.script.steps[p.index].steps == nil {
                    // A "next"-only step: the simulated walker says next after `nextOnlyWaitS`.
                    stalledSteps += 0.5
                    if stalledSteps >= IndoorSimSteps.nextOnlyWaitS {
                        stalledSteps = 0
                        self.next()
                    }
                } else {
                    stalledSteps = 0
                    self.feed(steps: base + IndoorSimSteps.steps(rate: rate, elapsedS: Self.clock() - started),
                              generation: gen)
                }
            }
        }
    }

    /// "Stop simulation" while indoors: stops the synthetic steps (the walker continues with "next").
    func stopSimulation() {
        guard isSimulating else { return }
        simTask?.cancel()
        simTask = nil
        isSimulating = false
        log("sim_stop")
    }

    /// Live CMPedometer counts from now into `feed`.
    /// ⚠ The handler must stay `@Sendable` (see the header and TripTracker.startPedometer).
    private func startPedometer() {
        guard CMPedometer.isStepCountingAvailable() else {
            log("pedometer_unavailable")
            return
        }
        let gen = generation
        pedometer.startUpdates(from: Date()) { @Sendable [weak self] data, error in
            let count = data?.numberOfSteps.intValue
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                if let message { self.log("pedometer_error", ["error": message]) }
                if let count {
                    self.feed(steps: count, generation: gen)
                } else {
                    self.logPedometerNil("walking")
                }
            }
        }
    }

    /// `indoor {action: pedometer_nil, source}` rate-limited per source (review round 9b).
    /// - Parameter source: "walking" or "recording".
    private func logPedometerNil(_ source: String) {
        guard pedometerNilLog.allow(source, now: Self.clock()) else { return }
        log("pedometer_nil", ["source": source])
    }

    /// One cumulative count into the step machine.
    private func feed(steps: Int, generation gen: UInt64) {
        guard isActive, gen == generation, var p = progress else { return }
        lastSteps = max(lastSteps, steps)
        let events = p.update(stepsWalked: steps)
        progress = p
        perform(events)
    }

    /// Performs `IndoorProgress` events in order: speak (`.nav`, ttl 20, logged `say` with the text),
    /// log `advanced`, arm the handover at the exit (`exit`). Then mirrors the machine's state.
    private func perform(_ events: [IndoorEvent]) {
        guard let model else { return }
        if let p = progress {
            stepIndex = p.index
            atExit = p.atExit
            currentSay = p.currentSay
        }
        // Step 64: the Live Activity shows "Step i of n" and this step's line (no-op without an
        // activity — an indoor script never starts one).
        model.liveActivity.setIndoor(stepIndex: stepIndex, stepCount: stepCount, say: currentSay)
        for event in events {
            switch event {
            case .say(let line):
                model.speech.say(line, .nav, ttl: Self.lineTTL)
                log("say", ["text": line])
            case .advanced:
                log("advanced")
            case .reachedExit:
                if var h = handover {
                    h.reachedExit()
                    handover = h
                }
                log("exit")
            }
        }
    }

    /// The gate opened: log, end the indoor leg silently, start the outdoor leg. A simulated indoor
    /// walk to CIF continues as a simulated outdoor walk (`startSimulatedWalk` starts the demo route).
    /// The outdoor leg reuses the indoor walk's Live Activity; if it did not even begin (location
    /// refused, self-test running) the activity is ended (`endIfIdle`) instead of freezing.
    private func handOver(by trigger: String) {
        guard let model else { return }
        let target = destination
        let wasSimulating = isSimulating
        let leg = IndoorScriptCatalog.outdoorLeg(destination: target)
        log("handover", ["by": trigger, "destination": target ?? ""])
        teardown()
        switch leg {
        case .demoRoute:
            if wasSimulating { model.startSimulatedWalk() } else { model.startDemoRoute() }
        case .navigate(let text):
            model.navigate(to: text)
        }
        if !model.nav.isNavigating, !model.routeStartWaiting, !model.isBuildingRoute {
            model.liveActivity.endIfIdle()
        }
    }

    /// Stops every source and clears the walking state (no speech, no log).
    private func teardown() {
        generation &+= 1
        pedometer.stopUpdates()
        simTask?.cancel()
        simTask = nil
        isSimulating = false
        isActive = false
        progress = nil
        handover = nil
        activeScript = nil
        destination = nil
        stepIndex = 0
        stepCount = 0
        atExit = false
        waitingForGPS = false
        currentSay = ""
        scriptName = nil
        // Step 64: leave the island's indoor phase (the handover's outdoor route, or Stop, takes over).
        model?.liveActivity.setIndoor(stepIndex: nil, stepCount: 0, say: nil)
    }

    /// `indoor {action, index, count, steps, walked, script, …extra}` (never `t` / `kind`).
    private func log(_ action: String, _ extra: [String: Any] = [:]) {
        var fields: [String: Any] = ["action": action, "index": stepIndex, "count": stepCount,
                                     "steps": lastSteps, "walked": activeScript?.walked ?? false,
                                     "script": activeScript?.id ?? ""]
        fields.merge(extra) { _, new in new }
        model?.logger.event("indoor", fields)
    }

    // MARK: - Recording

    /// "Start recording": pedometer + 10 Hz yaw into a fresh `IndoorRecorder`, GPS warmed for the
    /// exit. Refused while an indoor walk runs. Spoken at `.nav`; logs `indoor {action: record_start}`.
    func startRecording() {
        guard let model, !isRecording else { return }
        guard !isActive else {
            recordingSay("Stop the indoor route before recording.")
            return
        }
        recordGeneration &+= 1
        let gen = recordGeneration
        recorder = IndoorRecorder()
        yawUnwrapper = IndoorYawUnwrapper()
        isRecording = true
        recordingFinished = false
        isFinishingExit = false
        awaitingLandmark = false
        recordedStepCounts = recorder.stepCountsSoFar
        recordedLandmarkCount = 0
        model.location.start()
        let hasPedometer = CMPedometer.isStepCountingAvailable()
        if hasPedometer {
            // ⚠ @Sendable, hop to main (TripTracker crash note).
            recordPedometer.startUpdates(from: Date()) { @Sendable [weak self] data, _ in
                let count = data?.numberOfSteps.intValue
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording, self.recordGeneration == gen else { return }
                    guard let count else {
                        self.logPedometerNil("recording")
                        return
                    }
                    self.record(.stepCount(count, t: Self.clock()), generation: gen)
                }
            }
        }
        let hasMotion = motion.isDeviceMotionAvailable
        if hasMotion {
            motion.deviceMotionUpdateInterval = IndoorRecorder.yawSampleIntervalS
            // Delivered on main: the closure runs on the main queue, so assumeIsolated holds.
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, _ in
                let yaw = data?.attitude.yaw
                MainActor.assumeIsolated {
                    guard let self, let yaw, let deg = self.yawUnwrapper.unwrap(radians: yaw) else { return }
                    self.record(.yaw(deg, t: Self.clock()), generation: gen)
                }
            }
        }
        log("record_start", ["pedometer": hasPedometer, "motion": hasMotion, "id": recordingID])
        recordingSay("Recording started. Walk to the exit door. Tap Add landmark to name what you pass.")
    }

    /// One recorder event of the current recording.
    private func record(_ event: IndoorRecorder.Event, generation gen: UInt64) {
        guard isRecording, gen == recordGeneration, !recordingFinished else { return }
        recorder.handle(event)
        recordedStepCounts = recorder.stepCountsSoFar
    }

    /// "Add landmark": arms the one-shot transcript hook for `IndoorRecorder.landmarkWindowS` and
    /// opens push-to-talk (`AppModel.startVoiceInput`). Logs `indoor {action: record_landmark_listen}`.
    /// After the exit is recorded it says so instead of ignoring the tap (Muse M11).
    func addLandmark() {
        guard let model, isRecording else { return }
        guard !recordingFinished else {
            recordingSay("The exit is already recorded. Tap Save.")
            return
        }
        landmarkDeadline = Self.clock() + IndoorRecorder.landmarkWindowS
        awaitingLandmark = true
        recordingStatus = "Listening for the landmark…"
        log("record_landmark_listen")
        model.startVoiceInput()
    }

    /// The voice path's one-shot hook (`AppModel.start()`'s `onTranscriptionFinalized`): while a
    /// landmark is awaited and not expired, the transcript becomes the landmark instead of a
    /// conversation query. Review round item 1: a command (`IndoorRecorder.isLandmarkText` false —
    /// Stop route, "I'm outside", emergency, yes / no, blank) is not consumed, disarms the hook and
    /// reaches the conversation; logged `record_landmark_command`. Logs
    /// `indoor {action: record_landmark, text}` for a landmark.
    /// - Parameter text: the finalized transcript.
    /// - Returns: true when it was consumed (the conversation must not see it).
    func takeTranscript(_ text: String) -> Bool {
        guard awaitingLandmark else { return false }
        awaitingLandmark = false
        guard let deadline = landmarkDeadline, Self.clock() <= deadline, isRecording, !recordingFinished else {
            log("record_landmark_expired")
            return false
        }
        landmarkDeadline = nil
        guard IndoorRecorder.isLandmarkText(text) else {
            log("record_landmark_command", ["text": text])
            recordingStatus = "Not added as a landmark. Tap Add landmark to try again."
            return false
        }
        recorder.handle(.landmark(text, t: Self.clock()))
        recordedLandmarkCount += 1
        log("record_landmark", ["text": text])
        recordingSay("Landmark added: \(text)")
        return true
    }

    /// "Finish at the exit": opens the `IndoorExitAverager` window (fixes arrive through `ingest`),
    /// polls until it is done, then stores the mean of the good fixes, else the last fix ≤ 30 m of
    /// the window, else the last known fix if ≤ 30 m and ≤ 20 s old. No usable fix → says so and
    /// stays open for another try. A tap after the exit is recorded, or while the window is open,
    /// speaks why nothing happens (Muse M11).
    func finishAtExit() {
        guard let model, isRecording else { return }
        guard !recordingFinished else {
            recordingSay("The exit is already recorded. Tap Save.")
            return
        }
        guard exitTask == nil else {
            recordingSay("Still reading GPS at the exit. Hold still.")
            return
        }
        isFinishingExit = true
        exitAverager = IndoorExitAverager(startedAt: Self.clock())
        model.location.start()
        recordingSay("Hold still at the exit door for a few seconds.")
        let gen = recordGeneration
        exitTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.recordGeneration == gen else { return }
                guard let a = self.exitAverager, a.isDone(now: Self.clock()) else { continue }
                self.completeExit(fallback: self.model?.location.fix)
                return
            }
        }
    }

    /// Closes the exit window: records `.finish` or reports that no usable fix exists. The
    /// last-known `fallback` counts only when `IndoorExitAverager.usableFallback` (≤ 30 m, ≤ 20 s
    /// old; review round item 6) — a stale indoor fix saved as the exit would misplace every handover.
    /// - Parameter fallback: `LocationService.fix` when the window closed.
    private func completeExit(fallback: GeoFix?) {
        exitTask = nil
        isFinishingExit = false
        let averaged = exitAverager?.result()
        let good = exitAverager?.goodFixCount ?? 0
        exitAverager = nil
        let usable = fallback.flatMap { fix in
            IndoorExitAverager.usableFallback(accuracyM: fix.accuracy, ageS: Self.wallClock() - fix.timestamp)
                ? fix : nil
        }
        guard let exit = averaged ?? usable?.coordinate else {
            log("record_finish_no_fix")
            recordingSay("No GPS fix. Step outside the door and tap Finish at the exit again.")
            return
        }
        recorder.handle(.finish(lat: exit.latitude, lon: exit.longitude, t: Self.clock()))
        recordingFinished = true
        stopRecordingSensors()
        log("record_finish", ["good_fixes": good, "fallback": averaged == nil,
                              "lat": exit.latitude, "lon": exit.longitude])
        let steps = recordedStepCounts.filter { $0 > 0 }.count
        recordingSay("Exit recorded. \(steps == 1 ? "1 step" : "\(steps) steps"). Tap Save.")
    }

    /// Save: builds the script (name, aliases, outdoor place, exit line and radius copied from the
    /// catalog script with the same id, e.g. the ISR draft), validates it, writes
    /// Documents/indoor/<id>.json and reloads the catalog. Logs `indoor {action: record_save, id, steps}`.
    func saveRecording() {
        guard isRecording else { return }
        guard recordingFinished else {
            recordingSay("Tap Finish at the exit before saving.")
            return
        }
        let id = IndoorScriptCatalog.sanitizedID(recordingID)
        let base = scripts.first { $0.id == id }
        let date = Date().formatted(.iso8601.year().month().day())
        guard let script = recorder.script(
            id: id, name: base?.name ?? "Recorded indoor route",
            fromAliases: base?.fromAliases ?? [id.replacingOccurrences(of: "_", with: " ")],
            outdoorPlaceID: base?.outdoorPlaceID ?? "isr", recordedAt: date,
            exitSay: base?.exit.say ?? IndoorRecorder.defaultExitSay,
            radiusM: base?.exit.radiusM ?? IndoorScript.defaultRadiusM) else {
            recordingSay("Nothing was recorded. Walk some steps, then finish at the exit.")
            return
        }
        let problems = script.validate()
        guard problems.isEmpty else {
            log("record_save_invalid", ["problems": problems.joined(separator: " ")])
            recordingSay("Recording not saved. \(problems[0])")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try FileManager.default.createDirectory(at: Self.recordedDirectory, withIntermediateDirectories: true)
            try encoder.encode(script).write(to: Self.recordedDirectory.appendingPathComponent("\(id).json"),
                                             options: .atomic)
        } catch {
            log("record_save_failed", ["error": error.localizedDescription])
            recordingSay("Recording not saved. \(error.localizedDescription)")
            return
        }
        recordGeneration &+= 1
        isRecording = false
        reloadScripts()
        log("record_save", ["id": id, "steps": script.steps.count,
                            "landmarks": script.steps.compactMap(\.landmark).count])
        recordingSay("Indoor route saved. \(script.steps.count == 1 ? "1 step" : "\(script.steps.count) steps").")
    }

    /// "Cancel recording": stops the sensors and discards the recording. Logs `record_cancel`.
    func cancelRecording() {
        guard isRecording else { return }
        recordGeneration &+= 1
        stopRecordingSensors()
        exitTask?.cancel()
        exitTask = nil
        exitAverager = nil
        isFinishingExit = false
        awaitingLandmark = false
        isRecording = false
        log("record_cancel")
        recordingSay("Recording canceled.")
    }

    /// Stops the recording pedometer and device motion.
    private func stopRecordingSensors() {
        recordPedometer.stopUpdates()
        motion.stopDeviceMotionUpdates()
    }

    /// Shows a recording line on the card and speaks it at `.nav` (the teammate may be looking at
    /// the corridor, not the screen).
    private func recordingSay(_ line: String) {
        recordingStatus = line
        model?.speech.say(line, .nav, ttl: 10)
    }
}
