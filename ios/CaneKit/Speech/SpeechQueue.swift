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
//  Rules, all enforced here (AGENTS.md hard rule 8 and "deliberate behaviours"; keep in sync
//  with docs/design.md §5):
//    · Priority: a strictly higher priority pre-empts; equal/lower queues. `.safety` ("Head
//      height.") is the top band: it pre-empts every other line and no other line can cut it
//      (only `stopAll`, the watchdog or a call/Siri `.began` stop it). The
//      only ways it does not play at once are coalescing with an identical line, queuing behind
//      another `.safety` line, or an active call/Siri interruption. (Its once-per-episode
//      rate limit lives upstream in CaneKitLogic `CueSpeechPolicy`, not here.)
//    · Coalescing: `say` drops a line identical to the one playing or already queued. Repeat
//      uses `sayAgain`, which bypasses coalescing (AGENTS.md: Repeat speaks the last line
//      actually spoken, even if it is playing right now).
//    · TTL: each queued line expires (`say` default 8 s, `sayAgain` 12 s); expired lines are
//      purged whenever a line ends, so a stale instruction is never spoken late.
//    · Replay: an interrupted line resumes at most once (`maxReplays`), at the front of its
//      band, with its TTL extended to ≥ 8 s from the cut; a second cut drops it (Repeat recovers).
//    · Interruption (call / Siri): `.began` re-queues the current line and holds the queue;
//      new lines queue (deduplicated) but nothing plays; `.ended` — or a 15 s fallback when
//      `.ended` never arrives — re-activates the session (2 retries, 1 s apart) and drains.
//    · Warnings never wait for the network: `.obstacle` / `.safety` cache misses use the system
//      voice immediately and prefetch the natural voice for next time.
//    · Watchdog: 6 s + characters / 6 after a line starts, a missing end callback is treated
//      as the end so a stalled backend can never freeze the queue.
//
//  Threading / isolation: `SpeechQueue` is `@MainActor` (the module default is MainActor; the
//  attribute is spelled out). Every piece of state and every method below runs on main.
//  Framework callbacks do not: `AVSpeechSynthesizerDelegate` and `AVAudioPlayerDelegate` fire on
//  arbitrary AVFoundation threads, so they land on the `nonisolated` relays at the bottom of
//  this file, which carry only Sendable values (`ObjectIdentifier`, the captured `Int`
//  generation) and hop with `Task { @MainActor in … }` (AGENTS.md hard rule 1). The interruption
//  notification is observed with `queue: .main`, which is why `MainActor.assumeIsolated` is
//  legal there. `ElevenLabsVoice` is a nonisolated Sendable struct; with
//  NonisolatedNonsendingByDefault its `audio(for:)` runs on main when awaited from `speakNow`'s
//  task (the network wait suspends, never blocks), while `prefetch` is pushed off main on a
//  detached `.utility` task. Unstructured `Task { … }` blocks created in this class (fetch,
//  watchdog, interruption fallback, resume retries) inherit the main actor.
//
//  Callers: `AppModel` (route lines, obstacle cue lines, channel announcements, Repeat via
//  `sayAgain`, `prefetch` at launch/route start, `stopAll` on Stop), `NavigationEngine` via
//  AppModel's `onSpeak`, `SceneDescriber` (`.scene`). The beacon reads `isSpeaking` through
//  AppModel's 10 Hz ticker to duck itself.
//

import AVFoundation
import Foundation
import Observation
import UIKit

/// Priority of a spoken line. Higher raw value wins: a strictly higher priority interrupts the
/// line playing; equal or lower queues behind it (FIFO within a band). Order is fixed by
/// AGENTS.md hard rule 8 and docs/design.md §5 — do not reorder without updating both.
enum SpeechPriority: Int, Comparable, Sendable {
    /// Scene descriptions < obstacle names < route instructions < head-height / safety lines.
    /// - `scene`: "Where am I" results and their progress lines (`SceneDescriber`).
    /// - `obstacle`: mesh names ("door ahead, one meter") and left/right/ahead cue lines spoken
    ///   when the phone cannot buzz.
    /// - `nav`: route, crossing, arrival, channel and status lines.
    /// - `safety`: "Head height." — never suppressed, pre-empts everything else.
    case scene = 0, obstacle = 1, nav = 2, safety = 3
    /// Orders by raw value so `priority > currentPriority` reads naturally at call sites.
    static func < (a: SpeechPriority, b: SpeechPriority) -> Bool { a.rawValue < b.rawValue }
}

/// The app's single speech channel: a priority queue with pre-emption, TTLs, one-shot replay of
/// interrupted lines, call/Siri interruption handling and two interchangeable backends
/// (ElevenLabs mp3 via `AVAudioPlayer`, or `AVSpeechSynthesizer`). Main-actor only; owned by
/// `AppModel`. See the file header for the full rule set.
@MainActor
@Observable
final class SpeechQueue {

    // MARK: Published

    /// True while a line is playing (the beacon ducks itself on this).
    /// Set in `speakNow`; cleared by `lineEnded` when the queue drains, by `stopAll`, and on an
    /// interruption `.began`. AppModel's 10 Hz ticker copies it into `BeaconEngine.setSpeaking`.
    private(set) var isSpeaking = false
    /// Last line handed to a backend (debug footer / trip log).
    /// Also the text re-spoken by the system voice when mp3 playback fails in `playFile`.
    private(set) var lastSpoken = ""
    /// Human-readable failure from activating the audio session (initial configure or resume
    /// after an interruption); nil when the last activation succeeded. Shown on the Haptics card.
    private(set) var audioSessionError: String?
    /// "ElevenLabs" or "System" — what the last line used.
    private(set) var backendName = "System"
    /// Last natural-voice problem (fetch failure, playback failure, watchdog reset). Diagnostic
    /// only, never spoken. Cleared when a new prefetch starts and when the natural voice actually
    /// plays a line, so the card shows a live complaint rather than a grievance from a dead spot
    /// the walker left ten minutes ago.
    private(set) var voiceError: String?
    /// Natural voice available (key present). Toggle `useNaturalVoice` to force the system voice.
    /// Built once from `Secrets.plist`; nil without `ELEVENLABS_API_KEY` (hard rule 4: no key,
    /// no crash — the system voice simply carries every line).
    let naturalVoice: ElevenLabsVoice? = ElevenLabsVoice.fromSecrets()
    /// When false every line uses `AVSpeechSynthesizer`, even with a key and a warm cache.
    /// Also gates `prefetch` (no point spending API quota on a voice we will not use).
    var useNaturalVoice = true

    /// Lines that belong in the cache but are never urgent, appended to the end of *every*
    /// prefetch batch. `AppModel.start()` sets it to `SpokenPhrases.warningLines`.
    ///
    /// Why a standing set rather than one long batch at launch: `prefetch` cancels the batch
    /// running before it, and `speakNow` calls `prefetch([text])` for every warning that misses
    /// the cache. One launch batch would therefore be abandoned by the first warning the walker
    /// heard — a few seconds in, with most of its lines never synthesized — and the voice would go
    /// on flipping for the rest of the session. Re-appending the set to every batch instead makes
    /// each restart resume where the last stopped: `VoicePrefetch.queue` drops whatever already
    /// reached the disk, so the remainder only shrinks and no line is paid for twice.
    ///
    /// Always last, so a route's own lines (waypoint 1 is needed *now*) are still requested first,
    /// and still only `VoicePrefetch.maxConcurrent` requests are in flight.
    @ObservationIgnored var backgroundLines: [String] = []

    // MARK: Private

    /// A line waiting in `queue`.
    private struct Pending {
        /// Trimmed, non-empty text; also the coalescing key (identical text = same line).
        let text: String
        /// Band the line waits in; `sortQueue` orders bands high → low.
        let priority: SpeechPriority
        /// Absolute deadline (`Date().timeIntervalSinceReferenceDate` seconds) after which the
        /// line is purged unspoken; `.infinity` for `ttl: 0`.
        let expires: TimeInterval
        /// FIFO key within a band: lower = older = spoken first. A re-queued interrupted line
        /// gets `min - 1` so it jumps to the front of its band.
        let sequence: Int
        /// How many times this line was already cut and resumed (capped at `maxReplays`).
        var replays: Int = 0
    }

    /// System voice backend. `usesApplicationAudioSession = true` (set in `init`) so it shares the
    /// app's `.playback` session and route with the beacon instead of opening its own.
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    /// Strong reference to the synthesizer's delegate (AVSpeechSynthesizer holds it weakly).
    @ObservationIgnored private let relay: DelegateRelay
    /// Lines waiting to play, kept sorted by `sortQueue` (priority desc, then sequence asc).
    /// `queue.first` is always the next line to speak.
    @ObservationIgnored private var queue: [Pending] = []
    /// Monotonic counter feeding `Pending.sequence`.
    @ObservationIgnored private var sequence = 0
    /// Generation of the line we consider current; callbacks for any other generation are stale.
    /// Bumped by `speakNow` (new line) and by `stopCurrent` (cancel), so every in-flight fetch,
    /// player callback and watchdog captured under an older value becomes a no-op.
    @ObservationIgnored private var generation = 0
    /// Priority of the line playing, or nil when idle; compared against incoming lines in `say`.
    @ObservationIgnored private var currentPriority: SpeechPriority?
    /// The line now playing and when it stops being worth resuming (for re-queue on interrupt).
    @ObservationIgnored private var currentText = ""
    /// Deadline carried over from the line's `Pending.expires` (`.infinity` for direct lines).
    @ObservationIgnored private var currentExpires: TimeInterval = .infinity
    /// How many times the line playing has already been resumed after a cut.
    @ObservationIgnored private var currentReplays = 0
    /// An interrupted line resumes once; cut again, it is dropped (a head-height branch every few
    /// seconds must not loop the first words of a crossing line forever — Repeat recovers it).
    private let maxReplays = 1
    /// True between an audio-session interruption's `.began` and `.ended` (call, Siri).
    /// While true `say` / `sayAgain` only enqueue and `lineEnded` does not start the next line.
    @ObservationIgnored private var interrupted = false
    /// 15 s timer armed on `.began` that drains the queue if `.ended` never arrives (the
    /// interrupting app is not obliged to deactivate its session). Cancelled on `.ended`.
    @ObservationIgnored private var interruptionFallback: Task<Void, Never>?
    /// Last time an ElevenLabs fetch failed (circuit breaker for weak networks).
    @ObservationIgnored private var naturalVoiceFailedAt: TimeInterval = -.infinity
    /// The system-voice utterance that is current; `utteranceEnded` matches callbacks against it
    /// by `ObjectIdentifier`, so a cancelled utterance's late `didCancel` is ignored.
    @ObservationIgnored private var currentUtterance: AVSpeechUtterance?
    /// Unstick timer for the current line (see `armWatchdog`); cancelled when the line ends.
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    /// The ElevenLabs mp3 player for the current line (nil while the system voice speaks).
    @ObservationIgnored private var player: AVAudioPlayer?
    /// Strong reference to `player`'s delegate (AVAudioPlayer holds its delegate weakly).
    @ObservationIgnored private var playerRelay: PlayerRelay?
    /// The one running batch prefetch, so a new route can cancel the previous route's.
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    /// In-flight ElevenLabs fetch for a cache miss; cancelled by `stopCurrent`.
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    /// True from a cache-miss fetch start until the fetch result *or* the 2.5 s deadline claims
    /// the line. Whichever comes second sees false and does nothing, so a line is never spoken
    /// twice (review round 5: the deadline fired after a short mp3 had already finished and
    /// repeated it in the system voice, over the next warning).
    @ObservationIgnored private var voicePending = false
    /// System voice chosen once at init (`bestEnglishVoice`); nil lets AVSpeech pick.
    @ObservationIgnored private var voice: AVSpeechSynthesisVoice?
    /// Token for the `AVAudioSession.interruptionNotification` observer (main queue).
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?

    /// System-voice rate (AVSpeech units, 0…1): 5 % above the default — brisk but clear while
    /// walking. Ignored by the ElevenLabs backend (the mp3 has its own pace).
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate * 1.05

    /// Wires the synthesizer delegate through the `nonisolated` relay. The relay's callback is
    /// `@Sendable` and may run on any AVFoundation thread, so it captures only the utterance's
    /// `ObjectIdentifier` and hops to the main actor before touching queue state.
    /// Does not touch the audio session — `configureAudioSession()` does that.
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
    ///
    /// This is the app's only `setCategory` call (AGENTS.md hard rule 7): `.playback` so speech
    /// and the beacon play with the ring/silent switch on, mode `.default`, options
    /// `[.duckOthers]` so a podcast dips under guidance. Deliberately *no* `.allowBluetooth` /
    /// `.allowBluetoothHFP`: HFP would drop AirPods to mono call quality (no HRTF beacon) and
    /// flip the route mid-walk. `BeaconEngine` and `CHHapticEngine(audioSession: nil)` rely on
    /// this session and never reconfigure it. Failures are recorded in `audioSessionError`,
    /// never thrown — speech still attempts to play.
    ///
    /// Also installs the interruption observer. It is registered with `queue: .main`, so the
    /// closure provably runs on the main thread and `MainActor.assumeIsolated` is legal; only
    /// the decoded `InterruptionType` (Sendable) crosses into the isolated call.
    /// Called by `AppModel.start()` before `haptics.start()` and `depth.start()`. Calling it
    /// twice would add a second observer (the token is overwritten, not removed).
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
    ///
    /// `.began`: re-queue the current line (subject to `maxReplays` and its TTL), cancel the
    /// backends (bumping `generation` so their late callbacks are ignored), set `interrupted`,
    /// and arm the 15 s `interruptionFallback`. `.ended`: cancel the fallback and resume.
    /// `.ended`'s `shouldResume` option is not consulted: guidance resumes regardless.
    /// `BeaconEngine` observes the same notification independently and restarts its own graph.
    /// Main actor (called from the main-queue observer via `assumeIsolated`).
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
                self.resumeAfterInterruption(attempt: 0, fromEnded: false)
            }
        case .ended:
            interruptionFallback?.cancel()
            resumeAfterInterruption(attempt: 0, fromEnded: true)
        @unknown default:
            break
        }
    }

    /// Re-activate the session (it can fail right at `.ended` while the call's session winds
    /// down — retry twice, a second apart), then drain whatever queued up meanwhile.
    ///
    /// - Parameter attempt: 0 on the first try; retries at 1 and 2. After the last failure the
    ///   queue is drained anyway (better to try than to hold guidance forever), with the error
    ///   left in `audioSessionError`.
    /// Draining goes through `lineEnded(gen: generation)` — the current generation, so the guard
    /// passes — which purges expired lines and starts the head of the queue.
    /// Retry tasks inherit the main actor (unstructured `Task` in a main-actor method).
    /// - Parameter fromEnded: true when the system posted `.ended`; false for our own 15 s
    ///   fallback. Without `.ended`, a failed re-activation means the call is probably still on:
    ///   keep waiting (re-arm the fallback) instead of draining lines over it (Muse M3).
    private func resumeAfterInterruption(attempt: Int, fromEnded: Bool) {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            audioSessionError = "Audio resume: \(error.localizedDescription)"
            if attempt < 2 {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    self?.resumeAfterInterruption(attempt: attempt + 1, fromEnded: fromEnded)
                }
                return
            }
            if !fromEnded {
                interruptionFallback = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    guard let self, !Task.isCancelled, self.interrupted else { return }
                    self.resumeAfterInterruption(attempt: 0, fromEnded: false)
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
    ///
    /// Decision order:
    /// 1. Whitespace-only text is ignored.
    /// 2. During a call/Siri interruption the line is queued (unless identical text is already
    ///    queued) and nothing plays until `.ended` / the 15 s fallback.
    /// 3. While speaking: a strictly higher priority re-queues the current line (one replay,
    ///    front of its band), stops it and speaks now; equal/lower priority is coalesced away if
    ///    identical to the playing or a queued line, else appended FIFO within its band.
    /// 4. Idle: speaks immediately. The TTL only matters while waiting in the queue; a line
    ///    that starts at once plays in full.
    /// Callers pick TTLs per line type (AppModel: obstacle names 4 s, cue lines 6 s, route
    /// lines 12–20 s; SceneDescriber results 20 s). Main actor.
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
    ///
    /// No-op when idle, when the line already used its one replay (`maxReplays`), when it has
    /// expired, or when identical text is already queued. The resumed line restarts from its
    /// first word (neither backend can resume mid-utterance). Its new deadline is
    /// `max(original, now + 8 s)`. Must be called *before* `stopCurrent`, which clears nothing
    /// here but bumps the generation. Callers: `say` (pre-emption) and `interruption(.began)`.
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
    ///
    /// Any queued copy of `text` is removed first so it cannot play twice. The line it cuts is
    /// *not* re-queued (the user explicitly asked for this line instead). During an interruption
    /// it only queues. `ttl` is always finite here (default 12 s) — unlike `say`, `ttl: 0` does
    /// not mean "never expires"; a queued line with `ttl: 0` would be purged at the next drain.
    /// Caller: the Repeat path (watch / on-screen button) through `NavigationEngine.onRepeat`,
    /// wired in `AppModel`, always with `.nav` and the last line actually spoken (AGENTS.md).
    /// Main actor.
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
    /// Called after every insertion so `queue.first` / `removeFirst()` is always the next line.
    /// The queue is a handful of lines, so a full sort is cheaper than being clever.
    private func sortQueue() {
        queue.sort { ($0.priority, -$0.sequence) > ($1.priority, -$1.sequence) }
    }

    /// Pre-synthesize lines the route will need (no-op without the natural voice).
    /// Fire-and-forget on a detached `.utility` task so the network work never runs on (or
    /// blocks) the main actor; `ElevenLabsVoice` is a Sendable value, so capturing it is safe.
    /// A line that is still uncached later simply takes the fetch or system-voice path in
    /// `speakNow`. Callers: `AppModel.start()` (common lines) and route start (every waypoint line
    /// + intro); `speakNow` for a warning spoken by the system voice.
    ///
    /// Only one prefetch runs at a time: starting a second route cancels the first. Two overlapping
    /// batches would put twice `maxConcurrentPrefetches` requests in flight and rate-limit the live
    /// cue the walker is waiting for, and the older batch is for a route nobody is walking any more.
    /// `backgroundLines` is appended to whatever the caller passed, so a cancelled batch's
    /// never-urgent tail is carried into the replacement instead of being dropped.
    /// - Parameter lines: the urgent lines, in speaking order; requested before `backgroundLines`.
    func prefetch(_ lines: [String]) {
        guard let naturalVoice, useNaturalVoice else { return }
        prefetchTask?.cancel()
        // A new attempt: drop the previous complaint so the card cannot keep accusing the voice
        // after the network came back. A failure below writes a fresh one.
        voiceError = nil
        let batch = lines + backgroundLines
        prefetchTask = Task.detached(priority: .utility) { [weak self] in
            let failure = await naturalVoice.prefetch(batch)
            // Only report; never let a prefetch failure disable the voice. The live path has its
            // own circuit breaker, and the cache may already hold the line that matters.
            guard let failure, !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                // Backgrounding surfaces as a timeout, not a cancellation, and is not a voice
                // problem: do not accuse the voice for a suspension the user caused.
                guard UIApplication.shared.applicationState != .background else { return }
                self.voiceError = failure
            }
        }
    }

    /// Drop everything waiting and stop the current line (used when a route ends).
    /// Nothing is re-queued. Does not clear `interrupted`; a later `say` still obeys an active
    /// call. `AppModel.stopRoute` calls this before speaking "Route stopped." so queued
    /// waypoint lines cannot play after Stop.
    func stopAll() {
        queue.removeAll()
        stopCurrent()
        isSpeaking = false
        currentPriority = nil
        currentText = ""
    }

    /// True when launched with `CANEKIT_MUTE=1` or under XCUITest (`CANEKIT_UITEST=1`): tests
    /// and the e2e harness run silently.
    static let muted: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["CANEKIT_MUTE"] == "1" || env["CANEKIT_UITEST"] == "1"
    }()

    // MARK: Backends

    /// Make `text` the current line and hand it to a backend. The caller must already have
    /// stopped (or never started) any previous line.
    ///
    /// Bumps `generation`, records the current line's priority / text / deadline / replay
    /// count (used by `requeueCurrent`), sets `isSpeaking` and `lastSpoken`, arms the watchdog,
    /// then picks a backend:
    /// - no key, or `useNaturalVoice == false` → system voice;
    /// - ElevenLabs cache hit → mp3 plays at once;
    /// - cache miss on `.obstacle` / `.safety` → system voice now + background prefetch
    ///   (warnings never wait for the network — AGENTS.md);
    /// - cache miss otherwise → fetch (≤ `ElevenLabsVoice.timeout`, 2.5 s), then play; on
    ///   failure speak with the system voice. The fetch task inherits the main actor and the
    ///   URLSession await inside `ElevenLabsVoice.audio(for:)` suspends rather than blocks it.
    /// A result that arrives after the line was superseded (generation changed) is dropped.
    ///
    /// - Parameters:
    ///   - expires: absolute deadline carried from the queue; `.infinity` for direct lines.
    ///   - replays: how many times this line has already been resumed after a cut.
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

        // Automation mute (simulator tests, never on a normal launch): keep the queue's timing
        // and logging but make no sound — the line "ends" after its estimated spoken length.
        if Self.muted {
            let seconds = 0.4 + Double(text.count) / 15.0
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.lineEnded(gen: gen)
            }
            return
        }

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
        // The natural voice failed recently (weak or captive network): don't make every line wait
        // up to 2.5 s for another failure — system voice now, retry the network in the background
        // (Muse M1). After 60 s quiet, the natural voice gets another chance.
        if Date().timeIntervalSinceReferenceDate - naturalVoiceFailedAt < 60 {
            speakSystem(text, gen: gen)
            prefetch([text])
            return
        }
        // Cache miss: fetch, but never wait more than 2.5 s in total — URLRequest's timeout is an
        // *idle* timeout, so a slow trickle could stall the queue far longer (review). On the
        // deadline: system voice now, mark the natural voice as failing (circuit breaker).
        voicePending = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, self.voicePending, self.generation == gen, self.isSpeaking,
                  self.player == nil, self.currentUtterance == nil else { return }
            self.voicePending = false
            self.fetchTask?.cancel()
            self.naturalVoiceFailedAt = Date().timeIntervalSinceReferenceDate
            self.speakSystem(text, gen: gen)
        }
        fetchTask = Task { [weak self] in
            let result = await Result { try await naturalVoice.audio(for: text) }
            // Superseded meanwhile, or the 2.5 s deadline already switched to the system voice.
            guard let self, self.voicePending, self.generation == gen, self.isSpeaking,
                  self.currentUtterance == nil else { return }
            self.voicePending = false
            switch result {
            case .success(let url): self.playFile(url, gen: gen)
            case .failure(let error):
                self.voiceError = error.localizedDescription
                self.naturalVoiceFailedAt = Date().timeIntervalSinceReferenceDate
                self.speakSystem(text, gen: gen)
            }
        }
    }

    /// System-voice backend. Speaks through the app's audio session (`usesApplicationAudioSession`),
    /// so it shares the beacon's route and ducking. Completion arrives via `DelegateRelay` →
    /// `utteranceEnded`, matched by utterance identity rather than `gen` (the parameter is kept
    /// for symmetry with `playFile`; staleness is enforced by `currentUtterance`, which
    /// `stopCurrent` clears). 0.05 s post-utterance gap keeps back-to-back lines distinct.
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

    /// ElevenLabs backend: play a cached mp3 with `AVAudioPlayer` on the app audio session.
    ///
    /// A fresh `PlayerRelay` per line captures this line's `gen`; its `@Sendable` callback fires
    /// on an AVFoundation thread and hops to the main actor, where `lineEnded(gen:)` ignores it
    /// unless `gen` is still current. The relay is retained in `playerRelay` because the
    /// player's delegate is weak. If the file cannot be opened or `play()` returns false (no
    /// delegate callback will ever come) the line is re-spoken by the system voice under the same
    /// generation, so the queue never sticks. Main actor.
    private func playFile(_ url: URL, gen: Int) {
        backendName = "ElevenLabs"
        // The natural voice just worked, so any earlier complaint is history. Without this a
        // launch with no signal would leave "timed out" on the card for the rest of the day, even
        // once every line was coming out in the ElevenLabs voice.
        voiceError = nil
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
    ///
    /// Limit = 6 s + characters / 6 s (≈ a slow speaking rate plus fetch headroom). The timer
    /// also covers a slow ElevenLabs fetch, since it is armed before the backend is chosen.
    /// Fires only if the same generation is still speaking; it then records
    /// "Speech watchdog reset" in `voiceError`, stops the backends (bumping `generation`) and
    /// ends the line with the *new* generation so the next queued line starts. The dropped line
    /// is not re-queued. The task inherits the main actor. Called from `speakNow` only.
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

    /// Silence whatever is playing and invalidate every in-flight callback for it: cancels the
    /// watchdog and any ElevenLabs fetch, stops the player and the synthesizer (at a word
    /// boundary), forgets `currentUtterance`, and bumps `generation`. The stop calls return
    /// before their delegate callbacks fire; those late callbacks are ignored by the generation /
    /// utterance-identity checks. Does *not* touch `isSpeaking`, `currentPriority` or the
    /// queue — callers either start a new line right after or reset those themselves.
    private func stopCurrent() {
        watchdog?.cancel()
        watchdog = nil
        fetchTask?.cancel()
        fetchTask = nil
        voicePending = false
        if let player, player.isPlaying { player.stop() }
        player = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .word) }
        currentUtterance = nil
        generation += 1                      // anything in flight is now stale
    }

    // MARK: Completion

    /// System-voice completion (finish *or* cancel), delivered on main by the relay hop.
    /// Ignored unless `id` is the utterance we still consider current — a `didCancel` from a
    /// line that `stopCurrent` already replaced arrives late and must not end its successor.
    private func utteranceEnded(_ id: ObjectIdentifier) {
        guard let currentUtterance, ObjectIdentifier(currentUtterance) == id else { return }
        self.currentUtterance = nil
        lineEnded(gen: generation)
    }

    /// The current line finished (or was declared finished): advance the queue.
    ///
    /// Stale calls (`gen != generation`) are ignored. Otherwise clears the current-line state,
    /// purges expired queued lines (TTL), and either starts the head of the queue — carrying its
    /// deadline and replay count — or, if the queue is empty or a call/Siri interruption is
    /// active, sets `isSpeaking = false`. Callers: `utteranceEnded`, the `PlayerRelay` hop,
    /// the watchdog, and `resumeAfterInterruption` (to drain after `.ended`).
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
    /// Evaluated once in `init`; premium/enhanced voices exist only if the user downloaded them
    /// in Settings › Accessibility › Spoken Content.
    private static func bestEnglishVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en-US") }
        if let v = voices.first(where: { $0.quality == .premium }) { return v }
        if let v = voices.first(where: { $0.quality == .enhanced }) { return v }
        return AVSpeechSynthesisVoice(language: "en-US")
    }
}

// MARK: - Relays (callbacks arrive off the main actor)
//
// Why these exist (AGENTS.md hard rule 1): with MainActor default isolation, a delegate method
// on `SpeechQueue` itself would be main-actor isolated, but AVFoundation calls delegates on its
// own threads — a data race the compiler rightly rejects. So each delegate is a tiny
// `nonisolated` class that touches no main-actor state, turns the callback into Sendable values
// (`ObjectIdentifier`, a captured `Int` generation) and hops with `Task { @MainActor in … }`.
// `@unchecked Sendable` is acceptable on these relays (not on `SpeechQueue`) because their only
// state is immutable after init or written once before the delegate is installed.

/// Holds the end-of-utterance callback. Written once during `SpeechQueue.init`, then only read.
/// Exists because `init` must build `DelegateRelay` before `self` is fully initialised, so the
/// `[weak self]` closure is attached afterwards through this box.
nonisolated private final class CallbackBox: @unchecked Sendable {
    /// Receives the finished/cancelled utterance's identity on the synthesizer's thread; the
    /// closure installed by `SpeechQueue.init` hops to the main actor.
    var onEnd: (@Sendable (ObjectIdentifier) -> Void)?
}

/// `AVSpeechSynthesizerDelegate` relay. Runs on whatever thread AVSpeech uses; forwards only the
/// utterance's `ObjectIdentifier` (the utterance object itself is not Sendable). Finish and
/// cancel are reported identically — `SpeechQueue.utteranceEnded` decides whether it matters.
nonisolated private final class DelegateRelay: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let box: CallbackBox
    init(box: CallbackBox) { self.box = box }

    /// Normal end of an utterance → `onEnd`.
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        box.onEnd?(ObjectIdentifier(utterance))
    }

    /// `stopSpeaking` (pre-emption, stop, watchdog) → `onEnd`; usually stale by the time it lands.
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        box.onEnd?(ObjectIdentifier(utterance))
    }
}

/// `AVAudioPlayerDelegate` relay, one per mp3 line. `onEnd` already captures that line's
/// generation and does the main-actor hop (see `SpeechQueue.playFile`). Note `player.stop()`
/// does not call `audioPlayerDidFinishPlaying`, so a stopped line relies on `stopCurrent`'s
/// generation bump rather than on this callback.
nonisolated private final class PlayerRelay: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let onEnd: @Sendable () -> Void
    init(onEnd: @escaping @Sendable () -> Void) { self.onEnd = onEnd }

    /// Playback reached the end (successfully or not) → the line is over.
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onEnd() }
    /// A corrupt cached mp3 → treat as ended so the queue moves on (no system-voice retry here).
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { onEnd() }
}

/// Async counterpart of `Result(catching:)`, so `speakNow` can await the ElevenLabs fetch and
/// then switch on success / failure in one place.
private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
