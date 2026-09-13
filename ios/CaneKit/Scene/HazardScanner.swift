//
//  HazardScanner.swift
//  CaneKit
//
//  The camera's second job: while the LiDAR lanes watch waist-to-head, this reads the scene for
//  hazards a map does not know about.
//    · Signs (on-device Vision text, every `signPeriod` s): "Sign: sidewalk closed." — once per
//      sign per minute (CaneKitLogic.SignPolicy).
//    · Hazard watch (every 8 s while walking a route): one frame to the vision model — the cloud
//      provider when a key is set, else the on-device client — asking only for path hazards;
//      "NONE" stays silent, a hazard becomes "Caution: 3 meters ahead, cones."
//      (CaneKitLogic.HazardWatchPolicy).
//  Ground hazards (drop-offs, potholes, curbs) come from LiDAR in DepthFrameProcessor, not here.
//
//  Every spoken hazard goes out through `onHazard` so AppModel can speak it (`.obstacle`, TTL 8 s
//  for a sign, 6 s for a caution) and write it to the hazard map (HazardLog) with the current GPS
//  fix and the frame. Nothing here buzzes: the cane taps belong to LiDAR ground hazards
//  (`AppModel.groundHazardFound`), which never pass through this class.
//
//  Why it exists: the LiDAR lanes see *that* something is there, not *what* it says or whether it
//  is a cone. Reading signs and asking a vision model are the camera's only contributions to
//  safety beyond depth, and both are slow (Vision text, a network round trip), so they live on
//  their own 500 ms loop instead of the ~30 Hz depth path.
//
//  Owner: `AppModel.hazards` (built in `AppModel.init` with the shared `VLMClient`; wired and
//  started by `AppModel.wireHazards`; stopped on background and while "Both cameras" pauses
//  ARKit; `paused` while the phone is hot). UI: `HazardsCard` (toggles, last lines, provider).
//  Tests: the decisions are pure and live in CaneKitLogic — `HazardTests` (`SignPolicy`,
//  `HazardWatchPolicy`: `signsAreReadOnceAndSpecifically`, `hazardWatchAsksOnlyWhileWalkingAndRarely`,
//  `hazardWatchRepliesBecomeShortCautions`, `aLateReplyLosesItsDistance`, …) and
//  `SignPhraseFilterTests` (CueProfileTests.swift, `signAllowedPhrases`). This class itself is
//  exercised end to end by `make e2e SCENARIO=streetview` (`scan` / `hazard_watch` log records).
//
//  Threading / isolation: `@MainActor @Observable`. The loop is a main-actor Task that awaits
//  `@concurrent` helpers for the expensive parts (JPEG encode, Vision, network), so the main
//  thread only does bookkeeping. At most one hazard-watch request is in flight.
//

import CaneKitLogic
import Foundation
import Observation

/// Where a hazard came from. The raw value is the `source` field of the trip log's `hazard`
/// event (`AppModel.recordHazard`) and, for signs and vision, also the hazard-map record's `kind`
/// (a ground hazard's kind is its `GroundHazard.kind` instead). `AppModel.onHazard` also keys the
/// speech TTL on it (sign 8 s, caution 6 s).
///
/// Cases: `ground` — a LiDAR ground hazard (drop-off / hole / curb / low obstacle), produced by
/// `AppModel.groundHazardFound`, never by `HazardScanner`; `sign` — a sign phrase read on-device
/// by `scanSigns` ("Sign: sidewalk closed."); `vision` — a hazard-watch caution from the vision
/// model (`runWatch`).
enum HazardSource: String, Sendable {
    case ground, sign, vision
}

/// The camera's hazard loop: on-device sign reading every `signPeriod` s and, while walking a
/// route, one vision-model hazard check every 8 s. Emits spoken lines through `onHazard` and
/// what it saw through `onDiagnostic`; owns no speech, haptics or log of its own.
/// Owner: `AppModel.hazards`. Main actor.
@MainActor
@Observable
final class HazardScanner {

    // MARK: Published (UI)

    /// True between `start()` and `stop()` (the loop task exists). Not shown in the UI today.
    private(set) var isRunning = false
    /// Last sign line spoken, for the Hazards card.
    private(set) var lastSign: String?
    /// Last hazard-watch caution spoken.
    private(set) var lastCaution: String?
    /// Which backend the hazard watch uses: `watchClient.name`, fixed at init ("Muse + On-device"
    /// with a cloud key, "On-device" without one). Shown as a pill on `HazardsCard`, logged as
    /// `provider` in every `hazard_watch` record.
    private(set) var watchProvider: String
    /// Round-trip of the last hazard-watch request (ms), measured from just before
    /// `watchClient.describe` to its return (excludes the JPEG encode). nil after a failure.
    private(set) var lastWatchMs: Int?
    /// Who answered the last hazard-watch request ("Muse" / "On-device"), from the client's
    /// `lastHazardOutcome` (a bare client answers for itself). nil before the first reply and
    /// after a failure. Shown on the Scene engine card (Step 47).
    private(set) var lastWatchSource: String?
    /// Why the cloud did not answer the last hazard-watch request ("The request timed out." after
    /// `FallbackVLMClient.hazardDeadline`); nil when it did, or with no cloud. Scene engine card.
    private(set) var lastWatchReason: String?
    /// When the last hazard-watch reply landed (any client); nil before the first. The Scene
    /// engine card turns it into "30 s ago".
    private(set) var lastWatchAt: Date?
    /// `HazardWatchPolicy.interval` (8 s): how often the watch asks while a route guides. Exposed
    /// so the Scene engine card's words come from the policy's number, not a second literal.
    var watchInterval: TimeInterval { watchPolicy.interval }
    /// `FallbackVLMClient.hazardDeadline` in seconds (2.5), or nil when the client has no cloud —
    /// the same number the card says as "on-device after 2.5 s".
    var hazardCloudDeadlineS: TimeInterval? {
        guard let d = watchClient.hazardCloudDeadline else { return nil }
        return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }
    /// "Hazard watch: <localized error>" from the last failed request; cleared by the next reply.
    /// Shown in red on `HazardsCard`. Sign scans never set it (Vision failures yield no text).
    private(set) var lastError: String?

    /// "Read signs" switch. Default here is true, but `AppModel.init` overwrites it from the
    /// persisted `AppModel.signsEnabled` (default on) and its `didSet` keeps it in step.
    var signsEnabled = true
    /// "Hazard watch" switch. Default here is true, but `AppModel.init` overwrites it from the
    /// persisted `AppModel.hazardWatchEnabled` — ⚠ **off by default** until tuned on the cane —
    /// and `CANEKIT_HAZARD_WATCH=1` (Street View e2e) forces it on without persisting.
    /// Checked at ask time and again when the reply lands (a reply after switch-off is silent).
    var watchEnabled = true
    /// Sign phrases that may be spoken (nil = all). Set by `AppModel.applyCueRules` from
    /// `CueRules.allowedSignPhrases` (Quiet / Indoors: safety signs only); forwarded to
    /// `SignPolicy.allowedPhrases`.
    @ObservationIgnored var signAllowedPhrases: Set<String>? {
        get { signPolicy.allowedPhrases }
        set { signPolicy.allowedPhrases = newValue }
    }

    /// Output: (spoken line, source, JPEG of the frame it came from). Called on the main actor,
    /// once per line the policies decided to say. `AppModel.wireHazards` speaks it at `.obstacle`
    /// and records it in `HazardLog` + the trip log (`hazard {type, text, source}`).
    @ObservationIgnored var onHazard: ((String, HazardSource, Data?) -> Void)?
    /// The vision model described a weapon or an attacker. Fired from the **raw** reply, before
    /// `HazardWatchPolicy` decides whether to speak anything: that policy exists to keep the
    /// soundscape calm and will happily drop a repeat, which is right for "kerb ahead" and wrong
    /// for a gun. Rate limiting for the family alert happens in `FamilyAlertPolicy.threat`.
    @ObservationIgnored var onThreat: ((ThreatSighting, Data?) -> Void)?
    /// Diagnostics for the trip log (AppModel → `logger.event(kind, fields)`): one `scan` record
    /// per sign scan (what text was read, what was said) and one `hazard_watch` record per hazard-watch
    /// reply (reply, latency, and why it was dropped). Without these a walk log, or the Street
    /// View mock, only shows what was spoken, never what the camera saw.
    /// Fields: `scan {texts (first 8), said ("" when silent), frame}`; `hazard_watch {reply, ms,
    /// provider, source, cloud_ms, fallback_reason, frame, said | dropped: "stale"}` or
    /// `hazard_watch {error, provider}`. `source` is who answered ("Muse" / "On-device"),
    /// `cloud_ms` how long the cloud took or was given (−1 without a cloud), `fallback_reason` the
    /// cloud's error when on-device answered ("" otherwise) — Step 47. `frame` is
    /// the `FrameReplay` file name in the simulator, "" on the phone. Never name a field `t` or
    /// `kind` (`TripLogRecord` owns those; e2e.py fails a run on `field_kind`).
    @ObservationIgnored var onDiagnostic: ((String, [String: Any]) -> Void)?
    /// Inputs polled by the loop (set by `AppModel.wireHazards`).
    /// True while a route is guiding (`nav.isNavigating`); the hazard watch only asks then.
    @ObservationIgnored var isNavigating: () -> Bool = { false }
    /// Walking speed in m/s from the last GPS fix, or 0 when there is none or it is older than 5 s
    /// (CoreLocation stops sending fixes while standing, so a stale speed would keep the watch
    /// asking at a curb). Gates `HazardWatchPolicy.shouldAsk` (> 0.5 m/s) and sizes `maxReplyAge`.
    @ObservationIgnored var currentSpeed: () -> Double = { 0 }

    // MARK: Private

    /// Source of camera frames (`jpegSnapshot`); the same instance `DepthEngine` feeds, so a
    /// snapshot is the latest ARKit frame (or a Street View frame under `FrameReplay`).
    @ObservationIgnored private let processor: DepthFrameProcessor
    /// The shared vision client (`VLMClientFactory.resolved`); for `FallbackVLMClient` a hazard
    /// prompt gets 2.5 s of cloud, then the on-device answer (`OnDeviceHazards`).
    @ObservationIgnored private let watchClient: any VLMClient
    /// The 500 ms loop task; nil when stopped. `start()` is idempotent on it.
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// Which sign phrases to say and when (once per phrase per minute, size rules, cue-level
    /// filter). Value type from CaneKitLogic; persists its "last said" stamps for the app's life.
    @ObservationIgnored private var signPolicy = SignPolicy()
    /// When to ask the vision model (8 s interval, walking only) and how to turn a reply into a
    /// short caution ("NONE" → silent).
    @ObservationIgnored private var watchPolicy = HazardWatchPolicy()
    /// True from the tick that launches `runWatch` until it returns (`defer`): at most one hazard
    /// request in flight, however slow the network is.
    @ObservationIgnored private var watchInFlight = false
    /// Reference-date seconds of the last sign scan that had a frame; −∞ so the first tick scans,
    /// and reset to −∞ when a scan found no frame so the next 500 ms tick retries.
    @ObservationIgnored private var lastSignScan: TimeInterval = -.infinity
    /// Seconds between sign scans (text recognition is the costly half of Vision). Nothing
    /// overrides the 3 s default today. A scan that finds no frame does not use up its slot.
    var signPeriod: TimeInterval = 3
    /// Set by AppModel from the thermal state (`updateThermal`: `.serious` / `.critical`): when
    /// hot, skip sign scans and the hazard watch (ARKit + LiDAR keep the lanes and haptics alive;
    /// the camera extras are optional). Also read by `LiveView.state` as "hot" for the live view.
    var paused = false
    /// A hazard-watch reply about a frame older than this (s) is not spoken: the walker has moved.
    /// Scaled by walking speed at request time: ~4 m of walking, capped at 5 s (1.2 m/s → 3.3 s).
    /// Speeds under 0.5 m/s count as 0.5, so standing or slow always gets the 5 s cap.
    /// ⚠ A number in the app rather than in CaneKitLogic, and not unit-tested; lengthening it
    /// speaks hazards the walker has already passed. Change it only with a device walk with the
    /// hazard watch on (review round 5 set these ages).
    /// - Parameter speed: m/s at request time (`currentSpeed()`).
    /// - Returns: the oldest reply age, in seconds, that may still be spoken.
    static func maxReplyAge(speed: Double) -> TimeInterval { min(5, 4 / max(speed, 0.5)) }
    /// Replies older than this (s) keep their hazard but lose any spoken distance ("3 meters"
    /// was measured from where the walker stood when the frame was taken). The strip itself is
    /// `HazardWatchPolicy.withoutDistance` (pinned by `aLateReplyLosesItsDistance`).
    var distanceFreshFor: TimeInterval = 2

    /// Builds an idle scanner; nothing runs until `start()`.
    /// - Parameters:
    ///   - processor: `depth.processor`, the source of camera frames.
    ///   - watchClient: the app's one resolved `VLMClient` (shared with `SceneDescriber`); its
    ///     `name` becomes `watchProvider`.
    init(processor: DepthFrameProcessor, watchClient: any VLMClient) {
        self.processor = processor
        self.watchClient = watchClient
        self.watchProvider = watchClient.name
    }

    // MARK: Lifecycle

    /// Starts the 500 ms loop. Idempotent (`guard loop == nil`). Callers: `AppModel.wireHazards`
    /// (launch, after the depth engine), the return to `.active`, and every path that resumes
    /// ARKit after "Both cameras" (`resumeARKitPipelines`, a failed or ended two-camera start).
    /// The task holds `self` weakly, so a released scanner ends its own loop.
    func start() {
        guard loop == nil else { return }
        isRunning = true
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                await self?.tick()
            }
        }
    }

    /// Cancels the loop. Callers: `AppModel.scenePhaseChanged(.background)` (no scanning a frozen
    /// last frame) and "Both cameras" on (ARKit paused, no frames). A hazard-watch request already
    /// in flight is not cancelled; its reply is dropped only if `watchEnabled` / `paused` say so.
    func stop() {
        loop?.cancel()
        loop = nil
        isRunning = false
    }

    // MARK: Loop

    /// One 500 ms loop step. Does nothing while `paused`. Otherwise:
    ///   · hazard watch — when enabled, a route is guiding, nothing is in flight and
    ///     `HazardWatchPolicy.shouldAsk` agrees (> 0.5 m/s, ≥ 8 s since the last ask), launches
    ///     `runWatch` in an **unawaited** Task, so a slow network never stalls sign reading;
    ///   · signs — when enabled and `signPeriod` has passed, awaits `scanSigns` (signs are read
    ///     with or without a route).
    private func tick() async {
        let now = Date().timeIntervalSinceReferenceDate
        guard !paused else { return }
        if watchEnabled, isNavigating(), !watchInFlight,
           watchPolicy.shouldAsk(now: now, speed: currentSpeed()) {
            watchInFlight = true
            Task { [weak self] in await self?.runWatch() }
        }
        if signsEnabled, now - lastSignScan >= signPeriod {
            lastSignScan = now
            await scanSigns(now: now)
        }
    }

    /// One sign scan: a 1280 px, quality 0.8 JPEG (small letters survive compression) → Vision
    /// text only → `SignPolicy.line(for: seenTexts)` → `onHazard(.sign)` when a phrase is due.
    /// Always emits one `scan` diagnostic when it had a frame, even when nothing was said.
    /// - Parameter now: the tick's reference-date seconds (the policy's repeat clock).
    private func scanSigns(now: TimeInterval) async {
        let frameName = FrameReplay.shared.currentName ?? ""
        guard let jpeg = await Self.snapshot(processor, maxDimension: 1280, quality: 0.8) else {
            // No fresh frame (just unlocked, ARKit stalled): don't spend the 3 s slot on nothing;
            // retry on the next 500 ms tick (Muse camera review).
            lastSignScan = -.infinity
            return
        }
        // Text only: classification here would be thrown away (review: wasted CPU every scan).
        // Small text (down to 1/128 of the frame, 10 px on the 1280 px scan): measured with
        // scripts/sign_probe.swift on the route frames, 7.5 cm letters on a flat, frontal sign read
        // from ≈ 7 m and 15 cm from ≈ 14 m (Vision's default: 1.7 m / 3.5 m), at no measurable extra
        // cost; expect less on a moving cane. Far text only counts for multi-word safety phrases:
        // one-word phrases (EXIT, PUSH …) must be ≥ 1/80 tall (SignPolicy.shortPhraseMinHeight),
        // so storefront words across the street stay quiet (Muse + Antigravity, Step 12).
        let d = await OnDeviceVision.detect(jpeg: jpeg, readText: true, classify: false,
                                            minTextHeight: 1.0 / 128)
        let line = signPolicy.line(for: d.seenTexts, now: now)
        if let line {
            lastSign = line
            onHazard?(line, .sign, jpeg)
        }
        onDiagnostic?("scan", ["texts": d.texts.prefix(8).map { $0.0 }, "said": line ?? "",
                               "frame": frameName])
    }

    /// One hazard-watch request: a 768 px JPEG (quality 0.6) → `watchClient.describe(prompt:
    /// HazardPrompt.text)` → age checks → `HazardWatchPolicy.line(forReply:)` → `onHazard(.vision)`.
    /// No frame → `watchPolicy.refund` (retry in 2 s instead of waiting 8). `maxAge` is fixed at
    /// request time from the speed then. The reply is silent (and unlogged) if the switch went
    /// off or the phone got hot while it was in flight; a reply older than `maxAge` is logged
    /// `dropped: "stale"` and not spoken; older than `distanceFreshFor` it loses its metres.
    /// Clears `watchInFlight` on every exit.
    private func runWatch() async {
        defer { watchInFlight = false }
        guard let jpeg = await Self.snapshot(processor, maxDimension: 768) else {
            watchPolicy.refund(now: Date().timeIntervalSinceReferenceDate)   // no frame: retry in 2 s
            return
        }
        let started = Date()
        let maxAge = Self.maxReplyAge(speed: currentSpeed())
        let frameName = FrameReplay.shared.currentName ?? ""
        do {
            var reply = try await watchClient.describe(jpeg: jpeg, prompt: HazardPrompt.text)
            let age = Date().timeIntervalSince(started)
            lastWatchMs = Int(age * 1000)
            lastError = nil
            // Provenance for the Scene engine card: a `FallbackVLMClient` says who won the race and
            // why the cloud lost; a bare client answered for itself.
            let outcome = watchClient.lastHazardOutcome
            lastWatchSource = outcome?.answeredBy ?? watchClient.name
            lastWatchReason = outcome?.fallbackReason
            lastWatchAt = Date()
            // Switched off (or paused hot) while the request was in flight: say nothing
            // (Antigravity review: a reply arrived seconds after the toggle went off).
            guard watchEnabled, !paused else { return }
            // A slow round trip describes where the walker *was*: drop it rather than announce a
            // hazard that is now behind them, and drop a stale distance from a late-but-usable one.
            var fields: [String: Any] = ["reply": reply, "ms": lastWatchMs ?? -1, "provider": watchProvider,
                                         "frame": frameName,
                                         // Who actually answered and why the cloud did not (Step 47).
                                         "source": lastWatchSource ?? "", "cloud_ms": outcome?.cloudMs ?? -1,
                                         "fallback_reason": lastWatchReason ?? ""]
            guard age <= maxAge else {
                fields["dropped"] = "stale"
                onDiagnostic?("hazard_watch", fields)
                return
            }
            // Checked on the raw reply and before the age gate: a weapon a second ago still
            // matters, even when the distance in the sentence has gone stale.
            if let sighting = ThreatWatch.sighting(in: reply) {
                fields["threat"] = sighting.term
                onThreat?(sighting, jpeg)
            }
            if age > distanceFreshFor { reply = HazardWatchPolicy.withoutDistance(reply) }
            let spoken = watchPolicy.line(forReply: reply, now: Date().timeIntervalSinceReferenceDate)
            fields["said"] = spoken ?? ""
            onDiagnostic?("hazard_watch", fields)
            if let line = spoken {
                lastCaution = line
                onHazard?(line, .vision, jpeg)
            }
        } catch {
            lastWatchMs = nil                  // a failed request has no round trip to show
            lastWatchSource = nil              // nobody answered
            lastWatchReason = nil
            lastWatchAt = Date()
            lastError = "Hazard watch: \(error.localizedDescription)"
            onDiagnostic?("hazard_watch", ["error": error.localizedDescription, "provider": watchProvider])
        }
    }

    /// JPEG of the latest camera frame, encoded off the main actor. `@concurrent` is load-bearing:
    /// a static method of this main-actor class would otherwise encode on main (tens of ms per
    /// scan, every 3 s). `DepthFrameProcessor` is Sendable, so passing it across is safe.
    /// - Parameters:
    ///   - p: the frame source.
    ///   - maxDimension: longest side in pixels (1280 for signs, 768 for the hazard watch).
    ///   - quality: JPEG quality 0…1.
    /// - Returns: the JPEG, or nil when there is no fresh frame (just unlocked, ARKit stalled).
    @concurrent
    private static func snapshot(_ p: DepthFrameProcessor, maxDimension: CGFloat,
                                 quality: CGFloat = 0.6) async -> Data? {
        p.jpegSnapshot(maxDimension: maxDimension, quality: quality)
    }
}
