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
//      "NONE" stays silent, a hazard becomes "Caution: cones ahead, 3 meters."
//      (CaneKitLogic.HazardWatchPolicy).
//  Ground hazards (drop-offs, potholes, curbs) come from LiDAR in DepthFrameProcessor, not here.
//
//  Every spoken hazard goes out through `onHazard` so AppModel can speak it, buzz, and write it to
//  the hazard map (HazardLog) with the current GPS fix and the frame.
//
//  Threading / isolation: `@MainActor @Observable`. The loop is a main-actor Task that awaits
//  `@concurrent` helpers for the expensive parts (JPEG encode, Vision, network), so the main
//  thread only does bookkeeping. At most one hazard-watch request is in flight.
//

import CaneKitLogic
import Foundation
import Observation

/// Where a hazard came from (for the log, the UI and the haptic choice).
enum HazardSource: String, Sendable {
    case ground, sign, vision
}

@MainActor
@Observable
final class HazardScanner {

    // MARK: Published (UI)

    private(set) var isRunning = false
    /// Last sign line spoken, for the Hazards card.
    private(set) var lastSign: String?
    /// Last hazard-watch caution spoken.
    private(set) var lastCaution: String?
    /// Which backend the hazard watch uses ("Muse", "Gemini", "On-device", …).
    private(set) var watchProvider: String
    /// Round-trip of the last hazard-watch request (ms).
    private(set) var lastWatchMs: Int?
    private(set) var lastError: String?

    /// User toggles (persisted by AppModel).
    var signsEnabled = true
    var watchEnabled = true

    /// Output: (spoken line, source, JPEG of the frame it came from).
    @ObservationIgnored var onHazard: ((String, HazardSource, Data?) -> Void)?
    /// Diagnostics for the trip log (AppModel → `logger.event(kind, fields)`): one `scan` record
    /// per sign scan (what text was read, what was said) and one `hazard_watch` record per hazard-watch
    /// reply (reply, latency, and why it was dropped). Without these a walk log, or the Street
    /// View mock, only shows what was spoken, never what the camera saw.
    @ObservationIgnored var onDiagnostic: ((String, [String: Any]) -> Void)?
    /// Inputs polled by the loop (set by AppModel).
    @ObservationIgnored var isNavigating: () -> Bool = { false }
    @ObservationIgnored var currentSpeed: () -> Double = { 0 }

    // MARK: Private

    @ObservationIgnored private let processor: DepthFrameProcessor
    @ObservationIgnored private let watchClient: any VLMClient
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var signPolicy = SignPolicy()
    @ObservationIgnored private var watchPolicy = HazardWatchPolicy()
    @ObservationIgnored private var watchInFlight = false
    @ObservationIgnored private var lastSignScan: TimeInterval = -.infinity
    /// Seconds between sign scans (text recognition is the costly half of Vision).
    var signPeriod: TimeInterval = 3
    /// Set by AppModel from the thermal state: when hot, skip sign scans and the hazard watch
    /// (ARKit + LiDAR keep the lanes and haptics alive; the camera extras are optional).
    var paused = false
    /// A hazard-watch reply about a frame older than this (s) is not spoken: the walker has moved.
    /// Scaled by walking speed at request time: ~4 m of walking, capped at 5 s (1.2 m/s → 3.3 s).
    static func maxReplyAge(speed: Double) -> TimeInterval { min(5, 4 / max(speed, 0.5)) }
    /// Replies older than this (s) keep their hazard but lose any spoken distance ("3 meters"
    /// was measured from where the walker stood when the frame was taken).
    var distanceFreshFor: TimeInterval = 2

    init(processor: DepthFrameProcessor, watchClient: any VLMClient) {
        self.processor = processor
        self.watchClient = watchClient
        self.watchProvider = watchClient.name
    }

    // MARK: Lifecycle

    /// Idempotent. Called once the depth engine is running (AppModel.start).
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

    func stop() {
        loop?.cancel()
        loop = nil
        isRunning = false
    }

    // MARK: Loop

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

    private func runWatch() async {
        defer { watchInFlight = false }
        guard let jpeg = await Self.snapshot(processor, maxDimension: 768) else { return }
        let started = Date()
        let maxAge = Self.maxReplyAge(speed: currentSpeed())
        let frameName = FrameReplay.shared.currentName ?? ""
        do {
            var reply = try await watchClient.describe(jpeg: jpeg, prompt: HazardPrompt.text)
            let age = Date().timeIntervalSince(started)
            lastWatchMs = Int(age * 1000)
            lastError = nil
            // A slow round trip describes where the walker *was*: drop it rather than announce a
            // hazard that is now behind them, and drop a stale distance from a late-but-usable one.
            var fields: [String: Any] = ["reply": reply, "ms": lastWatchMs ?? -1, "provider": watchProvider,
                                         "frame": frameName]
            guard age <= maxAge else {
                fields["dropped"] = "stale"
                onDiagnostic?("hazard_watch", fields)
                return
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
            lastError = "Hazard watch: \(error.localizedDescription)"
            onDiagnostic?("hazard_watch", ["error": error.localizedDescription, "provider": watchProvider])
        }
    }

    /// JPEG of the latest camera frame, encoded off the main actor.
    @concurrent
    private static func snapshot(_ p: DepthFrameProcessor, maxDimension: CGFloat,
                                 quality: CGFloat = 0.6) async -> Data? {
        p.jpegSnapshot(maxDimension: maxDimension, quality: quality)
    }
}
