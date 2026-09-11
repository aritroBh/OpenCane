//
//  SpeechQueue.swift
//  CaneKit
//
//  The one voice of the app. Every spoken line goes through here with a priority:
//    .scene    < .obstacle              < .nav                 < .safety
//    "Where am I"  "door ahead, one meter"  route / crossing lines  "Head height."
//  A higher-priority line interrupts the current one; equal or lower priority queues behind it
//  (FIFO within a priority). Queued lines carry a TTL so a stale "turn left" is never spoken late.
//  An interrupted line is put back at the front of its priority band and resumes after the
//  interrupter, so a crossing instruction cut by a head-height warning is never lost
//  (docs/design.md §5: crossing / arrival / head are P0, obstacle names P1).
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
    /// Scene descriptions < obstacle names < route instructions < head-height / safety lines.
    case scene = 0, obstacle = 1, nav = 2, safety = 3
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
        /// How many times this line was already cut and resumed (capped at `maxReplays`).
        var replays: Int = 0
    }

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let relay: DelegateRelay
    @ObservationIgnored private var queue: [Pending] = []
    @ObservationIgnored private var sequence = 0
    /// Generation of the line we consider current; callbacks for any other generation are stale.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var currentPriority: SpeechPriority?
    /// The line now playing and when it stops being worth resuming (for re-queue on interrupt).
    @ObservationIgnored private var currentText = ""
    @ObservationIgnored private var currentExpires: TimeInterval = .infinity
    @ObservationIgnored private var currentReplays = 0
    /// An interrupted line resumes once; cut again, it is dropped (a head-height branch every few
    /// seconds must not loop the first words of a crossing line forever — Repeat recovers it).
    private let maxReplays = 1
    /// True between an audio-session interruption's `.began` and `.ended` (call, Siri).
    @ObservationIgnored private var interrupted = false
    @ObservationIgnored private var interruptionFallback: Task<Void, Never>?
    @ObservationIgnored private var currentUtterance: AVSpeechUtterance?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
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
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            guard let type else { return }
            MainActor.assumeIsolated { self?.interruption(type) }
        }
    }

    /// Phone call / Siri: the system stops our audio without telling the backends. Put the
    /// current line back in the queue and mark ourselves quiet; when the interruption ends,
    /// re-activate the session and carry on with whatever is still valid.
    private func interruption(_ type: AVAudioSession.InterruptionType) {
        switch type {
        case .began:
            if isSpeaking { requeueCurrent() }
            stopCurrent()
            isSpeaking = false
            currentPriority = nil
            currentText = ""
            interrupted = true
            // `.ended` is not guaranteed (the interrupting app may never deactivate): drain anyway.
            interruptionFallback?.cancel()
            interruptionFallback = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled, self.interrupted else { return }
                self.resumeAfterInterruption(attempt: 0)
            }
        case .ended:
            interruptionFallback?.cancel()
            resumeAfterInterruption(attempt: 0)
        @unknown default:
            break
        }
    }

    /// Re-activate the session (it can fail right at `.ended` while the call's session winds
    /// down — retry twice, a second apart), then drain whatever queued up meanwhile.
    private func resumeAfterInterruption(attempt: Int) {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            audioSessionError = "Audio resume: \(error.localizedDescription)"
            if attempt < 2 {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    self?.resumeAfterInterruption(attempt: attempt + 1)
                }
                return
            }
        }
        interrupted = false
        if !isSpeaking { lineEnded(gen: generation) }
    }

    // MARK: Speaking

    /// Speak `text`. Higher priority than the current line interrupts it; otherwise it queues.
    /// - Parameter ttl: seconds the line stays valid while waiting (0 = never expires).
    func say(_ text: String, _ priority: SpeechPriority, ttl: TimeInterval = 8) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        let now = Date().timeIntervalSinceReferenceDate
        let expires = ttl > 0 ? now + ttl : TimeInterval.infinity

        // During a call / Siri nothing can play: queue it; `.ended` drains in priority order.
        if interrupted {
            guard !queue.contains(where: { $0.text == line }) else { return }
            sequence += 1
            queue.append(Pending(text: line, priority: priority, expires: expires, sequence: sequence))
            sortQueue()
            return
        }
        if isSpeaking, let cp = currentPriority {
            if priority > cp {
                requeueCurrent()             // resume the cut line after this one
                stopCurrent()
                speakNow(line, priority, expires: expires)
            } else {
                guard line != currentText, !queue.contains(where: { $0.text == line }) else { return }   // coalesce
                sequence += 1
                queue.append(Pending(text: line, priority: priority, expires: expires, sequence: sequence))
                sortQueue()
            }
            return
        }
        speakNow(line, priority, expires: expires)
    }

    /// Put the line now playing back at the *front* of its priority band (if still valid and not
    /// already replayed). Its validity is extended so the original TTL does not expire while the
    /// interrupter speaks.
    private func requeueCurrent() {
        let now = Date().timeIntervalSinceReferenceDate
        guard let cp = currentPriority, !currentText.isEmpty, currentReplays < maxReplays,
              currentExpires > now,
              !queue.contains(where: { $0.text == currentText }) else { return }
        let front = (queue.map(\.sequence).min() ?? sequence) - 1
        queue.append(Pending(text: currentText, priority: cp, expires: max(currentExpires, now + 8),
                             sequence: front, replays: currentReplays + 1))
        sortQueue()
    }

    /// "Say that again": always speaks, even when `text` is the line playing right now (plain
    /// `say` would coalesce it away). Interrupts an equal-or-lower line, queues behind a higher one.
    func sayAgain(_ text: String, _ priority: SpeechPriority, ttl: TimeInterval = 12) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        let expires = Date().timeIntervalSinceReferenceDate + ttl
        queue.removeAll { $0.text == line }
        if interrupted || (isSpeaking && (currentPriority ?? .scene) > priority) {
            sequence += 1
            queue.append(Pending(text: line, priority: priority, expires: expires, sequence: sequence))
            sortQueue()
            return
        }
        stopCurrent()
        speakNow(line, priority, expires: expires)
    }

    /// Highest priority first; within a priority, oldest (lowest sequence) first.
    private func sortQueue() {
        queue.sort { ($0.priority, -$0.sequence) > ($1.priority, -$1.sequence) }
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
        currentText = ""
    }

    // MARK: Backends

    private func speakNow(_ text: String, _ priority: SpeechPriority, expires: TimeInterval = .infinity,
                          replays: Int = 0) {
        generation += 1
        let gen = generation
        currentPriority = priority
        currentText = text
        currentExpires = expires
        currentReplays = replays
        isSpeaking = true
        lastSpoken = text
        armWatchdog(gen: gen, text: text)

        guard let naturalVoice, useNaturalVoice else {
            speakSystem(text, gen: gen)
            return
        }
        if let url = naturalVoice.cached(text) {
            playFile(url, gen: gen)
            return
        }
        // Warnings never wait for the network (a 2.5 s fetch is 3.5 m of walking into the
        // obstacle): system voice now, natural voice cached for next time.
        if priority == .obstacle || priority == .safety {
            speakSystem(text, gen: gen)
            prefetch([text])
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
            // A false return means no delegate callback will ever come: fall back immediately
            // instead of leaving `isSpeaking` stuck and every later line queued forever.
            if !p.play() {
                player = nil
                voiceError = "Playback did not start"
                speakSystem(lastSpoken, gen: gen)
            }
        } catch {
            voiceError = "Playback: \(error.localizedDescription)"
            speakSystem(lastSpoken, gen: gen)
        }
    }

    /// Last-resort unstick: if no end callback arrives well after the line should be over
    /// (interruption edge cases, a stalled player), treat it as ended so the queue keeps moving.
    private func armWatchdog(gen: Int, text: String) {
        watchdog?.cancel()
        let limit = 6.0 + Double(text.count) / 6.0          // ~25 s for a long crossing line
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard let self, !Task.isCancelled, self.generation == gen, self.isSpeaking else { return }
            self.voiceError = "Speech watchdog reset"
            self.stopCurrent()                              // bumps generation: in-flight work stays stale
            self.lineEnded(gen: self.generation)
        }
    }

    private func stopCurrent() {
        watchdog?.cancel()
        watchdog = nil
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
        watchdog?.cancel()
        watchdog = nil
        player = nil
        currentPriority = nil
        currentText = ""
        let now = Date().timeIntervalSinceReferenceDate
        queue.removeAll { $0.expires < now }
        guard !queue.isEmpty, !interrupted else {
            isSpeaking = false
            return
        }
        let next = queue.removeFirst()
        speakNow(next.text, next.priority, expires: next.expires, replays: next.replays)
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
