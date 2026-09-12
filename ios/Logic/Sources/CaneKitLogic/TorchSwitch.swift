//
//  TorchSwitch.swift
//  CaneKitLogic
//
//  The flashlight switch as a small state machine: what the on-screen switch shows, when a
//  request counts as done, and what is spoken about it.
//
//  Why it exists (measured, trip log canekit-2026-09-12T20-57-17Z, t = 106–120 s): the app set
//  the torch and read `AVCaptureDevice.isTorchActive` on the very next line. iOS updates that
//  property asynchronously, so the read was the OLD state: the switch snapped back, "The
//  flashlight did not switch on." was spoken, the torch then came on anyway, and every change took
//  two presses. The switch now shows the request at once, the device's own report (KVO on
//  `isTorchActive`) confirms it, and the settle deadline decides failure. Step 34 review (agents,
//  Muse, Antigravity): a window stays open to its deadline so a quick OFF→ON's late reports are
//  never announced as the device acting alone, and the deadline ticks with `now: .infinity`.
//
//  Pure: Foundation-only, clock injected, no AVFoundation. The app (`AppModel.setTorch`, the
//  torch observer and its deadline task) owns the device and the speech.
//  Tests: `TorchSwitchTests.swift`.
//

import Foundation

/// Flashlight switch state: the displayed value, the request waiting for the device, and the
/// outcome of each device report or deadline tick.
///
/// Owner: `AppModel` (main actor). Callers feed `request` when the walker flips the switch,
/// `report` whenever the device's `isTorchActive` changes (KVO — never a read on the line after
/// setting it, which is exactly the stale value this type exists for), and `tick` when the settle
/// deadline passes.
public struct TorchSwitch: Sendable, Equatable {

    /// Numeric tuning for the switch.
    public struct Configuration: Sendable, Equatable {
        /// Seconds a request may wait for the device to report the requested state before it is
        /// declared failed. ⚠ 2 s is a generous HYPOTHESIS, not a measurement: a torch normally
        /// settles well under half a second, and the deadline only has to outlast that without
        /// leaving a real failure (thermal refusal) unannounced for long. Pinned by
        /// `TorchSwitchTests.settleWindowDefaultAndClamp`.
        public let settleSeconds: TimeInterval

        /// Creates a configuration; negative values clamp to 0, non-finite ones fall back to 2 s.
        public init(settleSeconds: TimeInterval = 2.0) {
            self.settleSeconds = settleSeconds.isFinite ? max(0, settleSeconds) : 2.0
        }
    }

    /// What one `report` or `tick` decided. Each case except `.none` is spoken once.
    public enum Outcome: Sendable, Equatable {
        /// Nothing to say: a stale report while settling, a repeat, or an idle tick.
        case none
        /// The device reached the requested state.
        case confirmed(on: Bool)
        /// The settle deadline passed and the device is not in the requested state.
        case failed(requested: Bool)
        /// The torch changed with no request pending (e.g. a thermal cut-out).
        case changedByDevice(on: Bool)

        /// The fixed line the app speaks for this outcome; nil for `.none`.
        /// Pinned by `TorchSwitchTests.spokenLines`.
        public var spokenLine: String? {
            switch self {
            case .none: return nil
            case .confirmed(let on): return on ? "Flashlight on." : "Flashlight off."
            case .failed(let requested):
                return requested ? "The flashlight did not switch on." : "The flashlight did not switch off."
            case .changedByDevice(let on): return on ? "The flashlight turned on." : "The flashlight turned off."
            }
        }

        /// Seconds the line may wait in the speech queue: 4 for a confirmation the walker is
        /// expecting, 12 for news they are not (a failure or a change they did not ask for must not
        /// expire unheard behind route speech). Pinned by `TorchSwitchTests.queueLifetimes`.
        public var queueSeconds: TimeInterval {
            switch self {
            case .none, .confirmed: return 4
            case .failed, .changedByDevice: return 12
            }
        }
    }

    /// Every line an outcome can speak, for `AppModel.commonLines` to prefetch (a cache miss would
    /// hold the speech queue and duck the beacon while it fetches). Pinned to the outcomes by
    /// `TorchSwitchTests.allSpokenLinesMatchOutcomes`.
    public static let allSpokenLines = [
        "Flashlight on.", "Flashlight off.",
        "The flashlight did not switch on.", "The flashlight did not switch off.",
        "The flashlight turned on.", "The flashlight turned off.",
    ]

    /// The tuning in use.
    public let configuration: Configuration
    /// What the on-screen switch shows: the latest request while its window is open, else the
    /// device state.
    public private(set) var displayed = false
    /// The latest request's settle window: its state, its deadline on the caller's clock, and
    /// whether a matching report already confirmed (and spoke) it.
    private var pending: (on: Bool, deadline: TimeInterval, confirmed: Bool)?
    /// The last device state this machine saw, so repeated identical reports stay silent.
    private var lastReported = false

    /// Creates a switch that starts off (the torch is off at every launch).
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// True while the latest request's settle window is open (until its deadline `tick`).
    public var isSettling: Bool { pending != nil }

    /// The walker flipped the switch. Shows the request at once and opens its settle window;
    /// a newer request replaces any open one (its reports then count toward the new one).
    public mutating func request(_ on: Bool, now: TimeInterval) {
        displayed = on
        pending = (on, now + configuration.settleSeconds, false)
    }

    /// The device reported `isTorchActive`.
    ///
    /// Inside a window, the first report matching the request confirms it (spoken once); every
    /// other report is recorded silently — it is the walker's own earlier requests landing (a
    /// quick OFF→ON sends the OFF's report late), not the device acting alone, and the switch keeps
    /// showing the request. The deadline `tick` decides what really happened. With no window open,
    /// a change is the device acting on its own (`.changedByDevice`, e.g. a thermal cut-out).
    public mutating func report(active: Bool, now: TimeInterval) -> Outcome {
        if var p = pending {
            lastReported = active
            guard active == p.on, !p.confirmed else { return .none }
            p.confirmed = true
            pending = p
            return .confirmed(on: active)
        }
        guard active != lastReported else { return .none }
        lastReported = active
        displayed = active
        return .changedByDevice(on: active)
    }

    /// The clock moved. At or after the window's deadline it closes against the device's current
    /// state: silent if a report already confirmed it and the device still agrees; `.confirmed` if
    /// the device agrees but no report said so; `.changedByDevice` if it was confirmed and has since
    /// changed; `.failed` if it never got there. The switch then shows the device state.
    /// `AppModel`'s deadline task passes `now: .infinity` — the task *is* the deadline, so no clock
    /// comparison can leave the window open (`infiniteTickAlwaysResolves`).
    public mutating func tick(active: Bool, now: TimeInterval) -> Outcome {
        guard let p = pending, now >= p.deadline else { return .none }
        pending = nil
        displayed = active
        lastReported = active
        if active == p.on { return p.confirmed ? .none : .confirmed(on: active) }
        return p.confirmed ? .changedByDevice(on: active) : .failed(requested: p.on)
    }

    /// Equality over everything observable: tuning, displayed value, open window, last report.
    public static func == (lhs: TorchSwitch, rhs: TorchSwitch) -> Bool {
        lhs.configuration == rhs.configuration && lhs.displayed == rhs.displayed
            && lhs.pending?.on == rhs.pending?.on && lhs.pending?.deadline == rhs.pending?.deadline
            && lhs.pending?.confirmed == rhs.pending?.confirmed && lhs.lastReported == rhs.lastReported
    }
}
