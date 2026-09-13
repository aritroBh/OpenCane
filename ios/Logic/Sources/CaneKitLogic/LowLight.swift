//
//  LowLight.swift
//  CaneKitLogic
//
//  Is it dark? A blind walker cannot tell, and every camera-based feature degrades silently in the
//  dark: ARKit's visual tracking (`trackingNormal` → `DepthReadiness`), sign reading
//  (`HazardScanner`), the on-device scene words and people detection (`OnDeviceVision`), the cloud
//  "Where am I" (`SceneDescriber`) and the hazard watch. LiDAR depth, the gyro gate, GPS, the compass
//  and haptics do not care. So the app has to notice the dark for the walker, say what still works,
//  light the torch when that is safe, and stop the vision features from guessing (Step 49, the
//  owner's question of 2026-09-12 22:50).
//
//  Why it is here: the decision has numbers in it (lux thresholds, dwell times, a smoothing constant),
//  so it lives in the logic package with tests (AGENTS.md hard rule 3), fed by the app with ARKit's
//  `ARFrame.lightEstimate?.ambientIntensity` (lux; Apple's docs put a well-lit room near 1000) carried
//  in `LaneReport.ambientLux` at the report cadence (~30 Hz).
//
//  ⚠ Every number below is a research HYPOTHESIS [H], not a measurement: 40 lux is "a dim hallway
//  at night" and 120 lux "a lit corridor" on the usual lux tables; the 3 s / 5 s dwells are the same
//  order as the other debounce windows in this app (head episodes 4 s, arrival two fixes). A dark-room
//  walk with the `light` trip-log records is what tunes them; until then `defaultsAreTheDesign` pins
//  them so a change is a decision, not drift.
//
//  Key invariants:
//    · `unknown` until the first estimate; nil estimates (the simulator, a paused session) change
//      nothing and report no edge.
//    · Hysteresis with a dwell in both directions: dark needs the SMOOTHED lux under `darkLux` for
//      `enterSeconds`; lit needs it over `litLux` for `exitSeconds`. A headlight or a shadow never
//      toggles the state (`flickerDoesNotToggle`).
//    · The torch is only ever lit while a route guides (a flashlight in a pocket is a burn risk and a
//      dead battery — the rule `AppModel.torchEnabled` already follows), only when the phone has one,
//      only with the setting on, and never when the walker lit it themselves.
//    · The spoken line is produced on the enter edge only — once per darkness episode.
//  Isolation: nonisolated `Sendable` values; `LowLightPolicy` is single-owner (`AppModel.lowLight`,
//  main actor). Clock: ARKit's `frame.timestamp` seconds, the same clock as `CueDecider`.
//  Tests: `LowLightTests.swift` (11, suite "Low light").
//

import Foundation

/// The dark / lit decision: an EMA over ARKit's ambient-light estimate with a dwell in each direction.
///
/// Owner: `AppModel.lowLight` (main actor), stepped once per `LaneReport` in `AppModel.handle(_:)`
/// with `report.ambientLux` and `report.timestamp`. The app acts on `Step.didEnterDark` /
/// `didExitDark` (torch, speech, log) and shows `state` / `smoothedLux` on the Guide card's DARK pill
/// and the Scene engine card's Light row.
public struct LowLightPolicy: Sendable, Equatable {

    /// The numbers. ⚠ All [H] — see the file header.
    public struct Configuration: Sendable, Equatable {
        /// Smoothed lux below which the scene counts as dark (after `enterSeconds`). 40 lux [H]:
        /// a dim hallway at night; a lit room is ~1000 (ARKit's docs), a street lamp's pool 10–50.
        public let darkLux: Float
        /// Smoothed lux above which the scene counts as lit again (after `exitSeconds`). 120 lux
        /// [H], three times `darkLux`, so a street-lamp pool (10–50 lux) cannot end an episode.
        public let litLux: Float
        /// Seconds the smoothed lux must stay under `darkLux` before the state flips to dark.
        /// 3 s [H]: longer than a doorway shadow, shorter than the walk into a dark room matters.
        public let enterSeconds: TimeInterval
        /// Seconds the smoothed lux must stay over `litLux` before the state flips back to lit.
        /// 5 s [H]: a passing headlight is ~1 s; a lit crossing is longer.
        public let exitSeconds: TimeInterval
        /// EMA time constant, seconds. 0.3 s [H] ≈ 9 frames at 30 Hz: a frame-noise filter for
        /// ARKit's per-frame estimate (auto-exposure steps), NOT the debounce — the dwells are.
        /// From 600 lux it reaches 40 in ~0.9 s, so a dark room flips at ~3.9 s, not 6.
        public let smoothingSeconds: TimeInterval
        /// Minimum seconds an app-lit torch stays on before the policy may declare `lit` again.
        /// 60 s [H]: a floor against flapping on any reading at all.
        public let minTorchOnSeconds: TimeInterval
        /// While the torch is app-lit, the smoothed lux must exceed THIS (not `litLux`) to end the
        /// episode. 400 lux [H]: ⚠ `ambientIntensity` is an auto-exposure proxy and the torch
        /// itself raises it — a torch-lit wall a metre away reads on the order of 100–300, a lit
        /// room or daylight ≥ 1000 (ARKit's docs) — so with the plain 120 lux exit the torch would
        /// switch itself off by its own glow, the dark would return 3 s later, and the torch would
        /// cycle 60 s on / ~4 s off forever (review, Step 49). With this the episode ends only on
        /// light the torch cannot have made: dawn, a lit building, a lit crossing.
        public let litWithTorchLux: Float
        /// Seconds the auto-torch stays off after the device cut it (`TorchSwitch.Outcome
        /// .changedByDevice(on: false)`, a thermal cut-out). 60 s [H]: long enough for the LED to
        /// cool, short enough to try again on the same block.
        public let torchBackoffSeconds: TimeInterval

        /// While app-lit and the reading sits in the dead zone (`litLux` < lux ≤ `litWithTorchLux`),
        /// the app switches the torch off for `probeSeconds` (1 s) every `probeIntervalSeconds`
        /// (60 s) to read the true ambient light; over `litLux` with the torch off ends the episode,
        /// otherwise the torch comes back. Without the probe a torch lit in the dark would never
        /// go off in a room the torch itself lifts to 250 lux (Muse review). [H]
        public let probeIntervalSeconds: TimeInterval
        /// How long the probe's torch-off lasts before the reading is judged (the 0.3 s EMA needs
        /// ~1 s to settle). [H]
        public let probeSeconds: TimeInterval

        /// Creates a configuration; a negative lux clamps to 0, `litLux` is kept above `darkLux`,
        /// negative dwells clamp to 0, a non-finite dwell falls back to its default, and a
        /// non-positive or non-finite smoothing constant falls back to 0.3 s.
        public init(darkLux: Float = 40, litLux: Float = 120,
                    enterSeconds: TimeInterval = 3, exitSeconds: TimeInterval = 5,
                    smoothingSeconds: TimeInterval = 0.3,
                    minTorchOnSeconds: TimeInterval = 60, torchBackoffSeconds: TimeInterval = 60,
                    litWithTorchLux: Float = 400,
                    probeIntervalSeconds: TimeInterval = 60, probeSeconds: TimeInterval = 1.0) {
            self.probeIntervalSeconds = probeIntervalSeconds.isFinite ? max(1, probeIntervalSeconds) : 60
            self.probeSeconds = probeSeconds.isFinite ? max(0.3, probeSeconds) : 1.0
            let dark = darkLux.isFinite ? max(0, darkLux) : 40
            self.darkLux = dark
            self.litLux = litLux.isFinite ? max(dark + 1, litLux) : max(dark + 1, 120)
            self.litWithTorchLux = litWithTorchLux.isFinite ? max(self.litLux, litWithTorchLux) : max(self.litLux, 400)
            self.enterSeconds = enterSeconds.isFinite ? max(0, enterSeconds) : 3
            self.exitSeconds = exitSeconds.isFinite ? max(0, exitSeconds) : 5
            self.smoothingSeconds = (smoothingSeconds.isFinite && smoothingSeconds > 0) ? smoothingSeconds : 0.3
            self.minTorchOnSeconds = minTorchOnSeconds.isFinite ? max(0, minTorchOnSeconds) : 60
            self.torchBackoffSeconds = torchBackoffSeconds.isFinite ? max(0, torchBackoffSeconds) : 60
        }
    }

    /// Battery percent at or below which the auto-torch never lights: `FamilyAlertLimits
    /// .lowBatteryPct` (20 %), the same number the family gets a `battery` event at — the phone is
    /// the only computer on this cane, and a torch at 20 % trades guidance minutes for light.
    /// Pinned by `lowBatteryNeverAutoLights`.
    public static let minBatteryPct = FamilyAlertLimits().lowBatteryPct

    /// The light level as the app knows it. Raw values are a trip-log contract (`light {state}`)
    /// and the Scene engine card's word; add cases, never rename them.
    public enum State: String, Sendable, Codable, CaseIterable {
        /// No estimate yet (before the first ARKit frame, or in the simulator).
        case unknown
        /// Not dark: the default once an estimate exists.
        case lit
        /// The smoothed lux stayed under `darkLux` for `enterSeconds`.
        case dark
    }

    /// What one `update` decided.
    public struct Step: Sendable, Equatable {
        /// The state after this update.
        public let state: State
        /// True on the one update that flipped `lit` / `unknown` → `dark`.
        public let didEnterDark: Bool
        /// True on the one update that flipped `dark` → `lit`.
        public let didExitDark: Bool
        /// The smoothed lux after this update; nil before the first estimate.
        public let smoothedLux: Float?
    }

    /// The numbers in use.
    public let configuration: Configuration
    /// The current state; `unknown` until the first estimate.
    public private(set) var state: State = .unknown
    /// The EMA of the estimates so far; nil before the first.
    public private(set) var smoothedLux: Float?
    /// ARKit time of the last update with an estimate; nil before the first.
    private var lastUpdate: TimeInterval?
    /// When the smoothed lux first went under `darkLux` in the current run; nil when it is not under.
    private var underSince: TimeInterval?
    /// When the smoothed lux first went over `litLux` in the current run; nil when it is not over.
    private var overSince: TimeInterval?
    /// `now` of the first update that saw `torchByApp == true` in the current lighting; nil while
    /// the app's torch is off. Holds `dark` for `minTorchOnSeconds` (see the configuration).
    private var appTorchSince: TimeInterval?
    /// Until when the auto-torch is backed off after a device cut-out; −∞ = not backed off.
    private var torchBackoffUntil: TimeInterval = -.infinity
    /// ARKit time of the last probe's start; −∞ = never.
    private var lastProbeAt: TimeInterval = -.infinity
    /// True between `beginProbe` and `endProbe` (the torch is off to read the true ambient).
    public private(set) var probing = false

    /// Should the app switch its torch off for a moment to read the true ambient light? True when
    /// dark, app-lit past the minimum on-time, the reading is in the dead zone
    /// (`litLux` < lux ≤ `litWithTorchLux`) and the last probe is ≥ `probeIntervalSeconds` ago.
    /// Pinned by `deadZoneProbeEndsEpisodeOnlyOnRealLight`.
    public func probeDue(now: TimeInterval) -> Bool {
        guard state == .dark, !probing, let since = appTorchSince, let lux = smoothedLux else { return false }
        guard now - since >= configuration.minTorchOnSeconds else { return false }
        guard lux > configuration.litLux, lux <= configuration.litWithTorchLux else { return false }
        return now - lastProbeAt >= configuration.probeIntervalSeconds
    }

    /// The app has switched its torch off for the probe. `update` keeps running meanwhile with
    /// `torchByApp: false` so the EMA settles on the ambient reading.
    public mutating func beginProbe(now: TimeInterval) {
        probing = true
        lastProbeAt = now
    }

    /// The probe is over: true when the ambient reading (torch off) is over `litLux` — the
    /// episode ends (`state` becomes `.lit`, the torch stays off); false when it is still dark —
    /// the app re-lights the torch and the episode continues, `appTorchSince` kept so the minimum
    /// on-time is not restarted.
    public mutating func endProbe(now: TimeInterval) -> Bool {
        probing = false
        guard let lux = smoothedLux, lux > configuration.litLux else { return false }
        state = .lit
        overSince = nil
        underSince = nil
        return true
    }

    /// Creates a policy in the `unknown` state.
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// One frame. `lux` is `ARFrame.lightEstimate?.ambientIntensity` (nil when ARKit gave none);
    /// `now` is the frame's ARKit timestamp (seconds); `torchByApp` is `AppModel.torchLitByApp`
    /// (the app's own torch is on, which raises the reading). Returns the state and the edges.
    ///
    /// nil keeps everything as it was. A `now` earlier than the last update (a new AR session's
    /// clock) restarts the EMA and both dwell timers but keeps the state, so a session restart in
    /// the dark neither flips to lit nor re-announces the dark (`clockJumpBackResetsDwellOnly`).
    /// While `torchByApp` is true, `dark` → `lit` also waits out `minTorchOnSeconds` from the
    /// first frame that saw the torch on (`appTorchStaysOnAMinute`).
    /// Pinned by `darkNeedsThreeSecondsUnderForty`, `litNeedsFiveSecondsOverOneTwenty`,
    /// `flickerDoesNotToggle`, `unknownUntilFirstEstimate`.
    public mutating func update(lux: Float?, now: TimeInterval, torchByApp: Bool = false) -> Step {
        if torchByApp {
            if appTorchSince == nil { appTorchSince = now }
        } else if !probing {
            appTorchSince = nil                  // a probe's torch-off is not the walker's choice
        }
        guard let lux, lux.isFinite else {
            return Step(state: state, didEnterDark: false, didExitDark: false, smoothedLux: smoothedLux)
        }
        let sample = max(0, lux)
        if let previous = smoothedLux, let last = lastUpdate, now >= last {
            // Time-based EMA: alpha = 1 − e^(−dt/τ), so a 60 Hz and a 30 Hz stream smooth alike and a
            // long gap (a paused session) simply adopts the new sample.
            let dt = now - last
            let alpha = Float(1 - exp(-dt / configuration.smoothingSeconds))
            smoothedLux = previous + alpha * (sample - previous)
        } else {
            smoothedLux = sample            // first estimate, or a clock that jumped back
            underSince = nil
            overSince = nil
            if torchByApp { appTorchSince = now }   // the old clock's value would be meaningless
            torchBackoffUntil = -.infinity
        }
        lastUpdate = now
        let value = smoothedLux ?? sample

        // Dwell bookkeeping on the smoothed value.
        if value < configuration.darkLux {
            if underSince == nil { underSince = now }
        } else {
            underSince = nil
        }
        // The exit threshold is higher while the app's own torch is lighting the scene.
        let exitLux = torchByApp ? configuration.litWithTorchLux : configuration.litLux
        if value > exitLux {
            if overSince == nil { overSince = now }
        } else {
            overSince = nil
        }

        let before = state
        switch state {
        case .unknown:
            // Not dark → lit at once (nothing to warn about). Dark → wait the full dwell, so one odd
            // first frame (auto-exposure still settling) cannot light the torch.
            if value >= configuration.darkLux {
                state = .lit
            } else if let since = underSince, now - since >= configuration.enterSeconds {
                state = .dark
            }
        case .lit:
            if let since = underSince, now - since >= configuration.enterSeconds { state = .dark }
        case .dark:
            // An app-lit torch is the likeliest reason the reading rose: hold for its minimum
            // on-time as well as the dwell.
            let torchHeld = appTorchSince.map { now - $0 < configuration.minTorchOnSeconds } ?? false
            if let since = overSince, now - since >= configuration.exitSeconds, !torchHeld { state = .lit }
        }
        return Step(state: state,
                    didEnterDark: before != .dark && state == .dark,
                    didExitDark: before == .dark && state == .lit,
                    smoothedLux: smoothedLux)
    }

    /// The device switched an app-lit torch off on its own (`TorchSwitch.Outcome
    /// .changedByDevice(on: false)` — a thermal cut-out): back the auto-torch off for
    /// `torchBackoffSeconds` from `now` (ARKit clock, the caller's last report time). The state
    /// itself is untouched — it is still dark. Pinned by `thermalCutOutBacksOffAMinute`.
    public mutating func torchCutByDevice(now: TimeInterval) {
        torchBackoffUntil = now + configuration.torchBackoffSeconds
        appTorchSince = nil
    }

    /// Whether the app may light the torch now: not inside a device-cut backoff, and the battery
    /// (percent; nil or negative = unknown, allowed) above `minBatteryPct`. `LowLightAdvice.decide`
    /// takes the answer as `autoTorchAllowed`. Pinned by `thermalCutOutBacksOffAMinute`,
    /// `lowBatteryNeverAutoLights`.
    public func canAutoLight(now: TimeInterval, batteryPct: Int?) -> Bool {
        guard now >= torchBackoffUntil else { return false }
        if let pct = batteryPct, pct >= 0, pct <= Self.minBatteryPct { return false }
        return true
    }
}

/// What to do about the light: light the torch, say a line, tell the vision features to admit the
/// dark. Pure: the app passes what it knows and applies the answer.
///
/// Caller: `AppModel.lowLightChanged` on every `LowLightPolicy.Step` whose state or edges matter,
/// and `AppModel.startRouteNow` (a route starting in a room that is already dark).
public struct LowLightAdvice: Sendable, Equatable {
    /// Switch the back-camera torch on (through `AppModel.setTorch(_:byApp:)`, the KVO-confirmed
    /// path). Only ever true while a route guides — a flashlight in a pocket is a burn risk and a
    /// dead battery — only when the phone has a torch that is off, and only with the setting on.
    public let turnTorchOn: Bool
    /// The line to speak at `.nav` (10 s TTL), or nil. Set on the enter edge only, so it is said
    /// once per darkness episode; `darkLineWithTorch` when the app is lighting the torch with it.
    public let spokenLine: String?
    /// True while it is dark and no torch is lit: `SceneDescriber` prefixes "It is dark, so this
    /// may miss things. " and `HazardScanner` logs `light: "dark"`. False when a torch is on (the
    /// cameras have light again) and when it is not dark.
    public let visionCaveat: Bool

    /// Spoken once per darkness episode when the app does not light the torch. ⚠ Byte-identical to
    /// the entry in `AppModel.commonLines` (prefetched); pinned by `adviceSpeaksOncePerEpisode`.
    public static let darkLine = "Low light. Obstacle detection still works."
    /// The same line when the app is lighting the torch with it. The `TorchSwitch` confirmation
    /// ("Flashlight on.") is then not spoken again — `AppModel.applyTorch` mutes the duplicate.
    public static let darkLineWithTorch = "Low light. Obstacle detection still works. Flashlight on."
    /// Every line this type can produce, for the voice prefetch list.
    public static let allSpokenLines = [darkLine, darkLineWithTorch]

    /// The decision.
    /// - Parameters:
    ///   - state: the policy's state after this update.
    ///   - entered: `Step.didEnterDark` — this update is the start of a darkness episode (or a route
    ///     starting in the dark, which the app treats as an entry for the torch and the line).
    ///   - torchOn: `AppModel.torchEnabled` (the switch as shown).
    ///   - torchAvailable: the phone has a back-camera torch.
    ///   - navigating: `nav.isNavigating`.
    ///   - autoTorch: the "Flashlight on in the dark (routes)" setting.
    ///   - autoTorchAllowed: `LowLightPolicy.canAutoLight(now:batteryPct:)` — false inside a
    ///     thermal backoff or at ≤ 20 % battery; the line is then the plain one.
    /// Pinned by `adviceTurnsTorchOnOnlyOnARoute`, `adviceSpeaksOncePerEpisode`,
    /// `lowBatteryNeverAutoLights`.
    public static func decide(state: LowLightPolicy.State, entered: Bool, torchOn: Bool,
                              torchAvailable: Bool, navigating: Bool, autoTorch: Bool = true,
                              autoTorchAllowed: Bool = true) -> LowLightAdvice {
        guard state == .dark else {
            return LowLightAdvice(turnTorchOn: false, spokenLine: nil, visionCaveat: false)
        }
        let light = entered && autoTorch && autoTorchAllowed && navigating && torchAvailable && !torchOn
        let line: String? = entered ? (light ? darkLineWithTorch : darkLine) : nil
        return LowLightAdvice(turnTorchOn: light, spokenLine: line,
                              visionCaveat: !(torchOn || light))
    }
}
