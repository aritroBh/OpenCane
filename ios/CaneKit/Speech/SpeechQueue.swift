//
//  SpeechQueue.swift
//  CaneKit
//
//  The one voice of the app. Every spoken line goes through here with a priority:
//    .scene    < .obstacle              < .nav                 < .safety
//    "Where am I"  "One meter ahead, door"  route / crossing lines  "Head height."
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
//  The single exception is `setMicrophoneEnabled(_:owner:)`: the danger-sound watch and the
//  push-to-talk path need an audio *input*, which `.playback` does not have, so this one method may
//  move the session to `.playAndRecord` while one feature has an explicit microphone lease. A
//  second owner is rejected. It reverts on any output/input route change — not only the one it can
//  see synchronously: iOS settles a route asynchronously, so for the whole time the microphone is
//  on a `routeChangeNotification` observer holds the session to the route it started with and puts
//  it back to `.playback` (and tells `SoundWatcher`, which stops) the moment that route moves. No
//  shipping code path may call `setCategory` anywhere else; the
//  one other call in the app is `SensorProbe.caseEAudioSession()`, the debug audio probe, which
//  runs only under `SensorProbe.isEnabled` (a launch argument) and finishes before
//  `SoundWatcher.start()` is ever reached.
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
//    · Resume (Step 37, owner decision 2026-09-12 "Cut in, then resume"): an interrupted line goes
//      back to the front of its band and continues from the start of the clause it was cut in
//      (CaneKitLogic `SpeechResume`) — a direction cut by "Head height." is never restarted from
//      its first word. It resumes at most 3 times and never from an earlier point than last time;
//      after that it is dropped (Repeat recovers). On the first cut its TTL is
//      extended to ≥ 8 s from the cut. An mp3's cut point is backed off ~0.5 s of speech.
//    · Pause between bands: when a line ends and the next queued line is a different band, 0.35 s
//      of silence first (`SpeechResume.gapSeconds`; `.safety` never waits), so a warning and a
//      direction are heard as two things.
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
import CaneKitLogic
import Foundation
import Observation
import UIKit

/// Priority of a spoken line. Higher raw value wins: a strictly higher priority interrupts the
/// line playing; equal or lower queues behind it (FIFO within a band). Order is fixed by
/// AGENTS.md hard rule 8 and docs/design.md §5 — do not reorder without updating both.
enum SpeechPriority: Int, Comparable, Sendable {
    /// Scene descriptions < obstacle names < route instructions < head-height / safety lines.
    /// - `scene`: "Where am I" results and their progress lines (`SceneDescriber`).
    /// - `obstacle`: mesh names ("One meter ahead, door") and left/right/ahead cue lines spoken
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

    /// The spoken lines of the route currently being walked, re-appended to every prefetch batch so
    /// a warning cache miss can never discard them. Set by `AppModel` when a route starts, cleared
    /// when it ends; empty when no route is running.
    @ObservationIgnored var routeLines: [String] = []

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
        /// How many times this line was already cut and resumed (capped at `SpeechResume.maxResumes`
        /// by `SpeechResume.nextResume`).
        var replays: Int = 0
        /// Speak in the system voice at once, prefetching the natural voice for next time
        /// (carried from `say(immediate:)` through the queue to `speakNow`).
        var immediate: Bool = false
        /// UTF-16 offset to start speaking from: 0 for a fresh line, the start of the clause it was
        /// cut in for a resumed one (Step 37). The text itself stays whole — it is the coalescing
        /// key, the cache key and what Repeat speaks.
        var resumeFrom: Int = 0
        /// The offset it last resumed from, nil if it was never cut (`SpeechResume.nextResume`).
        var lastResumeOffset: Int? = nil
    }

    /// System voice backend. `usesApplicationAudioSession = true` (set in `init`) so it shares the
    /// app's `.playback` session and route with the beacon instead of opening its own.
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    /// Strong reference to the synthesizer's delegate (AVSpeechSynthesizer holds it weakly).
    @ObservationIgnored private let relay: DelegateRelay
    /// Lines waiting to play, kept sorted by `sortQueue` (priority desc, then sequence asc).
    /// `queue.first` is always the next line to speak.
    @ObservationIgnored private var queue: [Pending] = []
    /// Pure optional-narration admission state. Only callers that explicitly pass an ambient load
    /// class reach it; normal, route and safety speech remain fail-open.
    @ObservationIgnored private var loadPolicy = SpeechLoadPolicy()
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
    /// Whether the line playing skips the TTS fetch (`say(immediate:)`), carried into the
    /// re-queue so a cut answer still answers at once instead of stalling on the network.
    @ObservationIgnored private var currentImmediate = false
    /// Offset the line playing started from (`Pending.resumeFrom`), 0 for a fresh line.
    @ObservationIgnored private var currentResumeFrom = 0
    /// The line playing's `Pending.lastResumeOffset`, carried into its next re-queue.
    @ObservationIgnored private var currentLastResumeOffset: Int?
    /// UTF-16 offset in `currentText` of the word the system voice is saying now (from
    /// `willSpeakRangeOfSpeechString`); 0 before the first word. Unused for an mp3 clip, whose
    /// progress is read from the player at the cut.
    @ObservationIgnored private var currentSpokenUTF16 = 0
    /// True once the system voice has reported a word of the line playing — only then has the word at
    /// `currentSpokenUTF16` actually started (and a word-boundary stop will finish it).
    @ObservationIgnored private var currentWordHeard = false
    /// True during the short pause `lineEnded` leaves before a line of a different band
    /// (`SpeechResume.gapSeconds`). `isSpeaking` stays true (the beacon stays ducked) and nothing is
    /// current; `say` queues everything except `.safety`, which ends the pause and speaks.
    @ObservationIgnored private var inGap = false
    /// Band of the line the current pause follows (valid while `inGap`); a new line of that band, or
    /// `.safety`, needs no pause and ends it (`SpeechResume.gapSeconds` = 0).
    @ObservationIgnored private var gapAfter: SpeechPriority?
    /// True between an audio-session interruption's `.began` and `.ended` (call, Siri).
    /// While true `say` / `sayAgain` only enqueue and `lineEnded` does not start the next line.
    @ObservationIgnored private var interrupted = false
    /// True while the walker is talking to OpenCane (voice input listening). While true `say`
    /// holds every line below `.safety` in the queue instead of playing it, so route and
    /// obstacle chatter never talks over the walker's dictation — and the recogniser never
    /// hears the app's own voice in the microphone. `.safety` ("Head height.", ground hazards)
    /// still breaks through: a curb cannot wait for the conversation. `sayAgain` (explicit
    /// Repeat) is unaffected: an explicit request wins. Owner: `VoiceInputEngine`, set where
    /// `isListening` flips and cleared in `cleanupAudioPipeline` (every exit path).
    @ObservationIgnored private var voiceHeld = false
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
        box.onWord = { [weak self] id, location in
            Task { @MainActor [weak self] in self?.utteranceWillSpeak(id, location: location) }
        }
    }

    // MARK: Audio session

    /// Call once before the AR session starts (ARKit does not touch audio, but the beacon does).
    ///
    /// This is the app's `setCategory` call for every normal launch (AGENTS.md hard rule 7); the
    /// only other one on a shipping path is `setMicrophoneEnabled(_:owner:)`, which a walker has to
    /// switch on and which reverts here on any output-route change, for as long as it is on. (The
    /// debug `SensorProbe` has one more, behind a launch argument.) `.playback` so speech
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
            microphoneRestoreError = nil
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

    // MARK: Microphone (danger-sound watch)

    /// Which feature currently owns the temporary microphone lease. The audio session has one
    /// input graph; rejecting a second owner prevents push-to-talk from replacing the sound
    /// watcher's route observer (or vice versa) while either feature is live.
    enum MicrophoneOwner: String, Equatable, Sendable {
        case soundRecognition
        case voiceInput
    }

    /// What asking for microphone input did to the audio route.
    /// Returned by `setMicrophoneEnabled(_:owner:)` so the caller can tell the walker the truth.
    enum MicrophoneSessionResult: Equatable, Sendable {
        /// The output route is unchanged. The input may still be settling; callers must inspect
        /// `microphoneRouteSnapshot` before declaring a classifier live.
        case granted(route: String)
        /// Input was available but the output route changed (e.g. AirPods dropped from A2DP to
        /// HFP call quality, which would kill the HRTF beacon). The session has already been put
        /// back to `.playback`; the caller must not enable its recording feature.
        case revertedRouteChanged(before: String, after: String)
        /// `setCategory` / `setActive` threw. The session has been put back to `.playback`.
        case failed(String)
    }

    /// Fired on the main actor when the microphone route moves while the microphone is on. For a
    /// benign startup transition from an input-less route to the first usable input, the session is
    /// still held and this callback only updates the baseline; for every other change the session
    /// has **already** been put back to `.playback`. Parameters are `(routeWhenGranted, routeNow)`
    /// and include both output identity and input quality.
    ///
    /// Why a callback and not just a return value: the route settles asynchronously. The
    /// before/after comparison inside `setMicrophoneEnabled(true, owner:)` only catches a route that has
    /// already moved by the time `setActive` returns, and on AirPods it typically has not — iOS
    /// publishes the new route roughly 0.1–0.5 s later, long after the switch has reported
    /// success. Without this hook the walker keeps walking with the beacon's HRTF gone and the
    /// voice at call quality, and nothing ever tells them. Set by `SoundWatcher.start()` and
    /// cleared by `SoundWatcher.stop()`.
    @ObservationIgnored var onMicrophoneRouteChanged: ((SoundRecognitionRoute, SoundRecognitionRoute) -> Void)?

    /// The complete route as it was when the microphone was granted; nil whenever the session is
    /// on plain `.playback`. Every route-change notification is compared against this, not against
    /// the previous notification, so a route that wanders away and is still wrong is still caught.
    @ObservationIgnored private var microphoneRoute: SoundRecognitionRoute?

    /// The complete route snapshot held while sound recognition owns `.playAndRecord`. Read by
    /// `SoundWatcher` immediately after `setMicrophoneEnabled(true, owner:)` so its pure guard starts with
    /// the same input/output identity the notification observer is watching.
    var microphoneRouteSnapshot: SoundRecognitionRoute? { microphoneRoute }

    /// Last failure while returning the microphone to `.playback`, if any. SoundWatcher includes
    /// this in its existing failure card/speech path instead of claiming a restore succeeded.
    @ObservationIgnored var microphoneRestoreError: String?

    /// The owner of the temporary `.playAndRecord` lease, or nil in the normal `.playback` state.
    @ObservationIgnored private var microphoneOwner: MicrophoneOwner?

    /// Token for the `AVAudioSession.routeChangeNotification` observer. Non-nil **only** while the
    /// microphone is on: the guard costs nothing the rest of the time, and removing it before the
    /// revert is what stops our own `setCategory(.playback)` from re-entering the handler.
    @ObservationIgnored private var routeChangeObserver: NSObjectProtocol?

    /// Receives an optional line that the load policy dropped, so `TripLogger` can show what the
    /// sensors produced and why the walker did not hear it. Main actor; set by `AppModel.start()`.
    @ObservationIgnored var onSuppressed: ((String, SpeechLoadClass, SpeechSuppressionReason) -> Void)?

    /// Receives every line at the moment the queue hands it to a voice backend (`speakNow`),
    /// whoever queued it and whether it started at once or drained from the queue.
    /// ⚠ Why: `speech` trip-log records are written by *callers* (cues, route lines), so lines said
    /// straight through `say` — the both-cameras refusal, flashlight confirmations — left no trace,
    /// and a device log could not tell "dropped by the queue" from "dispatched" (trip log
    /// 2026-09-12T20-57-17Z, t = 84 s). ⚠ Dispatched is not heard: the line may still be cut by a
    /// higher priority, fail to fetch, or be muted automation — it proves the queue did not drop
    /// it, nothing more (Step 34 review). Arguments: text, priority, replay count (> 0 when a cut
    /// line resumes, so a resumed line appears twice). Main actor; set by `AppModel.start()`,
    /// logged as `speech_dispatch` (a separate kind, so `e2e.py`'s `speech` assertions keep their
    /// meaning).
    @ObservationIgnored var onDispatch: ((String, SpeechPriority, Int, Int) -> Void)?
    /// Receives the priority of each line that ENDED naturally (finished, or its watchdog fired), at
    /// the moment `lineEnded` starts the next one or the pause before it. Logged as `speech_end` so
    /// `cue_audit.py` can measure the pause between one line's end and the next start — start times
    /// alone cannot see a missing 0.35 s pause (review agents, Step 37). Main actor.
    @ObservationIgnored var onLineEnd: ((SpeechPriority) -> Void)?

    /// Switch the app's one audio session between `.playback` (the normal state) and
    /// `.playAndRecord`, which is the only way to get an `AVAudioEngine` input node for the
    /// danger-sound watch (`.playback` has no input at all — Apple's category table).
    ///
    /// This is the **only** other `setCategory` call in the app besides
    /// `configureAudioSession()`, and it exists because AGENTS.md hard rule 7 / ios/README.md §2
    /// pin the app to one `.playback` session: the rule is not silently broken, it is broken
    /// *visibly, temporarily, and only while the walker has asked for it*, and undone the moment
    /// the route degrades.
    ///
    /// Protections, in order:
    ///   · `.allowBluetoothHFP` is never passed. Apple documents that when one device offers both
    ///     HFP and A2DP "the system gives hands-free ports a higher priority for routing", which
    ///     is exactly the AirPods call-quality drop that would destroy the beacon's HRTF.
    ///   · `.allowBluetoothA2DP` **is** passed, because without it "paired Bluetooth A2DP devices
    ///     don't show up as available audio output routes" under `.playAndRecord`.
    ///   · `.defaultToSpeaker` keeps phone-only playback on the speaker; `.playAndRecord` would
    ///     otherwise route to the earpiece, which a cane-mounted phone cannot be heard from.
    ///   · The output route is compared before and after, and **any** immediate change reverts to
    ///     `.playback` and reports `.revertedRouteChanged`.
    ///   · The route is then watched for as long as the microphone stays on (see
    ///     `beginWatchingOutputRoute`), because the immediate comparison is not enough: iOS
    ///     settles a route change asynchronously, so an AirPods flip lands *after* the check
    ///     passed. Any later output change reverts the session and calls
    ///     `onMicrophoneRouteChanged`. Speech, warnings and the beacon are the safety path and a
    ///     microphone feature never outranks them.
    ///
    /// Measured on the iPhone 17 Pro Max (2026-09-11, trip-log `probe_e_audio_session`): with no
    /// headphones, `.playAndRecord` + these options left the output at `Speaker` and added
    /// `MicrophoneBuiltIn` as an input, and restoring `.playback` worked. The AirPods case is
    /// **not** measured yet, which is why the continuous watch above exists rather than a promise.
    /// Caller: `SoundWatcher.start()` / `stop()` and `VoiceInputEngine`'s push-to-talk path.
    func setMicrophoneEnabled(_ on: Bool, owner: MicrophoneOwner) -> MicrophoneSessionResult {
        let session = AVAudioSession.sharedInstance()
        guard on else {
            guard microphoneOwner == nil || microphoneOwner == owner else {
                return .failed("Microphone is owned by another OpenCane feature.")
            }
            stopWatchingOutputRoute()
            let result = restorePlaybackSession()
            if result == nil { microphoneOwner = nil }
            return result ?? .granted(route: Self.outputRoute(session))
        }
        if let microphoneOwner, microphoneOwner != owner {
            return .failed("Microphone is already in use by another OpenCane feature.")
        }
        if microphoneOwner == owner, let route = microphoneRoute {
            return .granted(route: route.output)
        }
        let before = Self.outputRoute(session)
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.duckOthers, .allowBluetoothA2DP, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            audioSessionError = "Microphone session: \(error.localizedDescription)"
            _ = restorePlaybackSession()
            return .failed(error.localizedDescription)
        }
        let after = Self.outputRoute(session)
        guard after == before else {
            _ = restorePlaybackSession()
            return .revertedRouteChanged(before: before, after: after)
        }
        audioSessionError = nil
        microphoneRestoreError = nil
        let route = Self.microphoneRoute(session)
        microphoneOwner = owner
        beginWatchingOutputRoute(route)
        return .granted(route: after)
    }

    /// Watch `AVAudioSession.routeChangeNotification` for as long as the microphone is on.
    ///
    /// The notification is registered with `queue: .main`, so the closure provably runs on the
    /// main thread and `MainActor.assumeIsolated` is legal (the same pattern as the interruption
    /// observer above); only a decoded `Bool` route edge crosses into the isolated call.
    /// Idempotent: a second call replaces the observer rather than stacking one.
    /// - Parameter route: the complete route snapshot to hold the session to.
    private func beginWatchingOutputRoute(_ route: SoundRecognitionRoute) {
        stopWatchingOutputRoute()
        microphoneRoute = route
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            let oldDeviceUnavailable = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            MainActor.assumeIsolated {
                self?.outputRouteMayHaveChanged(forceInputDrop: oldDeviceUnavailable)
            }
        }
    }

    /// Take the observer down and forget the held route. Called on the way back to `.playback`
    /// and before the revert inside the handler, so our own `setCategory` cannot re-enter it.
    private func stopWatchingOutputRoute() {
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
        routeChangeObserver = nil
        microphoneRoute = nil
    }

    /// A route change arrived while the microphone was on. If either the **output** identity or
    /// the input port/quality moved, put the session back to `.playback` immediately and tell the
    /// owner. A route change that merely re-announces the same complete snapshot is ignored — iOS
    /// posts several of those around a category change. Input-only degradation must not be ignored:
    /// a Bluetooth HFP or missing input can leave the output name unchanged while the classifier
    /// has already gone deaf.
    private func outputRouteMayHaveChanged(forceInputDrop: Bool = false) {
        guard let held = microphoneRoute else { return }
        var now = Self.microphoneRoute(AVAudioSession.sharedInstance())
        // Preserve an old-device-unavailable edge even if the main-queue callback samples a route
        // that has already recovered. The event itself proves that a microphone dropout happened.
        if forceInputDrop, now == held {
            now = SoundRecognitionRoute(output: now.output, input: now.input,
                                        inputQuality: .unavailable,
                                        outputIsHFP: now.outputIsHFP)
        }
        guard now != held else { return }
        // A just-activated `.playAndRecord` session can publish its output before the input port
        // appears. Keep the session held for this one startup transition and update the baseline;
        // `SoundWatcher`'s pure guard still requires a usable format before declaring recognition
        // live. Once an input has been usable, disappearing or changing it is a hard stop below.
        if held.output == now.output,
           held.inputQuality == .unavailable,
           now.inputQuality == .usable {
            microphoneRoute = now
            onMicrophoneRouteChanged?(held, now)
            return
        }
        // Order matters: drop the observer *before* reverting, or our own `setCategory(.playback)`
        // posts another route change straight back into this method.
        stopWatchingOutputRoute()
        let restoreResult = restorePlaybackSession()
        if restoreResult == nil { microphoneOwner = nil }
        onMicrophoneRouteChanged?(held, now)
    }

    /// Put the session back to the one configuration the rest of the app relies on.
    /// - Returns: `.failed` when the restore threw (the app is then in an unknown audio state and
    ///   the error is left in `audioSessionError` / `microphoneRestoreError`), nil on success.
    private func restorePlaybackSession() -> MicrophoneSessionResult? {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
            audioSessionError = nil
            microphoneRestoreError = nil
            return nil
        } catch {
            audioSessionError = "Audio restore: \(error.localizedDescription)"
            microphoneRestoreError = audioSessionError
            return .failed(error.localizedDescription)
        }
    }

    /// The current **output** route as a stable string (for example
    /// `BluetoothA2DP[uid|AirPods]` or `Speaker[...]`), including each port's UID/name for the
    /// before/after comparison, continuous watch and trip log.
    private static func outputRoute(_ session: AVAudioSession) -> String {
        let ports = session.currentRoute.outputs.map(portDescription).sorted()
        return ports.isEmpty ? "none" : ports.joined(separator: "+")
    }

    /// Include UID and human-readable name, not only the port type: two AirPods or USB inputs can
    /// share a type while still being a real route change that must stop recognition.
    private static func portDescription(_ port: AVAudioSessionPortDescription) -> String {
        let type = port.portType.rawValue
        let uid = port.uid.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = port.portName.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = [uid, name].filter { !$0.isEmpty }.joined(separator: "|")
        return identity.isEmpty ? type : "\(type)[\(identity)]"
    }

    /// Build the Sendable route snapshot used by `SoundRecognitionGuard`. Input quality is derived
    /// from the actual port list, never from the requested category: HFP and a missing input are
    /// unsafe even if the output port still looks unchanged.
    private static func microphoneRoute(_ session: AVAudioSession) -> SoundRecognitionRoute {
        let outputPorts = session.currentRoute.outputs
        let inputPorts = session.currentRoute.inputs
        let outputs = outputPorts.map(portDescription).sorted()
        let inputs = inputPorts.map(portDescription).sorted()
        let output = outputs.isEmpty ? "none" : outputs.joined(separator: "+")
        let input = inputs.isEmpty ? "none" : inputs.joined(separator: "+")
        let quality: SoundInputQuality
        if outputPorts.contains(where: { $0.portType == .bluetoothHFP })
            || inputPorts.contains(where: { $0.portType == .bluetoothHFP }) {
            quality = .hfp
        } else if inputs.isEmpty {
            quality = .unavailable
        } else {
            quality = .usable
        }
        return SoundRecognitionRoute(output: output, input: input, inputQuality: quality,
                                     outputIsHFP: outputPorts.contains {
                                         $0.portType == .bluetoothHFP
                                     })
    }

    /// Phone call / Siri: the system stops our audio without telling the backends. Put the
    /// current line back in the queue and mark ourselves quiet; when the interruption ends,
    /// re-activate the session and carry on with whatever is still valid.
    ///
    /// `.began`: re-queue the current line to resume from its clause (subject to
    /// `SpeechResume.nextResume` and its TTL), cancel the
    /// backends (bumping `generation` so their late callbacks are ignored), set `interrupted`,
    /// and arm the 15 s `interruptionFallback`. `.ended`: cancel the fallback and resume.
    /// `.ended`'s `shouldResume` option is not consulted: guidance resumes regardless.
    /// `BeaconEngine` observes the same notification independently and restarts its own graph.
    /// Main actor (called from the main-queue observer via `assumeIsolated`).
    private func interruption(_ type: AVAudioSession.InterruptionType) {
        switch type {
        case .began:
            if isSpeaking { requeueCurrent(fromClause: false) }
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
    ///    queued) and nothing plays until `.ended` / the 15 s fallback. While the voice hold is
    ///    on (the walker is dictating) the same queueing applies to everything below `.safety`;
    ///    `.safety` skips the hold — only a taken-away audio session outranks a curb.
    /// 3. While speaking: a strictly higher priority re-queues the current line (front of its
    ///    band, to resume from its clause — `requeueCurrent`), stops it and speaks now; equal/lower priority is coalesced away if
    ///    identical to the playing or a queued line, else appended FIFO within its band.
    /// 4. Idle: speaks immediately. The TTL only matters while waiting in the queue; a line
    ///    that starts at once plays in full.
    /// Callers pick TTLs per line type (AppModel: obstacle names 4 s, cue lines 6 s, route
    /// lines 12–20 s; SceneDescriber results 20 s). `immediate` is conversational answers only
    /// (see `speakNow`); it rides the `Pending` through the queue so a drained answer still
    /// skips the fetch. Main actor.
    @discardableResult
    func say(_ text: String, _ priority: SpeechPriority, ttl: TimeInterval = 8,
             load: SpeechLoadClass = .normal, immediate: Bool = false) -> Bool {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }
        let now = Date().timeIntervalSinceReferenceDate
        let expires = ttl > 0 ? now + ttl : TimeInterval.infinity

        switch loadPolicy.admit(load, now: now, isBusy: isSpeaking || interrupted) {
        case .speak:
            break
        case .suppress(let reason):
            onSuppressed?(line, load, reason)
            return false
        }

        // During a call / Siri nothing can play: queue it; `.ended` drains in priority order.
        // Same while the walker dictates (voice hold), except `.safety`, which skips the hold.
        if interrupted || (voiceHeld && priority < .safety) {
            guard !queue.contains(where: { $0.text == line }) else { return false }
            sequence += 1
            queue.append(Pending(text: line, priority: priority, expires: expires, sequence: sequence,
                                 immediate: immediate))
            sortQueue()
            return true
        }
        // The pause between two bands: nothing is playing. A line that needs no pause after the
        // band that just ended (`.safety`, or the same band — Antigravity, Step 37: a second route
        // line should not wait out a pause meant for a scene line) and outranks-or-ties the queue
        // head ends the pause and speaks now. Anything else queues; the pause then starts the
        // highest band first.
        if inGap {
            let needsNoPause = SpeechResume.gapSeconds(previousBand: gapAfter?.rawValue, nextBand: priority.rawValue,
                                                       safetyBand: SpeechPriority.safety.rawValue) == 0
            if priority == .safety || (needsNoPause && priority >= (queue.first?.priority ?? .scene)) {
                stopCurrent()
                speakNow(line, priority, expires: expires, immediate: immediate)
                return true
            }
            guard !queue.contains(where: { $0.text == line }) else { return false }
            sequence += 1
            queue.append(Pending(text: line, priority: priority, expires: expires, sequence: sequence,
                                 immediate: immediate))
            sortQueue()
            return true
        }
        if isSpeaking, let cp = currentPriority {
            if priority > cp {
                requeueCurrent()             // resume the cut line after this one
                stopCurrent()
                speakNow(line, priority, expires: expires, immediate: immediate)
            } else {
                guard line != currentText, !queue.contains(where: { $0.text == line }) else { return false }   // coalesce
                sequence += 1
                queue.append(Pending(text: line, priority: priority, expires: expires, sequence: sequence,
                                     immediate: immediate))
                sortQueue()
            }
            return true
        }
        speakNow(line, priority, expires: expires, immediate: immediate)
        return true
    }

    /// Put the line now playing back at the *front* of its priority band, to resume from the clause it
    /// was cut in (Step 37, owner decision 2026-09-12 "Cut in, then resume"): a direction cut by
    /// "Head height." continues "…then the path west" instead of restarting from "Route started".
    ///
    /// Progress: the system voice's last `willSpeakRange` word (heard in full — it stops at a word
    /// boundary, `finishesWord`); an mp3 clip's `currentTime / duration` mapped proportionally and
    /// backed off ~0.5 s (`SpeechResume.mp3HeardUTF16`). The resume point is the start of the clause
    /// containing it (`SpeechResume.resumeOffset`); nothing is re-queued when nothing but punctuation
    /// is left, or when an mp3 has already stopped playing (it finished; its end callback is still
    /// hopping to main, and `currentTime` has reset to 0 — review agents, Step 37). A line resumes
    /// at most `SpeechResume.maxResumes` times and its resume point never moves backwards
    /// (`nextResume`), so a head-height branch every few seconds cannot loop it forever. On its
    /// first cut its deadline becomes `max(original, now + 8 s)`; later cuts keep that deadline, so a
    /// line cut again and again still goes stale.
    ///
    /// - Parameter fromClause: true for a pre-emption (a warning is ~1 s; the direction's context is
    ///   still in the walker's ear). False for a call / Siri or dictation: after a pause of seconds a
    ///   clause fragment has no context, so the line restarts from its last resume point (0 for a
    ///   line never cut) — review agents, Step 37.
    ///
    /// No-op when idle, expired, or identical text is already queued. Must be called *before*
    /// `stopCurrent` (which drops the player the progress is read from). Callers: `say`
    /// (pre-emption), `interruption(.began)` and `setVoiceHold(true)`.
    private func requeueCurrent(fromClause: Bool = true) {
        let now = Date().timeIntervalSinceReferenceDate
        guard let cp = currentPriority, !currentText.isEmpty, currentExpires > now,
              !queue.contains(where: { $0.text == currentText }) else { return }
        var progress = 0
        if fromClause {
            let found: Int?
            if let player {
                guard player.isPlaying else { return }      // finished; the end callback is on its way
                // Backed off ~0.5 s of speech: a natural voice's timing is uneven, and resuming a clause
                // early repeats a few words where resuming late would lose an instruction (Muse, Step 37).
                let estimate = player.duration > 0
                    ? SpeechResume.spokenUTF16(text: currentText, playedFraction: player.currentTime / player.duration)
                    : 0
                found = SpeechResume.resumeOffset(text: currentText,
                                                  spokenUTF16: SpeechResume.mp3HeardUTF16(estimate: estimate))
            } else {
                found = SpeechResume.resumeOffset(text: currentText, spokenUTF16: currentSpokenUTF16,
                                                  finishesWord: currentWordHeard)
            }
            guard let found else { return }
            progress = found
        }
        guard let offset = SpeechResume.nextResume(previousOffset: currentLastResumeOffset, newOffset: progress,
                                                   resumes: currentReplays) else { return }
        let front = (queue.map(\.sequence).min() ?? sequence) - 1
        // The deadline is extended on the FIRST cut only: three resumes each adding 8 s could let a
        // ~25 s-old turn instruction play (Muse, Step 37). Later cuts keep the extended deadline.
        let expires = currentReplays == 0 ? max(currentExpires, now + 8) : currentExpires
        queue.append(Pending(text: currentText, priority: cp, expires: expires,
                             sequence: front, replays: currentReplays + 1,
                             immediate: currentImmediate, resumeFrom: offset, lastResumeOffset: offset))
        sortQueue()
    }

    /// "Say that again": always speaks, even when `text` is the line playing right now (plain
    /// `say` would coalesce it away). Interrupts an equal-or-lower line, queues behind a higher one.
    ///
    /// Explicit Repeat wins the pause between bands too: during `inGap` it speaks at once (the pause
    /// exists to separate unasked lines; the walker asked for this one — Muse, Step 37, accepted).
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
        // During a pause nothing is current: rank against the line the pause is waiting to start, so
        // Repeat never jumps a higher queued line (Antigravity, Step 37; today's callers pass `.nav`).
        let ahead = currentPriority ?? (inGap ? queue.first?.priority : nil) ?? .scene
        if interrupted || (isSpeaking && ahead > priority) {
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
        // Route lines are a standing set too, for the same reason `backgroundLines` is one — and
        // this is the case that matters most. At route start the whole route is prefetched, but the
        // first obstacle warning that misses the cache calls `prefetch([text])`, which cancels this
        // batch and replaces it. Without re-appending them every remaining waypoint line is dropped,
        // and the walker's next turn or crossing instruction — at a street corner — waits on the
        // network and arrives late in the system voice. They go before `backgroundLines` because a
        // turn is time-critical and a warning phrase is only a nicety once it is cached.
        let batch = lines + routeLines + backgroundLines
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

    /// Hold (`true`) or release (`false`) the speech channel while the walker dictates.
    ///
    /// On hold: the playing line is cut unless it is `.safety`, and re-queued subject to the
    /// usual resume rule (AGENTS.md: interrupted lines are re-queued; Repeat recovers the
    /// rest). New lines below `.safety` queue with their TTLs instead of playing; `.safety`
    /// speaks straight through. On release: expired lines are purged and the head of the queue
    /// plays — a short conversation lets still-valid guidance through, a long one finds the
    /// queue already expired, so there is no burst either way. Idempotent; safe to call when
    /// the hold was never set (teardown paths share it). Owner: `VoiceInputEngine`.
    /// Main actor.
    func setVoiceHold(_ active: Bool) {
        guard active != voiceHeld else { return }
        voiceHeld = active
        if active {
            if isSpeaking, currentPriority != .safety {
                requeueCurrent(fromClause: false)
                stopCurrent()
                isSpeaking = false
                currentPriority = nil
                currentText = ""
                currentImmediate = false
            }
            return
        }
        if !isSpeaking { lineEnded(gen: generation) }
    }

    /// Drop everything waiting and stop the current line (used when a route ends).
    /// Nothing is re-queued. Does not clear `interrupted`; a later `say` still obeys an active
    /// call. `AppModel.stopRoute` calls this before speaking "Route stopped." so queued
    /// waypoint lines cannot play after Stop.
    func stopAll() {
        queue.removeAll()
        inGap = false
        currentResumeFrom = 0
        currentLastResumeOffset = nil
        currentSpokenUTF16 = 0
        currentReplays = 0
        loadPolicy.reset()
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
    ///   - immediate: speak in the system voice at once (prefetching the natural voice for next
    ///     time) instead of waiting on a cache-miss fetch. Conversational answers only: their
    ///     text is novel every time, so a fetch would stall *every* answer on the network.
    private func speakNow(_ text: String, _ priority: SpeechPriority, expires: TimeInterval = .infinity,
                          replays: Int = 0, immediate: Bool = false,
                          resumeFrom: Int = 0, lastResumeOffset: Int? = nil) {
        generation += 1
        let gen = generation
        inGap = false
        currentPriority = priority
        currentText = text
        currentExpires = expires
        currentReplays = replays
        currentImmediate = immediate
        currentResumeFrom = resumeFrom
        currentLastResumeOffset = lastResumeOffset
        currentSpokenUTF16 = resumeFrom
        currentWordHeard = false
        isSpeaking = true
        lastSpoken = text
        // What the system voice says: the remainder from the resume clause. An mp3 clip plays the
        // whole cached file from `clipStart` instead (one cache entry per line, never per fragment).
        let spokenText = SpeechResume.remainder(of: text, from: resumeFrom)
        armWatchdog(gen: gen, text: spokenText)
        onDispatch?(text, priority, replays, resumeFrom)

        // Automation mute (simulator tests, never on a normal launch): keep the queue's timing
        // and logging but make no sound — the line "ends" after its estimated spoken length.
        if Self.muted {
            let seconds = 0.4 + Double(spokenText.count) / 15.0
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.lineEnded(gen: gen)
            }
            return
        }

        guard let naturalVoice, useNaturalVoice else {
            speakSystem(spokenText, gen: gen)
            return
        }
        if let url = naturalVoice.cached(text) {
            playFile(url, gen: gen)
            return
        }
        // Warnings never wait for the network (a 2.5 s fetch is 3.5 m of walking into the
        // obstacle): system voice now, natural voice cached for next time. Same for an
        // `immediate` conversational answer: its text is novel, so the cache can never hit and
        // the walker would otherwise wait on a fetch after every question.
        if immediate || priority == .obstacle || priority == .safety {
            speakSystem(spokenText, gen: gen)
            prefetch([text])
            return
        }
        // The natural voice failed recently (weak or captive network): don't make every line wait
        // up to 2.5 s for another failure — system voice now, retry the network in the background
        // (Muse M1). After 60 s quiet, the natural voice gets another chance.
        if Date().timeIntervalSinceReferenceDate - naturalVoiceFailedAt < 60 {
            speakSystem(spokenText, gen: gen)
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
            self.speakSystem(spokenText, gen: gen)
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
                self.speakSystem(spokenText, gen: gen)
            }
        }
    }

    /// System-voice backend. Speaks through the app's audio session (`usesApplicationAudioSession`),
    /// so it shares the beacon's route and ducking. Completion arrives via `DelegateRelay` →
    /// `utteranceEnded`, matched by utterance identity rather than `gen` (the parameter is kept
    /// for symmetry with `playFile`; staleness is enforced by `currentUtterance`, which
    /// `stopCurrent` clears). 0.05 s post-utterance gap keeps back-to-back lines distinct.
    /// - Parameter text: what to say — the whole line, or its remainder from `currentResumeFrom`
    ///   (word ranges reported for it are shifted by that offset in `utteranceWillSpeak`).
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
            // A resumed line starts at its clause, a quarter second early (`SpeechResume.clipTime`).
            p.currentTime = SpeechResume.clipTime(text: currentText, resumeUTF16: currentResumeFrom,
                                                  duration: p.duration)
            // A false return means no delegate callback will ever come: fall back immediately
            // instead of leaving `isSpeaking` stuck and every later line queued forever.
            if !p.play() {
                player = nil
                voiceError = "Playback did not start"
                speakSystem(SpeechResume.remainder(of: lastSpoken, from: currentResumeFrom), gen: gen)
            }
        } catch {
            voiceError = "Playback: \(error.localizedDescription)"
            speakSystem(SpeechResume.remainder(of: lastSpoken, from: currentResumeFrom), gen: gen)
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
        inGap = false                        // a pending pause belongs to the old generation
        generation += 1                      // anything in flight is now stale
    }

    // MARK: Completion

    /// System-voice completion (finish *or* cancel), delivered on main by the relay hop.
    /// Ignored unless `id` is the utterance we still consider current — a `didCancel` from a
    /// line that `stopCurrent` already replaced arrives late and must not end its successor.
    /// The system voice is about to say the word at `location` (UTF-16, within the utterance's own
    /// string). Recorded as progress through the whole line for `requeueCurrent`; ignored for any
    /// utterance that is no longer current (a late callback from a cut line).
    private func utteranceWillSpeak(_ id: ObjectIdentifier, location: Int) {
        guard let currentUtterance, ObjectIdentifier(currentUtterance) == id else { return }
        currentSpokenUTF16 = currentResumeFrom + location
        currentWordHeard = true
    }

    private func utteranceEnded(_ id: ObjectIdentifier) {
        guard let currentUtterance, ObjectIdentifier(currentUtterance) == id else { return }
        self.currentUtterance = nil
        lineEnded(gen: generation)
    }

    /// The current line finished (or was declared finished): advance the queue.
    ///
    /// Stale calls (`gen != generation`) are ignored. Otherwise clears the current-line state,
    /// purges expired queued lines (TTL), and either starts the head of the queue — carrying its
    /// deadline and replay count — or, if the queue is empty, a call/Siri interruption is
    /// active, or the voice hold is on, sets `isSpeaking = false`. Callers: `utteranceEnded`,
    /// the `PlayerRelay` hop, the watchdog, `resumeAfterInterruption` (to drain after `.ended`)
    /// and `setVoiceHold(false)` (to drain after dictation).
    private func lineEnded(gen: Int) {
        guard gen == generation else { return }
        watchdog?.cancel()
        watchdog = nil
        player = nil
        let endedPriority = currentPriority
        if let endedPriority { onLineEnd?(endedPriority) }
        currentPriority = nil
        currentText = ""
        currentImmediate = false
        currentResumeFrom = 0
        currentLastResumeOffset = nil
        currentSpokenUTF16 = 0
        startNext(after: endedPriority)
    }

    /// Start the head of the queue, after a short pause when it is a different band from the line
    /// that just ended (`SpeechResume.gapSeconds`, Step 37: "Head height." and the direction it cut
    /// are heard as two things, not one run-on sentence). Purges expired lines first, and again
    /// after the pause. During the pause `inGap` is true and `isSpeaking` stays true; a new line
    /// starting (`speakNow`), `stopCurrent`, `stopAll` or an interruption ends it, and the pause
    /// task — tied to this `generation` — then does nothing.
    /// - Parameter endedPriority: band of the line that just ended; nil to start without a pause
    ///   (draining after a call or a voice hold).
    private func startNext(after endedPriority: SpeechPriority?) {
        let now = Date().timeIntervalSinceReferenceDate
        queue.removeAll { $0.expires < now }
        guard let head = queue.first, !interrupted, !voiceHeld else {
            inGap = false
            isSpeaking = false
            return
        }
        let gap = SpeechResume.gapSeconds(previousBand: endedPriority?.rawValue, nextBand: head.priority.rawValue,
                                          safetyBand: SpeechPriority.safety.rawValue)
        if gap > 0 {
            inGap = true
            gapAfter = endedPriority
            // A fresh generation for the pause: a stray second end callback from the line that just
            // ended (still holding the old generation) is then ignored instead of cutting the pause
            // short (Antigravity, Step 37).
            generation += 1
            let gen = generation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(gap))
                guard let self, self.inGap, self.generation == gen else { return }
                self.inGap = false
                self.startNext(after: nil)
            }
            return
        }
        inGap = false
        let next = queue.removeFirst()
        speakNow(next.text, next.priority, expires: next.expires, replays: next.replays,
                 immediate: next.immediate, resumeFrom: next.resumeFrom,
                 lastResumeOffset: next.lastResumeOffset)
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
    /// Receives each word's start (UTF-16 location in the utterance string) before it is spoken, on
    /// the synthesizer's thread; the closure installed by `SpeechQueue.init` hops to the main actor.
    var onWord: (@Sendable (ObjectIdentifier, Int) -> Void)?
}

/// `AVSpeechSynthesizerDelegate` relay. Runs on whatever thread AVSpeech uses; forwards only the
/// utterance's `ObjectIdentifier` (the utterance object itself is not Sendable). Finish and
/// cancel are reported identically — `SpeechQueue.utteranceEnded` decides whether it matters.
nonisolated private final class DelegateRelay: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let box: CallbackBox
    init(box: CallbackBox) { self.box = box }

    /// A word is about to be spoken → `onWord` with its UTF-16 location (progress for resume).
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        box.onWord?(ObjectIdentifier(utterance), characterRange.location)
    }

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
