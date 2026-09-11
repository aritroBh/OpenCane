//
//  SpeechQueue.swift
//  CaneKit
//
//  The one voice of the app. Every spoken line goes through here with a priority:
//    .scene    < .nav      < .obstacle
//    "Where am I" answers, route instructions, "door ahead, one meter"
//  A higher-priority line interrupts the current one; equal or lower priority queues behind it
//  (FIFO within a priority). Queued lines carry a TTL so a stale "turn left" is never spoken late.
//
//  Two backends, one queue:
//    · ElevenLabs (natural voice) when a key is configured — cached mp3s play instantly; a cache
//      miss is fetched with a short timeout and falls back to…
//    · AVSpeechSynthesizer (system voice), always available offline.
//
//  Audio: one `.playback` session with `.duckOthers`, mode `.default`, no Bluetooth options
//  (adding HFP would drop AirPods to phone-call quality and flip routes — ios/README.md §2).
//  Both backends use the app session so speech and the beacon share one route. Interruptions
//  (phone call, Siri) re-activate the session when they end.
//
//  Correctness note: `stopSpeaking` / `player.stop()` return before their end callbacks arrive.
//  Every line therefore carries a generation token, and an end callback is ignored unless it
//  belongs to the line that is *currently* ours — a late cancel never wipes its replacement.
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

    /// True while a line is playing (the beacon ducks itself on this).
    private(set) var isSpeaking = false
    /// Last line handed to a backend (debug footer / trip log).
    private(set) var lastSpoken = ""
    private(set) var audioSessionError: String?
    /// "ElevenLabs" or "System" — what the last line used.
    private(set) var backendName = "System"
    private(set) var voiceError: String?
    /// Natural voice available (key present). Toggle `useNaturalVoice` to force the system voice.
    let naturalVoice: ElevenLabsVoice? = ElevenLabsVoice.fromSecrets()
    var useNaturalVoice = true

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
    /// Generation of the line we consider current; callbacks for any other generation are stale.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var currentPriority: SpeechPriority?
    @ObservationIgnored private var currentUtterance: AVSpeechUtterance?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var playerRelay: PlayerRelay?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var voice: AVSpeechSynthesisVoice?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?

    var rate: Float = AVSpeechUtteranceDefaultSpeechRate * 1.05

    init() {
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

        if isSpeaking, let cp = currentPriority {
            if priority > cp {
                stopCurrent()
                speakNow(line, priority)
            } else {
                guard !queue.contains(where: { $0.text == line }) else { return }   // coalesce
                sequence += 1
                queue.append(Pending(text: line, priority: priority,
                                     expires: ttl > 0 ? now + ttl : .infinity, sequence: sequence))
                queue.sort { ($0.priority, -$0.sequence) > ($1.priority, -$1.sequence) }
            }
            return
        }
        speakNow(line, priority)
    }

    /// Pre-synthesize lines the route will need (no-op without the natural voice).
    func prefetch(_ lines: [String]) {
        guard let naturalVoice, useNaturalVoice else { return }
        Task.detached(priority: .utility) { await naturalVoice.prefetch(lines) }
    }

    /// Drop everything waiting and stop the current line (used when a route ends).
    func stopAll() {
        queue.removeAll()
        stopCurrent()
        isSpeaking = false
        currentPriority = nil
    }

    // MARK: Backends

    private func speakNow(_ text: String, _ priority: SpeechPriority) {
        generation += 1
        let gen = generation
        currentPriority = priority
        isSpeaking = true
        lastSpoken = text

        guard let naturalVoice, useNaturalVoice else {
            speakSystem(text, gen: gen)
            return
        }
        if let url = naturalVoice.cached(text) {
            playFile(url, gen: gen)
            return
        }
        // Cache miss: fetch with a short timeout; fall back to the system voice on failure.
        fetchTask = Task { [weak self] in
            let result = await Result { try await naturalVoice.audio(for: text) }
            guard let self, self.generation == gen else { return }     // superseded meanwhile
            switch result {
            case .success(let url): self.playFile(url, gen: gen)
            case .failure(let error):
                self.voiceError = error.localizedDescription
                self.speakSystem(text, gen: gen)
            }
        }
    }

    private func speakSystem(_ text: String, gen: Int) {
        backendName = "System"
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = rate
        u.preUtteranceDelay = 0
        u.postUtteranceDelay = 0.05
        currentUtterance = u
        synthesizer.speak(u)
    }

    private func playFile(_ url: URL, gen: Int) {
        backendName = "ElevenLabs"
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            let relay = PlayerRelay { [weak self] in
                Task { @MainActor [weak self] in self?.lineEnded(gen: gen) }
            }
            p.delegate = relay
            playerRelay = relay
            player = p
            p.play()
        } catch {
            voiceError = "Playback: \(error.localizedDescription)"
            speakSystem(lastSpoken, gen: gen)
        }
    }

    private func stopCurrent() {
        fetchTask?.cancel()
        fetchTask = nil
        if let player, player.isPlaying { player.stop() }
        player = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .word) }
        currentUtterance = nil
        generation += 1                      // anything in flight is now stale
    }

    // MARK: Completion

    private func utteranceEnded(_ id: ObjectIdentifier) {
        guard let currentUtterance, ObjectIdentifier(currentUtterance) == id else { return }
        self.currentUtterance = nil
        lineEnded(gen: generation)
    }

    private func lineEnded(gen: Int) {
        guard gen == generation else { return }
        player = nil
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

// MARK: - Relays (callbacks arrive off the main actor)

/// Holds the end-of-utterance callback. Written once during `SpeechQueue.init`, then only read.
nonisolated private final class CallbackBox: @unchecked Sendable {
    var onEnd: (@Sendable (ObjectIdentifier) -> Void)?
}

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

nonisolated private final class PlayerRelay: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let onEnd: @Sendable () -> Void
    init(onEnd: @escaping @Sendable () -> Void) { self.onEnd = onEnd }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onEnd() }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { onEnd() }
}

private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
