//
//  BeaconEngine.swift
//  CaneKit
//
//  A soft click that always comes from the direction to walk. AVAudioEngine → AVAudioPlayerNode
//  (mono, generated) → AVAudioEnvironmentNode (HRTF) → output. One rotation convention:
//    · the source sits at the *absolute* target bearing θ (degrees true), 10 m out:
//        position = (10 sin θ, 0, −10 cos θ)      (north = −z, east = +x)
//    · the listener's yaw carries the user's absolute facing = phone heading + head yaw:
//        listenerAngularOrientation.yaw = −(heading + headYaw)   (AVAudio yaw is CCW-positive)
//  Volume shrinks as the bearing error shrinks: silent under 10°, full by 90°, and ducks while
//  speech plays. Without AirPods motion data headYaw is 0 and the same graph pans from the
//  compass alone.
//

import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class BeaconEngine {

    // MARK: Published

    private(set) var isRunning = false
    private(set) var lastError: String?
    /// The bearing error currently rendered (debug).
    private(set) var renderedError: Double?
    /// 0…1, what the mixer is set to (debug).
    private(set) var renderedVolume: Float = 0
    var enabled = true {
        didSet { if !enabled { silence() } }
    }

    // MARK: Private

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private let environment = AVAudioEnvironmentNode()
    @ObservationIgnored private var clickBuffer: AVAudioPCMBuffer?
    @ObservationIgnored private var configObserver: NSObjectProtocol?
    @ObservationIgnored private var targetBearing: Double?
    @ObservationIgnored private var heading: Double?
    @ObservationIgnored private var headYaw: Double = 0
    @ObservationIgnored private var speaking = false
    /// Nodes are attached exactly once; a second `start()` (second route) only restarts the engine.
    @ObservationIgnored private var graphBuilt = false

    /// Silent inside this error; full volume at `fullVolumeError`.
    var silentError: Double = 10
    var fullVolumeError: Double = 90
    var duckWhileSpeaking: Float = 0.3

    init() {}

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            if !graphBuilt {
                clickBuffer = Self.makeClick(format: format)
                engine.attach(player)
                engine.attach(environment)
                // Mono in → environment (spatialised) → main mixer.
                engine.connect(player, to: environment, format: format)
                engine.connect(environment, to: engine.mainMixerNode, format: nil)

                player.renderingAlgorithm = .HRTF
                player.sourceMode = .spatializeIfMono
                environment.outputType = .headphones
                environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
                environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
                environment.distanceAttenuationParameters.referenceDistance = 10
                environment.distanceAttenuationParameters.maximumDistance = 20
                environment.reverbParameters.enable = false
                graphBuilt = true
            }

            try engine.start()
            restartLoop()
            isRunning = true
            lastError = nil
            observeRouteChanges()
            render()
        } catch {
            lastError = "Beacon: \(error.localizedDescription)"
            isRunning = false
        }
    }

    func stop() {
        player.stop()
        engine.stop()
        isRunning = false
    }

    /// One looping click, never two: stop first (drops any scheduled buffer), then schedule + play.
    private func restartLoop() {
        player.stop()
        if let clickBuffer {
            player.scheduleBuffer(clickBuffer, at: nil, options: [.loops])
        }
        player.volume = renderedVolume
        player.play()
    }

    /// AirPods connect/disconnect re-configures the engine: restart the graph.
    private func observeRouteChanges() {
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                do {
                    try self.engine.start()
                    self.restartLoop()
                } catch {
                    self.lastError = "Beacon restart: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: Inputs

    /// Where to walk, degrees true. nil = no target → silent.
    func setTarget(bearing: Double?) {
        targetBearing = bearing
        render()
    }

    /// The phone's heading, degrees true (already gyro-gated).
    func setHeading(_ h: Double?) {
        heading = h
        render()
    }

    /// Head yaw relative to the recentred forward direction, degrees, right-positive.
    func setHeadYaw(_ yaw: Double) {
        headYaw = yaw
        render()
    }

    func setSpeaking(_ on: Bool) {
        speaking = on
        render()
    }

    // MARK: Render

    private func render() {
        guard isRunning, enabled, let θ = targetBearing, let h = heading else {
            silence()
            return
        }
        // Source at the absolute bearing, listener rotated to the absolute facing.
        let rad = θ * .pi / 180
        player.position = AVAudio3DPoint(x: Float(10 * sin(rad)), y: 0, z: Float(-10 * cos(rad)))
        let facing = h + headYaw
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: Float(-facing), pitch: 0, roll: 0)

        var err = (θ - facing).truncatingRemainder(dividingBy: 360)
        if err > 180 { err -= 360 }
        if err <= -180 { err += 360 }
        renderedError = err
        let magnitude = abs(err)
        var volume: Float = magnitude <= silentError ? 0
            : Float(min(1, (magnitude - silentError) / (fullVolumeError - silentError)))
        if speaking { volume *= duckWhileSpeaking }
        renderedVolume = volume
        player.volume = volume
    }

    private func silence() {
        renderedVolume = 0
        renderedError = nil
        if isRunning { player.volume = 0 }
    }

    /// 40 ms decaying 1.2 kHz sine followed by silence to 400 ms — a soft, periodic tick.
    private static func makeClick(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let total = AVAudioFrameCount(sampleRate * 0.4)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = total
        let clickFrames = Int(sampleRate * 0.04)
        for i in 0..<Int(total) {
            if i < clickFrames {
                let t = Double(i) / sampleRate
                let env = exp(-t * 90)                       // fast decay
                data[i] = Float(0.6 * env * sin(2 * .pi * 1200 * t))
            } else {
                data[i] = 0
            }
        }
        return buffer
    }
}
