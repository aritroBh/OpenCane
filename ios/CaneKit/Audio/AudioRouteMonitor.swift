//
//  AudioRouteMonitor.swift
//  CaneKit
//
//  Knows whether the user is wearing headphones, and which. The beacon is only meaningful in
//  headphones (a spatial click through the cane-mounted speaker is just noise), speech should be
//  private, and the head-tracked beacon needs AirPods Pro / Max / 3rd-gen specifically. Watches
//  `AVAudioSession.routeChangeNotification` (main queue) and publishes the current output route.
//

import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class AudioRouteMonitor {

    /// True when the current output is a headphone route (Bluetooth A2DP/LE, wired, USB).
    private(set) var headphonesConnected = false
    /// Product name from the route ("Aritro's AirPods Pro") or the port type ("Speaker").
    private(set) var outputName = "Speaker"
    /// Best-effort: the output name contains "AirPods" (head tracking needs Pro/Max/3rd gen; the
    /// HeadPoseTracker reports the truth once motion data flows).
    var isAirPods: Bool { outputName.localizedCaseInsensitiveContains("AirPods") }

    /// Called on every change with (connected, name); the AppModel speaks the line.
    @ObservationIgnored var onChange: ((Bool, String) -> Void)?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {}

    func start() {
        guard observer == nil else { return }
        refresh(notify: false)
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
            onChange?(headphonesConnected, outputName)
        }
    }
}
