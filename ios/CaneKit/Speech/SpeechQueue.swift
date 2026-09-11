//
//  SpeechQueue.swift
//  CaneKit
//
//  The one voice of the app. Every spoken line goes through here with a priority:
//    .scene    < .nav      < .obstacle
//    "Where am I" answers, route instructions, "door ahead, one meter"
//  A higher-priority line interrupts the current one at a word boundary; equal or lower priority
//  queues behind it (FIFO within a priority). Queued lines carry a TTL so a stale "turn left" is
//  never spoken late.
//
//  Audio: one `.playback` session with `.duckOthers`, mode `.default`, no Bluetooth options
//  (adding HFP would drop AirPods to phone-call quality and flip routes — ios/README.md §2).
//  The synthesizer uses the app session so speech and the beacon share one route. Interruptions
//  (phone call, Siri) re-activate the session when they end.
//
//  Correctness note: `stopSpeaking` returns before `didCancel` arrives. Every utterance therefore
//  carries an identity, and a finish/cancel callback is ignored unless it belongs to the utterance
//  that is *currently* ours — otherwise a late cancel would wipe the line that replaced it.
//

import AVFoundation
import Foundation
import Observation

/// Higher raw value wins.
enum SpeechPriority: Int, Comparable, Sendable {
    case scene = 0, nav = 1, obstacle = 2
    static func < (a: SpeechPriority, b: SpeechPriority) -> Bool { a.rawValue < b.rawValue }
}

@MainActor
@Observable
final class SpeechQueue {

    // MARK: Published

    /// True while an utterance is playing (the beacon ducks itself on this).
    private(set) var isSpeaking = false
    /// Last line handed to the synthesizer (debug footer / trip log).
    private(set) var lastSpoken = ""
    private(set) var audioSessionError: String?

    // MARK: Private

    private struct Pending {
        let text: String
        let priority: SpeechPriority
        let expires: TimeInterval
        let sequence: Int
    }

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let relay: DelegateRelay
    @ObservationIgnored private var queue: [Pending] = []
    @ObservationIgnored private var sequence = 0
    /// The utterance we consider "current"; callbacks for any other utterance are stale.
    @ObservationIgnored private var current: AVSpeechUtterance?
    @ObservationIgnored private var currentPriority: SpeechPriority?
    @ObservationIgnored private var voice: AVSpeechSynthesisVoice?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?

    var rate: Float = AVSpeechUtteranceDefaultSpeechRate * 1.05

    init() {
        // The relay's callback is fixed at construction, so there is no later cross-thread write.
        let box = CallbackBox()
        relay = DelegateRelay(box: box)
        synthesizer.usesApplicationAudioSession = true
        synthesizer.delegate = relay
        voice = Self.bestEnglishVoice()
        box.onEnd = { [weak self] id in
            Task { @MainActor [weak self] in self?.utteranceEnded(id) }
        }
    }

    // MARK: Audio session

    /// Call once before the AR session starts (ARKit does not touch audio, but the beacon does).
    func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
            audioSessionError = nil
        } catch {
            audioSessionError = "Audio session: \(error.localizedDescription)"
        }
        // After a call / Siri the session is deactivated; re-activate so the next line is heard.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            guard type == .ended else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }

    // MARK: Speaking

    /// Speak `text`. Higher priority than the current line interrupts it; otherwise it queues.
    /// - Parameter ttl: seconds the line stays valid while waiting (0 = never expires).
    func say(_ text: String, _ priority: SpeechPriority, ttl: TimeInterval = 8) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        let now = Date().timeIntervalSinceReferenceDate

        if current != nil, let cp = currentPriority {
            if priority > cp {
                // Interrupt: the old utterance's late didCancel is ignored because `current` changes.
                synthesizer.stopSpeaking(at: .word)
                speakNow(line, priority)
            } else {
                guard !queue.contains(where: { $0.text == line }) else { return }   // coalesce
                sequence += 1
                queue.append(Pending(text: line, priority: priority,
                                     expires: ttl > 0 ? now + ttl : .infinity, sequence: sequence))
                // Stable: by priority, then arrival order.
                queue.sort { ($0.priority, -$0.sequence) > ($1.priority, -$1.sequence) }
            }
            return
        }
        speakNow(line, priority)
    }

    /// Drop everything waiting and stop the current line (used when a route ends).
    func stopAll() {
        queue.removeAll()
        current = nil
        currentPriority = nil
        isSpeaking = false
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func speakNow(_ text: String, _ priority: SpeechPriority) {
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = rate
        u.preUtteranceDelay = 0
        u.postUtteranceDelay = 0.05
        current = u
        currentPriority = priority
        isSpeaking = true
        lastSpoken = text
        synthesizer.speak(u)
    }

    /// Finish or cancel for utterance `id`. Stale ids (interrupted lines) are ignored.
    private func utteranceEnded(_ id: ObjectIdentifier) {
        guard let current, ObjectIdentifier(current) == id else { return }
        self.current = nil
        currentPriority = nil
        let now = Date().timeIntervalSinceReferenceDate
        queue.removeAll { $0.expires < now }
        guard !queue.isEmpty else {
            isSpeaking = false
            return
        }
        let next = queue.removeFirst()
        speakNow(next.text, next.priority)
    }

    /// Prefer an enhanced/premium en-US voice when one is installed; fall back to the default.
    private static func bestEnglishVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en-US") }
        if let v = voices.first(where: { $0.quality == .premium }) { return v }
        if let v = voices.first(where: { $0.quality == .enhanced }) { return v }
        return AVSpeechSynthesisVoice(language: "en-US")
    }
}

/// Holds the end-of-utterance callback. Written once on the main actor during `SpeechQueue.init`
/// before the synthesizer can call back, then only read.
nonisolated private final class CallbackBox: @unchecked Sendable {
    var onEnd: (@Sendable (ObjectIdentifier) -> Void)?
}

/// AVSpeechSynthesizerDelegate calls arrive on an unspecified thread; this stays `nonisolated`
/// and forwards the utterance identity to the main actor.
nonisolated private final class DelegateRelay: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let box: CallbackBox
    init(box: CallbackBox) { self.box = box }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        box.onEnd?(ObjectIdentifier(utterance))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        box.onEnd?(ObjectIdentifier(utterance))
    }
}
