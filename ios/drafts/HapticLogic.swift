//
//  HapticLogic.swift
//  CaneKit
//
//  LaneReport → haptic commands ("H:<L|R|B>:<1-4>:<ms>\n") with hysteresis and rate
//  limiting, plus spoken warnings via AVSpeechSynthesizer.
//
//  Call `process(_:)` from one thread (the app calls it on main).
//

import AVFoundation
import Foundation
import Observation

// MARK: - Types

enum Lane: Int, CaseIterable {
    case left = 0, center, right

    /// Motor selector in the cane protocol. Center obstacle → both motors.
    var motorCode: String {
        switch self {
        case .left:   return "L"
        case .center: return "B"
        case .right:  return "R"
        }
    }

    var spoken: String {
        switch self {
        case .left:   return "ahead, left"
        case .center: return "ahead"
        case .right:  return "ahead, right"
        }
    }
}

enum Severity: Int, Comparable {
    case clear = 0, warn = 1, urgent = 2
    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

// MARK: - HapticLogic

@Observable
final class HapticLogic {

    // Tunables
    var warnDistance: Float = 1.5
    var urgentDistance: Float = 0.8
    /// Extra distance an obstacle must recede before a lane de-escalates (m).
    var hysteresis: Float = 0.15
    /// Hard floor between any two haptic commands.
    var minCommandInterval: TimeInterval = 0.4
    /// While a lane stays in warn / urgent, re-buzz at this cadence.
    var warnRepeatInterval: TimeInterval = 1.2
    var urgentRepeatInterval: TimeInterval = 0.5
    var speechCooldown: TimeInterval = 2.0
    var hapticsEnabled = true
    var speechEnabled = true

    // Published for the UI
    private(set) var lastCommand = ""
    private(set) var activeLane: Lane?
    private(set) var activeSeverity: Severity = .clear

    /// Wire this to CaneBLE.send. Receives the full command including "\n".
    @ObservationIgnored var sendCommand: ((String) -> Void)?

    @ObservationIgnored private var laneSeverity: [Severity] = [.clear, .clear, .clear]
    @ObservationIgnored private var lastCommandTime: TimeInterval = 0
    @ObservationIgnored private var lastSpokenTime: TimeInterval = 0

    // MARK: Main entry

    func process(_ report: LaneReport) {
        guard report.depthAvailable else { return }
        // While sweeping the cane, the depth is smeared and the lanes are meaningless:
        // freeze state, send nothing.
        guard !report.isSweeping else { return }

        let now = Date().timeIntervalSinceReferenceDate

        // 1. Per-lane severity with hysteresis.
        for lane in Lane.allCases {
            let d = report.nearest(lane: lane.rawValue)
            laneSeverity[lane.rawValue] = nextSeverity(from: laneSeverity[lane.rawValue], distance: d)
        }

        // 2. Pick the lane to report: highest severity, tie → nearest.
        var best: (lane: Lane, severity: Severity, distance: Float)?
        for lane in Lane.allCases {
            let sev = laneSeverity[lane.rawValue]
            guard sev > .clear else { continue }
            let d = report.nearest(lane: lane.rawValue)
            if let b = best {
                if sev > b.severity || (sev == b.severity && d < b.distance) {
                    best = (lane, sev, d)
                }
            } else {
                best = (lane, sev, d)
            }
        }

        let previousLane = activeLane
        let previousSeverity = activeSeverity

        guard let best else {
            activeLane = nil
            activeSeverity = .clear
            return
        }
        activeLane = best.lane
        activeSeverity = best.severity

        let escalated = best.severity > previousSeverity || best.lane != previousLane

        // 3. Rate-limited haptic emission.
        let repeatInterval = best.severity == .urgent ? urgentRepeatInterval : warnRepeatInterval
        let sinceLast = now - lastCommandTime
        if sinceLast >= minCommandInterval && (escalated || sinceLast >= repeatInterval) {
            emit(lane: best.lane, severity: best.severity, now: now)
        }

        // 4. Speech on escalation / lane change, with cooldown.
        if escalated {
            speakWarning(lane: best.lane, distance: best.distance, now: now)
        }
    }

    /// Stateless severity for UI colouring (no hysteresis).
    func severity(for distance: Float) -> Severity {
        if distance < urgentDistance { return .urgent }
        if distance < warnDistance { return .warn }
        return .clear
    }

    /// Bypasses hysteresis and rate limiting. For the "Test buzz" buttons.
    func testBuzz(_ motor: Lane) {
        let cmd = "H:\(motor.motorCode):3:300\n"
        lastCommand = cmd.trimmingCharacters(in: .newlines)
        lastCommandTime = Date().timeIntervalSinceReferenceDate
        sendCommand?(cmd)
    }

    func reset() {
        laneSeverity = [.clear, .clear, .clear]
        activeLane = nil
        activeSeverity = .clear
    }

    // MARK: Internals

    private func nextSeverity(from current: Severity, distance d: Float) -> Severity {
        switch current {
        case .clear:
            if d < urgentDistance { return .urgent }
            if d < warnDistance { return .warn }
            return .clear
        case .warn:
            if d < urgentDistance { return .urgent }
            if d > warnDistance + hysteresis { return .clear }
            return .warn
        case .urgent:
            if d <= urgentDistance + hysteresis { return .urgent }
            if d > warnDistance + hysteresis { return .clear }
            return .warn
        }
    }

    private func emit(lane: Lane, severity: Severity, now: TimeInterval) {
        let intensity = severity == .urgent ? 4 : 2          // 1…4
        let durationMs = severity == .urgent ? 250 : 120
        let cmd = "H:\(lane.motorCode):\(intensity):\(durationMs)\n"
        lastCommandTime = now
        lastCommand = cmd.trimmingCharacters(in: .newlines)
        if hapticsEnabled {
            sendCommand?(cmd)
        }
    }

    private func speakWarning(lane: Lane, distance: Float, now: TimeInterval) {
        guard speechEnabled, now - lastSpokenTime >= speechCooldown else { return }
        lastSpokenTime = now
        let phrase = "Obstacle \(lane.spoken), \(Speech.distancePhrase(distance))"
        Speech.shared.say(phrase)
    }
}

// MARK: - Speech (shared by HapticLogic and SceneDescriber)

final class Speech: NSObject {
    static let shared = Speech()

    private let synthesizer = AVSpeechSynthesizer()
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    var language = "en-US"

    private override init() {
        super.init()
    }

    /// .playback so speech plays even with the ring/silent switch on; ducks music.
    func configureAudioSession() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try s.setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
    }

    func say(_ text: String, interrupt: Bool = false) {
        guard !text.isEmpty else { return }
        DispatchQueue.main.async {
            if interrupt, self.synthesizer.isSpeaking {
                self.synthesizer.stopSpeaking(at: .immediate)
            }
            let u = AVSpeechUtterance(string: text)
            u.voice = AVSpeechSynthesisVoice(language: self.language)
            u.rate = self.rate
            u.preUtteranceDelay = 0
            self.synthesizer.speak(u)
        }
    }

    /// "half a meter", "one meter", "one and a half meters", "two meters"…
    static func distancePhrase(_ meters: Float) -> String {
        guard meters.isFinite else { return "" }
        let half = (meters * 2).rounded() / 2          // nearest 0.5 m
        if half < 0.5 { return "very close" }
        if half == 0.5 { return "half a meter" }
        if half == 1 { return "one meter" }
        if half == 1.5 { return "one and a half meters" }
        if half == 2 { return "two meters" }
        if half == half.rounded() { return "\(Int(half)) meters" }
        return String(format: "%.1f meters", half)
    }
}
