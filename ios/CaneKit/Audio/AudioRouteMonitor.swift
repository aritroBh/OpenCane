//
//  AudioRouteMonitor.swift
//  CaneKit
//
//  Knows whether the user is wearing headphones, and which. The beacon is only meaningful in
//  headphones (a spatial click through the cane-mounted speaker is just noise), speech should be
//  private, and the head-tracked beacon needs AirPods Pro / Max / 3rd-gen specifically. Watches
//  `AVAudioSession.routeChangeNotification` (main queue) and publishes the current output route.
//
//  Read-only with respect to the audio session: it never sets a category, mode, option or
//  preferred route (the one `.playback` session is configured by `SpeechQueue`, AGENTS.md hard
//  rule 7). Because that session has no Bluetooth options, AirPods arrive as A2DP (stereo, HRTF
//  capable), never HFP — which is also why HFP is not counted as "headphones" here.
//
//  Threading / isolation: `@MainActor`. The observer is registered with `queue: .main`, so its
//  closure provably runs on the main thread and `MainActor.assumeIsolated` is the legal bridge
//  (hard rule 1); the notification payload is ignored and the route is re-read on main.
//
//  Consumers: `AppModel.wireAudioRoute()` copies `headphonesConnected` into
//  `BeaconEngine.headphonesConnected` (the beacon only plays into headphones — AGENTS.md) and
//  speaks "<name> connected." / "Headphones disconnected. Beacon paused."; GuideCard shows the
//  state.
//

import AVFoundation
import Foundation
import Observation

/// Publishes whether the current audio output is a headphone route, and its name.
/// Owned by `AppModel`.
@MainActor
@Observable
final class AudioRouteMonitor {

    /// True when the current output is a headphone route (Bluetooth A2DP/LE, wired, USB).
    private(set) var headphonesConnected = false
    /// Product name from the route ("Aritro's AirPods Pro") or the port type ("Speaker").
    /// Prefers the headphone port's name; otherwise the first output's name; "Speaker" if none.
    private(set) var outputName = "Speaker"
    /// Best-effort: the output name contains "AirPods" (head tracking needs Pro/Max/3rd gen; the
    /// HeadPoseTracker reports the truth once motion data flows).
    var isAirPods: Bool { outputName.localizedCaseInsensitiveContains("AirPods") }

    /// Called on every change with (connected, name); the AppModel speaks the line.
    /// Fires on the main actor, only when `headphonesConnected` flips (not on every route
    /// notification, e.g. category changes), and never for the initial state read by `start()`.
    @ObservationIgnored var onChange: ((Bool, String) -> Void)?
    /// Called immediately on every raw flip (no debounce): the beacon must stop the moment the
    /// AirPods drop, not click from the cane speaker for 2 s (review).
    @ObservationIgnored var onImmediateChange: ((Bool) -> Void)?
    /// Route-change observer token; non-nil once started (makes `start()` idempotent).
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {}

    /// Read the current route (without notifying) and begin observing route changes.
    /// Idempotent. Never stopped — the monitor lives as long as the app. Caller:
    /// `AppModel.wireAudioRoute()` at launch.
    func start() {
        guard observer == nil else { return }
        refresh(notify: false)
        announced = headphonesConnected
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(notify: true) }
        }
    }

    /// Re-read the route; `notify` fires `onChange` only when the headphone state actually flipped.
    private func refresh(notify: Bool) {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        // No `.bluetoothHFP`: a mono call-quality route cannot carry a directional (HRTF) click.
        let headphonePorts: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothLE, .headphones, .usbAudio]
        let wearing = outputs.first { headphonePorts.contains($0.portType) }
        let wasConnected = headphonesConnected
        headphonesConnected = wearing != nil
        outputName = wearing?.portName ?? outputs.first?.portName ?? "Speaker"
        if notify, wasConnected != headphonesConnected {
            onImmediateChange?(headphonesConnected)
            // Debounce 2 s: after a phone call the route flaps through the receiver / HFP and back,
            // which would speak "disconnected" then "connected" with the AirPods still in (Muse L2).
            pending?.cancel()
            let now = headphonesConnected
            pending = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, self.headphonesConnected == now,
                      now != self.announced else { return }
                self.announced = now
                self.onChange?(now, self.outputName)
            }
        }
    }

    /// Debounce state: the pending announcement and the last state actually announced.
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var announced: Bool?
}
