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
//  Two backends, one queue, one voice (Steps 53–54, owner decision 2026-09-13 "ElevenLabs is the one
//  voice for everything"):
//    · ElevenLabs (natural voice) when a key is configured and the Settings "Voice" picker is on
//      Natural — cached mp3s play instantly; a cache miss races a fetch for 2.5 s and falls back to…
//    · AVSpeechSynthesizer (system voice), always available offline.
//  Which one speaks a line is decided once, before its `speech_dispatch` record, by CaneKitLogic
//  `VoiceEngineChoice.decide` (tested); the dispatch record carries `engine` / `engine_reason`, and a
//  race is resolved by a `speech_engine` record.
//
//  Audio: one `.playback` session with `.duckOthers`, mode `.default`, no Bluetooth options
//  (adding HFP would drop AirPods to phone-call quality and flip routes — ios/README.md §2).
//  The single exception is `setMicrophoneEnabled(_:owner:)`: the danger-sound watch and the
//  push-to-talk path need an audio *input*, which `.playback` does not have, so this one method may
//  move the session to `.playAndRecord` while one feature has an explicit microphone lease
//  (`MicrophoneOwner`: `.soundRecognition` = SoundWatcher, `.voiceInput` = VoiceInputEngine). A
//  second owner is rejected. It reverts on any output/input route change — not only the one it can
//  see synchronously: iOS settles a route asynchronously, so for the whole time the microphone is
//  on a `routeChangeNotification` observer holds the session to the route it started with and puts
//  it back to `.playback` (and tells `SoundWatcher` through `onMicrophoneRouteChanged`, which stops)
//  the moment that route moves. The one tolerated move is the startup settle from "no input yet" to
//  a usable input on the same output (the baseline is updated, the session kept). Only SoundWatcher
//  installs that callback: a `.voiceInput` lease is reverted without being told. No
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
//      voice immediately and prefetch the natural voice for next time. Every other line — route
//      lines, conversational answers, "One moment.", status clauses — takes cache → 2.5 s race →
//      system voice only when the fetch fails or times out (Step 54; there is no `immediate` any more).
//    · The breaker is session-sticky (`VoiceBreaker`, Step 54): a race that fails or times out opens
//      it, and from then on every uncached line is the system voice at once — one flip per outage,
//      never one per line. Time alone never closes it; only a background prefetch chunk that
//      actually fetched something does. While open a probe re-runs the prefetch every 60 s.
//    · Prefetch is additive (`VoicePrefetch.merge`, Step 54): a new batch goes to the front of one
//      backlog that a single worker drains `VoicePrefetch.chunk` lines at a time; nothing cancels
//      the batch that is running, so a warning's cache miss can never throw away a route's lines.
//    · Watchdog: 6 s + characters / 6 after a line starts, a missing end callback is treated
//      as the end so a stalled backend can never freeze the queue.
//    · Load policy (Step 30 research, docs/auditory-load.md): a line tagged
//      `load: .ambientObstacleName` (mesh names only) must pass CaneKitLogic `SpeechLoadPolicy`
//      first — dropped while anything is speaking/interrupted or within 7 s of the last admitted
//      name — and a dropped line goes to `onSuppressed`, never to the queue. Every other line is
//      `.normal` and fails open.
//    · Voice hold (Step 30, device report "instructions kept playing over the dictation"): while
//      the walker talks to OpenCane, lines below `.safety` wait in the queue (`setVoiceHold`).
//    · Step 31's `say(immediate: true)` ("answers skip the fetch") is removed (Step 54): it was
//      the single biggest source of the voice flipping line by line on the first mounted walk.
//    · `onSpeakingChanged` (Step 55) tells `VoiceInputEngine` when a line starts and stops, so the
//      recogniser's tap is deaf while the app talks (a `.safety` line breaks through the voice hold).
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
//  `sayAgain`, `prefetch` at launch/route start, `stopAll` on Stop, the trip-log hooks
//  `onDispatch` / `onLineEnd` / `onSuppressed`, `routeLines` / `backgroundLines`),
//  `NavigationEngine` via AppModel's `onSpeak`, `SceneDescriber` (`.scene`), `HandsFreeIntents`
//  (status summary `.scene`, voice switches and haptics status `.nav`),
//  `ConversationCoordinator` (`.scene`), `VoiceInputEngine` (`setVoiceHold`, `onSpeakingChanged`,
//  the `.voiceInput` microphone lease, its own status lines) and `SoundWatcher` (the
//  `.soundRecognition` lease, `onMicrophoneRouteChanged`, `microphoneRouteSnapshot`,
//  `microphoneRestoreError`). The beacon reads `isSpeaking` through AppModel's 10 Hz ticker to duck
//  itself; `BeaconEngine.render` also reads `muted`.
//
//  Tests: none in-process — AVFoundation, device-only (docs/CODE_REFERENCE.md lists the device
//  walks). The numbers it applies are pinned in CaneKitLogic: `SpeechResumeTests` (resume point,
//  pause between bands), `SpeechLoadPolicyTests` (name pacing), `VoicePrefetchTests` (prefetch
//  order, fatal HTTP codes, the additive `merge`), `VoiceEngineChoiceTests` (which engine speaks a
//  line, the 2.5 s deadline, the session-sticky breaker), `SoundAlertsTests` (the microphone route guard) and `NavSupportTests`
//  (which cues reach the queue). `make uitest` / `make e2e` run it muted (`muted`) with real queue
//  timing; `ios/scripts/cue_audit.py` measures it from `speech_dispatch` / `speech_end` records.
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
    /// - `scene`: "Where am I" results and their progress lines (`SceneDescriber`), conversational
    ///   answers (`ConversationCoordinator`), the spoken status summary and the
    ///   flashlight outcome lines (`TorchSwitch.Outcome.spokenLine`).
    /// - `obstacle`: mesh names ("One meter ahead, door") and left/right/ahead cue lines spoken
    ///   when the phone cannot buzz, sign and hazard-watch lines (`HazardScanner`), horn / vehicle
    ///   sound alerts and the sound watch's own failure line.
    /// - `nav`: route, crossing, arrival, channel and status lines, and the emergency-siren alert
    ///   (a crossing fact — see the SoundWatcher.swift header for why it is not `.safety`).
    /// - `safety`: "Head height." and LiDAR ground hazards ("Two meters ahead, drop-off.") — never
    ///   suppressed, pre-empts everything else; nothing that is not imminent and physical belongs here.
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
    private(set) var isSpeaking = false {
        didSet {
            if oldValue != isSpeaking {
                onSpeakingChanged?(isSpeaking)
            }
        }
    }
    /// Fired on the main actor on every `isSpeaking` edge (true when a line starts, false when the
    /// queue drains, `stopAll`, an interruption or the voice hold ends it). The one listener is
    /// `VoiceInputEngine` (installed in its `init`, acting only while listening): it pauses the
    /// recogniser's tap while the app speaks and for `SelfHearFilter.tailSeconds` after (Step 55).
    /// ⚠ `isSpeaking` stays true through the 0.35 s pause between bands, so a pause covers it too.
    @ObservationIgnored var onSpeakingChanged: ((Bool) -> Void)?
    /// Last line handed to a backend — always the whole line, even for a resumed one. Nothing
    /// outside this class reads it today (Repeat speaks `NavigationEngine.lastSpokenLine`, and the
    /// trip log gets `onDispatch`); inside, `playFile` re-speaks its remainder from
    /// `currentResumeFrom` in the system voice when mp3 playback fails.
    private(set) var lastSpoken = ""
    /// Human-readable failure from activating the audio session (initial configure or resume
    /// after an interruption); nil when the last activation succeeded. Shown on the Haptics card.
    private(set) var audioSessionError: String?
    /// "ElevenLabs" or "System" — what the last line used. Shown by the Haptics card's voice pill
    /// (which says "System" whenever `naturalVoice` is nil).
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
    /// When false every line uses `AVSpeechSynthesizer`, even with a key and a warm cache
    /// (`VoiceEngineReason.naturalOff`). Also gates `prefetch` (no point spending API quota on a
    /// voice we will not use). ⚠ Not persisted here: `AppModel.naturalVoiceEnabled`
    /// (`Settings.bool("useNaturalVoice")`, the Settings "Voice" card) owns the stored value and
    /// pushes it at launch and on every change (Step 53). Switching back to Natural resumes the
    /// prefetch backlog.
    var useNaturalVoice = true {
        didSet { if useNaturalVoice, !oldValue { runPrefetchWorker() } }
    }
    /// The engine and reason of the last line handed to a backend, updated again when its race or
    /// playback resolves (`VoiceEngineChoice.resolvedEngine`). nil before the first line. Shown on
    /// the Details tab's Scene engine card ("Voice" row) and in the Haptics card's voice pill label.
    private(set) var lastEngine: VoiceEngineDecision?
    /// Mirror of `breaker.isOpen` for the UI and `AppModel.voiceFacts()`: true while the natural
    /// voice is treated as unreachable (Step 54).
    private(set) var naturalVoiceOffline = false

    /// Lines that belong in the cache but are never urgent, the last part of every prefetch pass's
    /// merge (`VoicePrefetch.merge`'s `tail`, after `routeLines`). `AppModel.start()` sets it to
    /// `SpokenPhrases.warningLines`.
    ///
    /// Why a standing set rather than one long batch at launch: before Step 54 `prefetch` cancelled
    /// the batch before it, and every warning that missed the cache started a new one, so a launch
    /// batch was abandoned a few seconds in. Prefetch is additive now and nothing is cancelled, but
    /// the standing tail stays: it keeps the warm-up complete whatever else is merged in front of it,
    /// and `VoicePrefetch.queue` drops whatever already reached the disk, so no line is paid for twice.
    /// Always last, so a route's own lines (waypoint 1 is needed *now*) are still requested first,
    /// and still only `VoicePrefetch.maxConcurrent` requests are in flight.
    @ObservationIgnored var backgroundLines: [String] = []

    /// The spoken lines of the route currently being walked, the front of every prefetch pass's
    /// standing tail (ahead of `backgroundLines`: a turn is time-critical, a warning phrase is a
    /// nicety once cached). Set by `AppModel` when a route starts, cleared when it ends; empty when
    /// no route is running. A line already handed to a pass still finishes after `stopRoute`.
    @ObservationIgnored var routeLines: [String] = []

    // MARK: Private

    /// A line waiting in `queue`. Value type: a re-queued line is a fresh `Pending` built by
    /// `requeueCurrent` from the `current…` fields, never the original mutated in place.
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
    /// Lines waiting to speak (not counting the one playing). Read by the voice shell
    /// (`AppModel.waitForSpeechToDrain`, `VoiceShellPolicy.followUp`) so the microphone never opens
    /// over a queued route line (Step 58).
    var queuedLineCount: Int { queue.count }
    /// Pure optional-narration admission state (CaneKitLogic `SpeechLoadPolicy`, 7 s calm window
    /// between admitted names; `SpeechLoadPolicyTests`). Only callers that explicitly pass an ambient
    /// load class reach it — today only `AppModel.handle`'s obstacle names; normal, route and safety
    /// speech remain fail-open. Consulted in `say` before any queueing; reset by `stopAll`.
    @ObservationIgnored private var loadPolicy = SpeechLoadPolicy()
    /// Monotonic counter feeding `Pending.sequence`.
    @ObservationIgnored private var sequence = 0
    /// Generation of the line we consider current; callbacks for any other generation are stale.
    /// Bumped by `speakNow` (new line) and by `stopCurrent` (cancel), so every in-flight fetch,
    /// player callback and watchdog captured under an older value becomes a no-op.
    @ObservationIgnored private var generation = 0
    /// Priority of the line playing, or nil when idle; compared against incoming lines in `say`.
    @ObservationIgnored private var currentPriority: SpeechPriority?
    /// The whole text of the line now playing (never the resumed remainder); "" when idle. Compared
    /// by `say` for coalescing and re-queued by `requeueCurrent` on interrupt.
    @ObservationIgnored private var currentText = ""
    /// When the line now playing stops being worth resuming (reference-date seconds): the deadline
    /// `say` / `sayAgain` computed from its TTL — also for a line that started at once, which is what
    /// bounds a resume after a cut — or `.infinity` for `say(ttl: 0)` and `speakNow`'s default.
    @ObservationIgnored private var currentExpires: TimeInterval = .infinity
    /// How many times the line playing has already been resumed after a cut.
    @ObservationIgnored private var currentReplays = 0
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
    /// True after a safety line has used its one watchdog system-voice fallback. A permanently
    /// stalled backend must not make the safety line loop forever.
    @ObservationIgnored private var watchdogFallbackUsed = false
    /// True during the short pause `lineEnded` leaves before a line of a different band
    /// (`SpeechResume.gapSeconds`, 0.35 s). `isSpeaking` stays true (the beacon stays ducked) and
    /// nothing is current; `say` queues everything except `.safety`, or a line that needs no pause
    /// after `gapAfter` and ties or outranks the queue head — those end the pause and speak.
    /// `sayAgain` (explicit Repeat) also speaks through it. Cleared by `speakNow`, `stopCurrent`,
    /// `stopAll` and the pause task itself.
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
    /// Generation of the current interruption episode. A retry from an older `.ended` must not
    /// clear a newer `.began` episode or drain speech into a call / Siri session.
    @ObservationIgnored private var interruptionGeneration: UInt64 = 0
    /// Delayed activation retry for the current interruption episode.
    @ObservationIgnored private var interruptionRetryTask: Task<Void, Never>?
    /// The natural voice's session-sticky circuit breaker (CaneKitLogic `VoiceBreaker`, Step 54;
    /// replaces Step 30's 60 s `naturalVoiceFailedAt` timestamp, Muse M1). Tripped by `resolveRace`
    /// on a timeout / failure, closed only by `prefetchPass` after a chunk that fetched something.
    /// Every change goes to `onBreakerChanged` and `naturalVoiceOffline`.
    @ObservationIgnored private var breaker = VoiceBreaker()
    /// While the breaker is open: wakes every `VoiceBreaker.probeInterval` and re-runs the prefetch
    /// worker over the backlog (the lines that missed are in it). Cancelled when the breaker closes.
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    /// Lines asked for by `prefetch` and not yet fetched, newest batch first (Step 54). The worker
    /// merges it with `routeLines + backgroundLines` on every pass and removes a chunk only once it
    /// was fetched; a failed chunk stays for the next `prefetch` call or the breaker probe.
    @ObservationIgnored private var prefetchBacklog: [String] = []
    /// The system-voice utterance that is current; `utteranceEnded` matches callbacks against it
    /// by `ObjectIdentifier`, so a cancelled utterance's late `didCancel` is ignored.
    @ObservationIgnored private var currentUtterance: AVSpeechUtterance?
    /// Unstick timer for the current line (see `armWatchdog`); cancelled when the line ends.
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    /// The ElevenLabs mp3 player for the current line (nil while the system voice speaks).
    @ObservationIgnored private var player: AVAudioPlayer?
    /// Strong reference to `player`'s delegate (AVAudioPlayer holds its delegate weakly).
    @ObservationIgnored private var playerRelay: PlayerRelay?
    /// The one prefetch worker (Step 54): drains `prefetchBacklog` + the standing tail one chunk at
    /// a time and clears itself when there is nothing left or a chunk failed. Never cancelled by a
    /// new batch — `prefetch` appends and, if this is nil, starts it.
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
    /// Generation of the microphone lease. A delayed restore from an old lease must not put a new
    /// lease back on `.playback` underneath it.
    @ObservationIgnored private var microphoneLeaseGeneration: UInt64 = 0
    /// Bounded retry for returning a failed microphone lease to `.playback`.
    @ObservationIgnored private var microphoneRestoreTask: Task<Void, Never>?

    /// System-voice rate (AVSpeech units, 0…1): 5 % above the default — brisk but clear while
    /// walking. Ignored by the ElevenLabs backend (the mp3 has its own pace).
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate * 1.05

    /// Wires the synthesizer delegate through the `nonisolated` relay. The relay's callback is
    /// `@Sendable` and may run on any AVFoundation thread, so it captures only the utterance's
    /// `ObjectIdentifier` (plus, for `onWord`, the word's UTF-16 location) and hops to the main
    /// actor before touching queue state. Also picks the system voice once (`bestEnglishVoice`).
    /// Built by `AppModel`'s property initialiser (`speech`), before anything can speak.
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
    /// Called by `AppModel.start()` right after the trip-log hooks (`onSuppressed`, `onDispatch`,
    /// `onLineEnd`) are installed and before `wireAudioRoute()`, `haptics.start()` and
    /// `depth.start()`. Calling it twice replaces the prior observer so interruption delivery stays
    /// single-shot. A success also clears `microphoneRestoreError`.
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
        // Keep this method idempotent even for test / recovery callers. Replacing the token
        // without removing it leaves an old observer alive and duplicates every interruption.
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
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
        /// `SoundWatcher` ("Listen for sirens and horns", off by default); may hold the lease for
        /// a whole walk, and is the only owner that installs `onMicrophoneRouteChanged`.
        case soundRecognition
        /// `VoiceInputEngine` push-to-talk ("Talk to OpenCane"); holds it for one utterance (≤ 10 s,
        /// `UtteranceEndDetector.maxListen`) and is refused while sound recognition owns the input.
        case voiceInput
    }

    /// Lifecycle edges forwarded to the push-to-talk owner. The queue owns the shared audio
    /// session; `VoiceInputEngine` decides whether its capture can continue.
    enum MicrophoneInterruption: String, Equatable, Sendable {
        case began
        case ended
    }

    /// What asking for microphone input did to the audio route.
    /// Returned by `setMicrophoneEnabled(_:owner:)` so the caller can tell the walker the truth.
    enum MicrophoneSessionResult: Equatable, Sendable {
        /// The output route is unchanged. The input may still be settling; callers must inspect
        /// `microphoneRouteSnapshot` before declaring a classifier live. `route` is the output-route
        /// string (`outputRoute`). Also returned by a successful `setMicrophoneEnabled(false, …)`
        /// (the route now) and by a repeated grant to the owner already holding the lease (the held
        /// route's output).
        case granted(route: String)
        /// Input was available but the output route changed (e.g. AirPods dropped from A2DP to
        /// HFP call quality, which would kill the HRTF beacon). The session has already been put
        /// back to `.playback`; the caller must not enable its recording feature.
        case revertedRouteChanged(before: String, after: String)
        /// `setCategory` / `setActive` threw (the restore to `.playback` was attempted; if that
        /// also threw, `microphoneRestoreError` says so), or the lease belongs to the other owner
        /// (nothing was changed). The payload is a technical message for the card / trip log, never
        /// for speech.
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
    /// voice at call quality, and nothing ever tells them. Set by `SoundWatcher` once its session is
    /// granted (`startGrantedSession`) and cleared by `SoundWatcher.stop()` / `fail`.
    /// `VoiceInputEngine` installs no hook, so a revert during push-to-talk is silent to it.
    @ObservationIgnored var onMicrophoneRouteChanged: ((SoundRecognitionRoute, SoundRecognitionRoute) -> Void)?

    /// Route callback for the push-to-talk owner. It is separate from the sound-recognition hook
    /// because the two features have different teardown and cue paths while sharing one lease.
    @ObservationIgnored var onVoiceInputRouteChanged: ((SoundRecognitionRoute, SoundRecognitionRoute) -> Void)?

    /// Interruption edges for push-to-talk. The voice owner fails closed on `.began` and never
    /// resumes a partial transcript after `.ended`.
    @ObservationIgnored var onVoiceInputInterruption: ((MicrophoneInterruption) -> Void)?

    /// The complete route as it was when the microphone was granted; nil whenever the session is
    /// on plain `.playback`. Every route-change notification is compared against this, not against
    /// the previous notification, so a route that wanders away and is still wrong is still caught.
    @ObservationIgnored private var microphoneRoute: SoundRecognitionRoute?

    /// The complete route snapshot held while any owner has `.playAndRecord`; nil on `.playback`.
    /// Read by `SoundWatcher` immediately after `setMicrophoneEnabled(true, owner:)` (and again
    /// once its engine runs) so its pure guard starts with the same input/output identity the
    /// notification observer is watching.
    var microphoneRouteSnapshot: SoundRecognitionRoute? { microphoneRoute }

    /// Last failure while returning the microphone to `.playback`, if any. SoundWatcher includes
    /// this in its existing failure card/speech path instead of claiming a restore succeeded.
    /// Set by `restorePlaybackSession`; cleared by any successful `configureAudioSession`, grant or
    /// restore, and by `SoundWatcher.start()` before a new attempt.
    @ObservationIgnored var microphoneRestoreError: String?

    /// The owner of the temporary `.playAndRecord` lease, or nil in the normal `.playback` state.
    /// Cleared when a restore to `.playback` succeeds, or after the bounded recovery window is
    /// exhausted. During that window the lease stays with its owner, so the other feature cannot
    /// grab a session in an unknown state; after exhaustion, clearing the stale owner lets a later
    /// explicit start attempt re-establish the session rather than leaking a permanently dead lease.
    @ObservationIgnored private var microphoneOwner: MicrophoneOwner?

    /// Token for the `AVAudioSession.routeChangeNotification` observer. Non-nil **only** while the
    /// microphone is on: the guard costs nothing the rest of the time, and removing it before the
    /// revert is what stops our own `setCategory(.playback)` from re-entering the handler.
    @ObservationIgnored private var routeChangeObserver: NSObjectProtocol?

    /// Receives an optional line that the load policy dropped, so `TripLogger` can show what the
    /// sensors produced and why the walker did not hear it. Arguments: trimmed text, the caller's
    /// load class, the policy's reason (`busy` / `calmWindow` / `invalidTime`). Main actor; set by
    /// `AppModel.start()`, logged as `speech_suppressed {text, load, reason}`.
    @ObservationIgnored var onSuppressed: ((String, SpeechLoadClass, SpeechSuppressionReason) -> Void)?

    /// Receives every line at the moment the queue hands it to a voice backend (`speakNow`),
    /// whoever queued it and whether it started at once or drained from the queue.
    /// ⚠ Why: `speech` trip-log records are written by *callers* (cues, route lines), so lines said
    /// straight through `say` — the both-cameras refusal, flashlight confirmations — left no trace,
    /// and a device log could not tell "dropped by the queue" from "dispatched" (trip log
    /// 2026-09-12T20-57-17Z, t = 84 s). ⚠ Dispatched is not heard: the line may still be cut by a
    /// higher priority, fail to fetch, or be muted automation — it proves the queue did not drop
    /// it, nothing more (Step 34 review). Arguments: whole text, priority, replay count (> 0 when a
    /// cut line resumes, so a resumed line appears twice), the UTF-16 offset it starts from
    /// (`resumeFrom`, 0 for a fresh line; Step 37), and the engine decision made *before* this call
    /// (`VoiceEngineChoice.decide`, Step 53: `engine` elevenlabs / system / race / muted and its
    /// `reason`; a `race` is resolved later through `onEngineResolved`). Main actor; set by
    /// `AppModel.start()`, logged as `speech_dispatch {text, priority, replays, resume_from, engine,
    /// engine_reason}` (a separate kind, so `e2e.py`'s `speech` assertions keep their meaning).
    /// Fires under `muted` too. Also forwards the text to `VoiceInputEngine.noteDispatched` (Step 55).
    @ObservationIgnored var onDispatch: ((String, SpeechPriority, Int, Int, VoiceEngineDecision) -> Void)?
    /// How a dispatched line's engine was finally settled (Step 53): `race_won` / `race_timeout` /
    /// `race_failed` with the milliseconds since the race started, or `playback_failed` (an mp3 that
    /// would not play; wait 0). Arguments: the whole line, the outcome, `wait_ms`. Main actor; set by
    /// `AppModel.start()`, logged as `speech_engine {text, engine, engine_reason, wait_ms}`.
    @ObservationIgnored var onEngineResolved: ((String, VoiceEngineReason, Int) -> Void)?
    /// Every `VoiceBreaker` state change (Step 54): `(open, reason)` with reason `race_timeout` /
    /// `race_failed` (opened) or `prefetch_succeeded` (closed). Main actor; set by `AppModel.start()`,
    /// logged as `voice_breaker {open, reason}`.
    @ObservationIgnored var onBreakerChanged: ((Bool, String) -> Void)?
    /// Receives the priority of each line that ENDED naturally (finished, or its watchdog fired), at
    /// the moment `lineEnded` starts the next one or the pause before it. Logged as `speech_end` so
    /// `cue_audit.py` can measure the pause between one line's end and the next start — start times
    /// alone cannot see a missing 0.35 s pause (review agents, Step 37). Main actor. Not fired for a
    /// line that was cut (pre-emption, `stopAll`, interruption, voice hold): those never reach
    /// `lineEnded` with their own generation. Set by `AppModel.start()`.
    @ObservationIgnored var onLineEnd: ((SpeechPriority) -> Void)?

    /// Switch the app's one audio session between `.playback` (the normal state) and
    /// `.playAndRecord`, which is the only way to get an `AVAudioEngine` input node for the
    /// danger-sound watch (`.playback` has no input at all — Apple's category table).
    ///
    /// This is the **only** other shipping `setCategory` path in the app besides
    /// `configureAudioSession()` (its revert, `restorePlaybackSession`, re-applies that same
    /// `.playback` configuration; the debug `SensorProbe` has its own behind a launch argument),
    /// and it exists because AGENTS.md hard rule 7 / ios/README.md §2
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
    ///     passed. Any later output change, or input port / quality change (HFP, input gone),
    ///     reverts the session and calls `onMicrophoneRouteChanged` — except the startup settle from
    ///     no input to a usable one (`outputRouteMayHaveChanged`). Speech, warnings and the beacon
    ///     are the safety path and a microphone feature never outranks them.
    ///   · One owner at a time (`MicrophoneOwner`, Step 28): a second feature gets `.failed` and the
    ///     session is left untouched, so push-to-talk can never replace the sound watcher's route
    ///     observer or restore `.playback` under it.
    ///
    /// Measured on the iPhone 17 Pro Max (2026-09-11, trip-log `probe_e_audio_session`): with no
    /// headphones, `.playAndRecord` + these options left the output at `Speaker` and added
    /// `MicrophoneBuiltIn` as an input, and restoring `.playback` worked. The AirPods case is
    /// **not** measured yet, which is why the continuous watch above exists rather than a promise.
    /// Caller: `SoundWatcher.start()` / `stop()` and `VoiceInputEngine`'s push-to-talk path.
    /// - Parameters:
    ///   - on: true to take the lease and switch to `.playAndRecord`; false to give it back. `false`
    ///     from the owner, or when nobody holds the lease, always attempts the `.playback` restore
    ///     (idempotent); from the other owner it is refused with `.failed`.
    ///   - owner: which feature is asking. A repeat `true` from the current owner returns
    ///     `.granted` with the held route and changes nothing.
    /// - Returns: what happened to the route; callers must not start recording on anything but
    ///   `.granted`. Main actor; `setCategory` / `setActive` are synchronous calls on main (duration
    ///   not measured).
    func setMicrophoneEnabled(_ on: Bool, owner: MicrophoneOwner) -> MicrophoneSessionResult {
        let session = AVAudioSession.sharedInstance()
        guard on else {
            guard microphoneOwner == nil || microphoneOwner == owner else {
                return .failed("Microphone is owned by another OpenCane feature.")
            }
            stopWatchingOutputRoute()
            let leaseGeneration = microphoneLeaseGeneration
            let result = restorePlaybackSession()
            if result == nil {
                microphoneOwner = nil
                microphoneLeaseGeneration &+= 1
                microphoneRestoreTask?.cancel()
                microphoneRestoreTask = nil
            } else {
                scheduleMicrophoneRestore(owner: owner, generation: leaseGeneration)
            }
            return result ?? .granted(route: Self.outputRoute(session))
        }
        if let microphoneOwner, microphoneOwner != owner {
            return .failed("Microphone is already in use by another OpenCane feature.")
        }
        if microphoneOwner == owner, let route = microphoneRoute {
            return .granted(route: route.output)
        }
        // A previous restore may still be retrying after a transient failure. A fresh grant from
        // the same owner supersedes that old lease and fences its delayed task.
        microphoneRestoreTask?.cancel()
        microphoneRestoreTask = nil
        microphoneLeaseGeneration &+= 1
        let before = Self.outputRoute(session)
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.duckOthers, .allowBluetoothA2DP, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            audioSessionError = "Microphone session: \(error.localizedDescription)"
            // `setCategory` may have changed the session before `setActive` failed. Claim the
            // lease for the recovery window so a second input feature cannot race the playback
            // restore; the bounded task clears this temporary owner if recovery never succeeds.
            microphoneOwner = owner
            if restorePlaybackSession() == nil {
                microphoneOwner = nil
                microphoneLeaseGeneration &+= 1
                microphoneRestoreTask?.cancel()
                microphoneRestoreTask = nil
            } else {
                scheduleMicrophoneRestore(owner: owner, generation: microphoneLeaseGeneration)
            }
            return .failed(error.localizedDescription)
        }
        let after = Self.outputRoute(session)
        guard after == before else {
            // This was a refused grant, but the category may already have moved. Keep ownership
            // while the failed playback restore retries, otherwise a different microphone user
            // could start against the unknown route state.
            microphoneOwner = owner
            if restorePlaybackSession() == nil {
                microphoneOwner = nil
                microphoneLeaseGeneration &+= 1
                microphoneRestoreTask?.cancel()
                microphoneRestoreTask = nil
            } else {
                scheduleMicrophoneRestore(owner: owner, generation: microphoneLeaseGeneration)
            }
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
    /// observer above); only a decoded `Bool` route edge crosses into the isolated call — true when
    /// the notification's reason is `.oldDeviceUnavailable` (a device went away), which
    /// `outputRouteMayHaveChanged` treats as an input drop even if the route already looks healthy.
    /// Idempotent: a second call replaces the observer rather than stacking one.
    /// Caller: `setMicrophoneEnabled(true, owner:)` after a successful grant.
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
    ///
    /// Clears `microphoneOwner` only when the restore succeeded, then calls
    /// `onMicrophoneRouteChanged(held, now)` either way (SoundWatcher retries a failed restore).
    /// - Parameter forceInputDrop: the notification said `.oldDeviceUnavailable`; if the sampled
    ///   route equals the held one anyway, it is recorded as `inputQuality: .unavailable` so the
    ///   dropout still stops recognition (Step 28).
    private func outputRouteMayHaveChanged(forceInputDrop: Bool = false) {
        guard let held = microphoneRoute else { return }
        let owner = microphoneOwner
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
            switch owner {
            case .soundRecognition:
                onMicrophoneRouteChanged?(held, now)
            case .voiceInput:
                onVoiceInputRouteChanged?(held, now)
            case nil:
                break
            }
            return
        }
        // Order matters: drop the observer *before* reverting, or our own `setCategory(.playback)`
        // posts another route change straight back into this method.
        stopWatchingOutputRoute()
        let restoreResult = restorePlaybackSession()
        if restoreResult == nil {
            microphoneOwner = nil
            microphoneLeaseGeneration &+= 1
            microphoneRestoreTask?.cancel()
            microphoneRestoreTask = nil
        } else if let owner {
            scheduleMicrophoneRestore(owner: owner, generation: microphoneLeaseGeneration)
        }
        switch owner {
        case .soundRecognition:
            onMicrophoneRouteChanged?(held, now)
        case .voiceInput:
            onVoiceInputRouteChanged?(held, now)
        case nil:
            break
        }
    }

    /// Put the session back to the one configuration the rest of the app relies on — byte-for-byte
    /// the `configureAudioSession` category, mode and options. Does not touch the lease or the
    /// observer; callers do (`stopWatchingOutputRoute` must run first whenever an observer is live).
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

    /// Retry a failed microphone-to-playback transition without clearing the owner early. Keeping
    /// the owner blocks a competing input feature while the audio category is unknown; the lease
    /// generation prevents this recovery from racing a fresh grant by the same owner. If the
    /// bounded window is exhausted, clear the stale lease so a future explicit start can recover
    /// instead of leaving all microphone features permanently refused.
    private func scheduleMicrophoneRestore(owner: MicrophoneOwner, generation leaseGeneration: UInt64) {
        microphoneRestoreTask?.cancel()
        microphoneRestoreTask = Task { @MainActor [weak self] in
            for _ in 0..<MicrophoneSessionRecovery.retryAttempts {
                try? await Task.sleep(for: .seconds(MicrophoneSessionRecovery.retryDelay))
                guard let self, !Task.isCancelled,
                      self.microphoneOwner == owner,
                      self.microphoneLeaseGeneration == leaseGeneration,
                      self.microphoneRoute == nil else { return }
                if self.restorePlaybackSession() == nil {
                    self.microphoneOwner = nil
                    self.microphoneLeaseGeneration &+= 1
                    self.microphoneRestoreTask = nil
                    return
                }
            }
            guard let self, !Task.isCancelled,
                  self.microphoneOwner == owner,
                  self.microphoneLeaseGeneration == leaseGeneration,
                  self.microphoneRoute == nil else { return }
            self.microphoneOwner = nil
            self.microphoneLeaseGeneration &+= 1
            self.microphoneRestoreTask = nil
        }
    }

    /// The current **output** route as a stable string (for example
    /// `BluetoothA2DP[uid|AirPods]` or `Speaker[...]`), including each port's UID/name for the
    /// before/after comparison, continuous watch and trip log. Ports are sorted and joined with
    /// "+", so ordering noise in `currentRoute.outputs` is never a "change"; "none" with no output.
    private static func outputRoute(_ session: AVAudioSession) -> String {
        let ports = session.currentRoute.outputs.map(portDescription).sorted()
        return ports.isEmpty ? "none" : ports.joined(separator: "+")
    }

    /// Include UID and human-readable name, not only the port type: two AirPods or USB inputs can
    /// share a type while still being a real route change that must stop recognition.
    /// Format: `portType[uid|name]` (either part omitted when blank), or the bare port type.
    /// ⚠ The result reaches the trip log and the Hazards card only — never speech (a port name read
    /// aloud means nothing to a walker; `SoundWatcher.fail`).
    private static func portDescription(_ port: AVAudioSessionPortDescription) -> String {
        let type = port.portType.rawValue
        let uid = port.uid.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = port.portName.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = [uid, name].filter { !$0.isEmpty }.joined(separator: "|")
        return identity.isEmpty ? type : "\(type)[\(identity)]"
    }

    /// Build the Sendable route snapshot used by `SoundRecognitionGuard`. Input quality is derived
    /// from the actual port list, never from the requested category: HFP and a missing input are
    /// unsafe even if the output port still looks unchanged. Quality: `.hfp` if any input or output
    /// port is Bluetooth HFP, else `.unavailable` with no input port, else `.usable`;
    /// `outputIsHFP` lets `SoundRecognitionGuard` refuse a route that was degraded before startup.
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
    /// `.began`: re-queue the current line — from its last resume point, not the clause it was cut in
    /// (`requeueCurrent(fromClause: false)`: after a call a clause fragment has no context; subject
    /// to `SpeechResume.nextResume` and its TTL), cancel the
    /// backends (bumping `generation` so their late callbacks are ignored), set `interrupted`,
    /// and arm the 15 s `interruptionFallback`. `.ended`: cancel the fallback and resume.
    /// `.ended`'s `shouldResume` option is not consulted: guidance resumes regardless.
    /// `BeaconEngine` observes the same notification independently and restarts its own graph;
    /// `SoundWatcher` observes it too and stops on `.began`.
    /// Main actor (called from the main-queue observer via `assumeIsolated`).
    private func interruption(_ type: AVAudioSession.InterruptionType) {
        let microphoneWasOwned = microphoneOwner != nil
        // The voice callback is installed immediately before activation, while the lease owner is
        // assigned only after `setActive` returns. Include the callback itself so an interruption
        // during that narrow activation window cannot be missed.
        let voiceInputWasActive = onVoiceInputInterruption != nil
        switch type {
        case .began:
            interruptionGeneration &+= 1
            interruptionRetryTask?.cancel()
            interruptionRetryTask = nil
            // Mark the queue interrupted before the owner surfaces a failure. Its spoken cue must
            // wait for the call/Siri session to end rather than trying to speak into it.
            interrupted = true
            if microphoneWasOwned || voiceInputWasActive { onVoiceInputInterruption?(.began) }
            if isSpeaking { requeueCurrent(fromClause: false) }
            stopCurrent()
            isSpeaking = false
            currentPriority = nil
            currentText = ""
            // `.ended` is not guaranteed (the interrupting app may never deactivate): drain anyway.
            interruptionFallback?.cancel()
            let episode = interruptionGeneration
            interruptionFallback = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled, self.interrupted,
                      self.interruptionGeneration == episode else { return }
                self.interruptionFallback = nil
                self.resumeAfterInterruption(attempt: 0, fromEnded: false, generation: episode)
            }
        case .ended:
            if microphoneWasOwned || voiceInputWasActive { onVoiceInputInterruption?(.ended) }
            interruptionFallback?.cancel()
            interruptionFallback = nil
            interruptionRetryTask?.cancel()
            interruptionRetryTask = nil
            resumeAfterInterruption(attempt: 0, fromEnded: true, generation: interruptionGeneration)
        @unknown default:
            break
        }
    }

    /// Re-activate the session (it can fail right at `.ended` while the call's session winds
    /// down — retry twice, a second apart), then drain whatever queued up meanwhile.
    ///
    /// - Parameter attempt: 0 on the first try; retries at 1 and 2. After the last failure the
    ///   queue stays interrupted and retries from the fallback rather than consuming guidance
    ///   while the session is still unavailable; the error remains in `audioSessionError`.
    /// Draining goes through `lineEnded(gen: generation)` — the current generation, so the guard
    /// passes — which purges expired lines and starts the head of the queue (no cross-band pause:
    /// nothing current means no previous band).
    /// Retry tasks inherit the main actor (unstructured `Task` in a main-actor method).
    /// - Parameter fromEnded: true when the system posted `.ended`; false for our own 15 s
    ///   fallback. Without `.ended`, a failed re-activation means the call is probably still on:
    ///   keep waiting (re-arm the fallback) instead of draining lines over it (Muse M3).
    private func resumeAfterInterruption(attempt: Int, fromEnded: Bool, generation episode: UInt64) {
        guard interruptionGeneration == episode, interrupted else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            audioSessionError = "Audio resume: \(error.localizedDescription)"
            if attempt < 2 {
                interruptionRetryTask?.cancel()
                interruptionRetryTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled,
                          self.interruptionGeneration == episode, self.interrupted else { return }
                    self.interruptionRetryTask = nil
                    self.resumeAfterInterruption(attempt: attempt + 1, fromEnded: fromEnded,
                                                 generation: episode)
                }
                return
            }
            // Keep the episode interrupted after a failed final activation. Draining here would
            // consume safety/nav lines while the session is still unavailable. The fallback retries
            // both the `.ended` and missing-`.ended` cases until a later activation succeeds.
            let retryEpisode = interruptionGeneration
            interruptionFallback?.cancel()
            interruptionFallback = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled, self.interrupted,
                      self.interruptionGeneration == retryEpisode else { return }
                self.interruptionFallback = nil
                self.resumeAfterInterruption(attempt: 0, fromEnded: false,
                                             generation: retryEpisode)
            }
            _ = fromEnded
            return
        }
        interruptionRetryTask?.cancel()
        interruptionRetryTask = nil
        interrupted = false
        if !isSpeaking { lineEnded(gen: generation) }
    }

    // MARK: Speaking

    /// Speak `text`. Higher priority than the current line interrupts it; otherwise it queues.
    /// - Parameters:
    ///   - text: trimmed before use; the trimmed text is the coalescing and cache key, so callers
    ///     that want the natural voice must pass bytes identical to the prefetched line.
    ///   - priority: the band (see `SpeechPriority`).
    ///   - ttl: seconds the line stays valid while waiting (≤ 0 = never expires). Also bounds a
    ///     resume after the line is cut (`requeueCurrent`).
    ///   - load: `.normal` (fail-open) or `.ambientObstacleName`, which `SpeechLoadPolicy` may drop.
    /// - Returns: true when the line started or was queued; false when it was empty, suppressed by
    ///   the load policy, or coalesced with an identical line. `AppModel` writes its `speech`
    ///   trip-log record only on true.
    ///
    /// Decision order:
    /// 1. Whitespace-only text is ignored. Then the load policy (`loadPolicy.admit`, busy =
    ///    speaking, in a pause, or interrupted): a suppressed line goes to `onSuppressed`, returns false.
    /// 2. During a call/Siri interruption the line is queued (unless identical text is already
    ///    queued) and nothing plays until `.ended` / the 15 s fallback. While the voice hold is
    ///    on (the walker is dictating) the same queueing applies to everything below `.safety`;
    ///    `.safety` skips the hold — only a taken-away audio session outranks a curb.
    /// 3. In the pause between bands (`inGap`): `.safety`, or a line needing no pause after the band
    ///    that ended and tying or outranking the queue head, ends the pause and speaks now; anything
    ///    else is coalesced against the queue or appended.
    /// 4. While speaking: a strictly higher priority re-queues the current line (front of its
    ///    band, to resume from its clause — `requeueCurrent`), stops it and speaks now; equal/lower priority is coalesced away if
    ///    identical to the playing or a queued line, else appended FIFO within its band.
    /// 5. Idle: speaks immediately. The TTL only matters while waiting in the queue; a line
    ///    that starts at once plays in full.
    /// Callers pick TTLs per line type (AppModel: obstacle names 4 s, cue lines 6 s, ground hazards
    /// 3 s, route lines 12 s, channel / permission lines 20 s, arrival summary 30 s; SceneDescriber
    /// results 20 s; conversation answers 8–15 s). The voice is chosen when the line is dispatched,
    /// not here (`speakNow`, `VoiceEngineChoice`). Main actor.
    @discardableResult
    func say(_ text: String, _ priority: SpeechPriority, ttl: TimeInterval = 8,
             load: SpeechLoadClass = .normal) -> Bool {
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
            queue.append(Pending(text: line, priority: priority, expires: expires, sequence: sequence))
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
                speakNow(line, priority, expires: expires)
                return true
            }
            guard !queue.contains(where: { $0.text == line }) else { return false }
            sequence += 1
            queue.append(Pending(text: line, priority: priority, expires: expires, sequence: sequence))
            sortQueue()
            return true
        }
        if isSpeaking, let cp = currentPriority {
            if priority > cp {
                requeueCurrent()             // resume the cut line after this one
                stopCurrent()
                speakNow(line, priority, expires: expires)
            } else {
                guard line != currentText, !queue.contains(where: { $0.text == line }) else { return false }   // coalesce
                sequence += 1
                queue.append(Pending(text: line, priority: priority, expires: expires, sequence: sequence))
                sortQueue()
            }
            return true
        }
        speakNow(line, priority, expires: expires)
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
                             resumeFrom: offset, lastResumeOffset: offset))
        sortQueue()
    }

    /// "Say that again": always speaks, even when `text` is the line playing right now (plain
    /// `say` would coalesce it away). Interrupts an equal-or-lower line, queues behind a higher one.
    ///
    /// Explicit Repeat wins the pause between bands too: during `inGap` it speaks at once unless the
    /// line the pause is waiting to start outranks it (the pause
    /// exists to separate unasked lines; the walker asked for this one — Muse, Step 37, accepted).
    /// Any queued copy of `text` is removed first so it cannot play twice. The line it cuts is
    /// *not* re-queued (the user explicitly asked for this line instead). During an interruption
    /// it only queues. `ttl` is always finite here (default 12 s) — unlike `say`, `ttl: 0` does
    /// not mean "never expires"; a queued line with `ttl: 0` would be purged at the next drain.
    /// Bypasses the load policy and the voice hold (an explicit request wins).
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

    /// Pre-synthesize lines the app will need (no-op without the natural voice, or when
    /// `useNaturalVoice` is false; `muted` does not gate it).
    ///
    /// Additive (Step 54): `lines` go to the front of `prefetchBacklog` (repeats dropped) and the one
    /// worker is started if it is not running. Nothing in flight is cancelled — before Step 54 every
    /// call cancelled the running batch, so each warning that missed the cache threw away whatever a
    /// route start or the launch warm-up had not reached yet. Each worker pass merges the backlog
    /// with `routeLines + backgroundLines` (`VoicePrefetch.merge`, off main: the cache checks are a
    /// hash and a `stat` per line) and requests the first `VoicePrefetch.chunk` uncached lines, so a
    /// line merged in mid-warm-up is requested within one chunk and at most `maxConcurrent` requests
    /// are ever in flight from here. The network work runs on a detached `.utility` task and never
    /// on (or blocking) the main actor.
    ///
    /// Callers: `AppModel.start()` (safety lines + common lines at launch), route starts
    /// (`buildRoute`, `queueRouteStart`, `startRouteNow`: the announce, the intro and every waypoint
    /// line), `speakNow` (a warning or breaker-open line that came out in the system voice, a line
    /// whose race failed or timed out), `AppModel`'s emergency-profile and shell lines.
    /// - Parameter lines: lines in the order they will be spoken. Blank lines are ignored.
    /// Clears `voiceError` (a new attempt; a failing chunk writes a fresh one, never while the app is
    /// backgrounded, where suspension shows up as a timeout).
    func prefetch(_ lines: [String]) {
        guard naturalVoice != nil, useNaturalVoice else { return }
        voiceError = nil
        prefetchBacklog = VoicePrefetch.queue(lines + prefetchBacklog) { _ in false }
        runPrefetchWorker()
    }

    /// Start the prefetch worker unless one is running. The loop holds `self` only across a pass
    /// and clears `prefetchTask` when `prefetchPass` says stop. Callers: `prefetch`, the breaker
    /// probe (`armBreakerProbe`) and `useNaturalVoice` switching back on.
    private func runPrefetchWorker() {
        guard prefetchTask == nil, naturalVoice != nil, useNaturalVoice else { return }
        prefetchTask = Task { [weak self] in
            while let self, await self.prefetchPass() {}
            self?.prefetchTask = nil
        }
    }

    /// One worker pass: merge, fetch one chunk, account for it.
    /// - Returns: true to run another pass — the chunk was fetched, or it was empty but lines were
    ///   merged in while the (off-main) merge ran; false when there is nothing left to fetch, a chunk
    ///   failed (the backlog is kept for the next `prefetch` or probe), the voice went away or was
    ///   switched off.
    /// A fetched chunk is removed from the backlog and, if the breaker is open, closes it
    /// (`VoiceBreaker.prefetchSucceeded(requested:)`: only a chunk that requested ≥ 1 line is proof).
    private func prefetchPass() async -> Bool {
        guard let naturalVoice, useNaturalVoice else { return false }
        let backlog = prefetchBacklog
        let tail = routeLines + backgroundLines
        let (chunk, failure) = await Task.detached(priority: .utility) { () async -> ([String], String?) in
            let pending = VoicePrefetch.merge(new: [], backlog: backlog, tail: tail) { naturalVoice.cached($0) != nil }
            let chunk = Array(pending.prefix(VoicePrefetch.chunk))
            guard !chunk.isEmpty else { return ([], nil) }
            return (chunk, await naturalVoice.prefetch(chunk))
        }.value
        guard !chunk.isEmpty else {
            if prefetchBacklog != backlog { return true }   // new lines arrived during the merge
            prefetchBacklog.removeAll()                      // everything left is already on disk
            return false
        }
        if let failure {
            // Only report; never let a prefetch failure disable the voice (the live path has the
            // breaker, and the cache may already hold the line that matters). Backgrounding surfaces
            // as a timeout, not a cancellation, and is not a voice problem.
            if UIApplication.shared.applicationState != .background { voiceError = failure }
            return false
        }
        prefetchBacklog.removeAll { chunk.contains($0) }
        if breaker.prefetchSucceeded(requested: chunk.count) {
            naturalVoiceOffline = false
            probeTask?.cancel()
            probeTask = nil
            onBreakerChanged?(false, VoiceBreaker.Reason.prefetchSucceeded.rawValue)
        }
        return true
    }

    /// Open the breaker (if it was closed), log it and start the probe. Caller: `resolveRace`.
    /// - Parameter reason: `raceTimeout` or `raceFailed`.
    private func tripBreaker(_ reason: VoiceBreaker.Reason) {
        guard breaker.trip(reason, now: Date().timeIntervalSinceReferenceDate) else { return }
        naturalVoiceOffline = true
        onBreakerChanged?(true, reason.rawValue)
        armBreakerProbe()
    }

    /// While the breaker is open, every `VoiceBreaker.probeInterval` (60 s) mark a probe and run the
    /// prefetch worker: a dead network costs one small chunk a minute and never a line's 2.5 s. The
    /// probe's payload is the backlog (every line that missed while open is prefetched by
    /// `speakNow`); with nothing uncached to fetch it proves nothing and the breaker stays open —
    /// harmless, because then every line is on disk and plays in the natural voice anyway. The task
    /// ends when the breaker closes; it inherits the main actor.
    private func armBreakerProbe() {
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(VoiceBreaker.probeInterval))
                guard let self, !Task.isCancelled, self.breaker.isOpen else { return }
                let now = Date().timeIntervalSinceReferenceDate
                guard self.breaker.probeDue(now: now) else { continue }
                self.breaker.probed(now: now)
                self.runPrefetchWorker()
            }
        }
    }

    /// Share (0…1) of `lines` whose exact bytes are on disk — the "voice ready" fact (Step 54,
    /// `StatusSummary.voiceLine`). Repeats and blank lines count once / not at all; an empty list is
    /// 1; no key is 0. Synchronous: a hash and a `stat` per line on main (~150 lines, called once per
    /// spoken status), never per frame. Caller: `AppModel.voiceFacts()`.
    /// - Parameter lines: `AppModel.voiceReadyLines`.
    func cachedShare(of lines: [String]) -> Double {
        guard let naturalVoice else { return 0 }
        let unique = VoicePrefetch.queue(lines) { _ in false }
        guard !unique.isEmpty else { return 1 }
        let onDisk = unique.filter { naturalVoice.cached($0) != nil }.count
        return Double(onDisk) / Double(unique.count)
    }

    /// Hold (`true`) or release (`false`) the speech channel while the walker dictates.
    ///
    /// On hold: the playing line is cut unless it is `.safety`, and re-queued subject to the
    /// usual resume rule (AGENTS.md: interrupted lines are re-queued; Repeat recovers the
    /// rest) — but from its last resume point, not the cut clause (`fromClause: false`: after a
    /// conversation a fragment has no context). A pending pause between bands is ended too
    /// (`isSpeaking` is true and nothing is current, so `stopCurrent` clears `inGap` and bumps the
    /// generation its task holds); the line it was waiting for stays queued for the release. New lines below `.safety` queue with their TTLs instead of playing; `.safety`
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
            }
            return
        }
        if !isSpeaking { lineEnded(gen: generation) }
    }

    /// Drop everything waiting and stop the current line (used when a route ends).
    /// Nothing is re-queued. Does not clear `interrupted`; a later `say` still obeys an active
    /// call. `AppModel.stopRoute` calls this before speaking "Route stopped." so queued
    /// waypoint lines cannot play after Stop; `endRouteQuietly` (a route replaced mid-walk) and the
    /// Guide card's cancel-route-start button (`cancelRouteStart`) call it too. Also ends a pending pause, clears the resume state (Muse,
    /// Step 37: it used to leave that behind) and resets the load policy's calm window. Does not
    /// touch the voice hold, `routeLines` or a running prefetch.
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
    /// and the e2e harness run silently. Read once (a lazy static) from the process environment,
    /// never from settings, so a normal launch can never be silent. Readers: `speakNow` (simulated
    /// line length instead of audio) and `BeaconEngine.render` (beacon stays silent).
    static let muted: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["CANEKIT_MUTE"] == "1" || env["CANEKIT_UITEST"] == "1"
    }()

    // MARK: Backends

    /// Make `text` the current line and hand it to a backend. The caller must already have
    /// stopped (or never started) any previous line.
    ///
    /// Bumps `generation`, ends any pause, records the current line's priority / text / deadline /
    /// replay count / resume state (used by `requeueCurrent`), sets `isSpeaking` and `lastSpoken`,
    /// arms the watchdog on the remainder it will say, **decides the engine**
    /// (`VoiceEngineChoice.decide`, Step 53 — before `onDispatch`, so the dispatch timestamp
    /// `cue_audit.py` measures pauses from does not move), fires `onDispatch` with that decision,
    /// then acts on it:
    /// - `muted` → no sound; the line "ends" after its estimated spoken length;
    /// - `system` (`no_key`, `natural_off`, `warning_miss`, `breaker_open`) → system voice now; a
    ///   `warning_miss` / `breaker_open` line is also prefetched for next time (warnings never wait
    ///   for the network — AGENTS.md; while the breaker is open this is also the probe's payload);
    /// - `elevenlabs` (`cached`) → the mp3 plays at once, a warning too, breaker open or not;
    /// - `race` → `startRace`: fetch against `VoiceEngineChoice.raceDeadline` (2.5 s total).
    /// A result that arrives after the line was superseded (generation changed) is dropped.
    ///
    /// - Parameters:
    ///   - expires: absolute deadline (reference-date seconds) from `say` / `sayAgain` or carried
    ///     from the queue; `.infinity` only for `say(ttl: 0)`.
    ///   - replays: how many times this line has already been resumed after a cut.
    ///   - resumeFrom: UTF-16 offset of the clause to start from (0 = the whole line). The system
    ///     voice speaks `SpeechResume.remainder`; an mp3 seeks with `SpeechResume.clipTime`.
    ///   - lastResumeOffset: the queued line's `Pending.lastResumeOffset`, carried so a later cut
    ///     can never resume from an earlier point (`SpeechResume.nextResume`).
    private func speakNow(_ text: String, _ priority: SpeechPriority, expires: TimeInterval = .infinity,
                          replays: Int = 0, resumeFrom: Int = 0, lastResumeOffset: Int? = nil,
                          watchdogFallback: Bool = false) {
        generation += 1
        let gen = generation
        inGap = false
        currentPriority = priority
        currentText = text
        currentExpires = expires
        currentReplays = replays
        currentResumeFrom = resumeFrom
        currentLastResumeOffset = lastResumeOffset
        currentSpokenUTF16 = resumeFrom
        currentWordHeard = false
        watchdogFallbackUsed = watchdogFallback
        isSpeaking = true
        lastSpoken = text
        // What the system voice says: the remainder from the resume clause. An mp3 clip plays the
        // whole cached file from `clipStart` instead (one cache entry per line, never per fragment).
        let spokenText = SpeechResume.remainder(of: text, from: resumeFrom)
        armWatchdog(gen: gen, text: spokenText)

        // The cache is only looked at when it could matter (a `stat` on main, as before Step 53).
        let cachedURL = (!Self.muted && useNaturalVoice) ? naturalVoice?.cached(text) : nil
        // The safety watchdog's one retry (Step 51a) goes straight to the system voice: the first
        // attempt already stalled, so neither the cache nor a race may be trusted with it again.
        let decision = watchdogFallback
            ? VoiceEngineDecision(engine: .system, reason: .watchdogFallback)
            : VoiceEngineChoice.decide(muted: Self.muted, hasKey: naturalVoice != nil,
                                       naturalEnabled: useNaturalVoice, cached: cachedURL != nil,
                                       isWarning: priority == .obstacle || priority == .safety,
                                       breakerOpen: breaker.isOpen)
        lastEngine = decision
        onDispatch?(text, priority, replays, resumeFrom, decision)

        switch decision.engine {
        case .muted:
            // Automation mute (simulator tests, never on a normal launch): keep the queue's timing
            // and logging but make no sound — the line "ends" after its estimated spoken length.
            let seconds = 0.4 + Double(spokenText.count) / 15.0
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.lineEnded(gen: gen)
            }
        case .natural:
            if let cachedURL {
                playFile(cachedURL, gen: gen)
            } else {
                reportPlaybackFailure()          // dispatch said cached; the system voice spoke (Muse review)
                speakSystem(spokenText, gen: gen)
            }
        case .race:
            if let naturalVoice {
                startRace(text, spokenText: spokenText, gen: gen, voice: naturalVoice)
            } else {
                speakSystem(spokenText, gen: gen)
            }
        case .system:
            speakSystem(spokenText, gen: gen)
            // A warning that missed the cache (2.5 s of fetch is 3.5 m of walking into the obstacle)
            // or any miss while the breaker is open: natural voice cached for next time.
            if decision.reason == .warningMiss || decision.reason == .breakerOpen { prefetch([text]) }
        }
    }

    /// The cache-miss race (Step 53/54): fetch the line, but never wait more than
    /// `VoiceEngineChoice.raceDeadline` (2.5 s) in total — URLRequest's timeout is an *idle*
    /// timeout, so a slow trickle could stall the queue far longer (review). Whichever of the fetch
    /// and the deadline claims the line first wins (`voicePending`); the loser does nothing, so a
    /// line is never spoken twice (review round 5). Won → the mp3 plays; timed out or failed → the
    /// system voice speaks it, the breaker trips (`resolveRace`) and the line is queued for the
    /// background prefetch. Both tasks inherit the main actor; the URLSession await inside
    /// `ElevenLabsVoice.audio(for:)` suspends rather than blocks it.
    /// - Parameters:
    ///   - text: the whole line (cache key, log text).
    ///   - spokenText: its remainder from `currentResumeFrom`, for the system voice.
    ///   - gen: the line's generation; a superseded line's result is ignored.
    ///   - naturalVoice: the configured voice.
    private func startRace(_ text: String, spokenText: String, gen: Int, voice naturalVoice: ElevenLabsVoice) {
        voicePending = true
        let startedAt = Date().timeIntervalSinceReferenceDate
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(VoiceEngineChoice.raceDeadline))
            guard let self, self.voicePending, self.generation == gen, self.isSpeaking,
                  self.player == nil, self.currentUtterance == nil else { return }
            self.voicePending = false
            self.fetchTask?.cancel()
            self.resolveRace(text, .raceTimeout, since: startedAt)
            self.speakSystem(spokenText, gen: gen)
            self.prefetch([text])
        }
        fetchTask = Task { [weak self] in
            let result = await Result { try await naturalVoice.audio(for: text) }
            // Superseded meanwhile, or the deadline already switched to the system voice.
            guard let self, self.voicePending, self.generation == gen, self.isSpeaking,
                  self.currentUtterance == nil else { return }
            self.voicePending = false
            switch result {
            case .success(let url):
                self.resolveRace(text, .raceWon, since: startedAt)
                self.playFile(url, gen: gen)
            case .failure(let error):
                self.voiceError = error.localizedDescription
                self.resolveRace(text, .raceFailed, since: startedAt)
                self.speakSystem(spokenText, gen: gen)
                self.prefetch([text])
            }
        }
    }

    /// Record how a race ended: `lastEngine`, `onEngineResolved` (`speech_engine`) and, for a
    /// timeout or failure, `tripBreaker`. Caller: `startRace`'s two tasks.
    /// - Parameters:
    ///   - text: the whole line.
    ///   - outcome: `raceWon`, `raceTimeout` or `raceFailed`.
    ///   - startedAt: reference-date seconds the race started; `wait_ms` is measured from it.
    private func resolveRace(_ text: String, _ outcome: VoiceEngineReason, since startedAt: TimeInterval) {
        let waitMs = Int(((Date().timeIntervalSinceReferenceDate - startedAt) * 1000).rounded())
        lastEngine = VoiceEngineDecision(engine: VoiceEngineChoice.resolvedEngine(outcome), reason: outcome)
        onEngineResolved?(text, outcome, waitMs)
        switch outcome {
        case .raceTimeout: tripBreaker(.raceTimeout)
        case .raceFailed: tripBreaker(.raceFailed)
        default: break
        }
    }

    /// An mp3 (cached or just fetched) would not play; the system voice is re-speaking the remainder
    /// under the same generation. Logged as `speech_engine {engine_reason: playback_failed}` (Step 53);
    /// not a network failure, so the breaker is untouched. Caller: `playFile`'s two failure paths.
    private func reportPlaybackFailure() {
        lastEngine = VoiceEngineDecision(engine: .system, reason: .playbackFailed)
        onEngineResolved?(lastSpoken, .playbackFailed, 0)
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
    /// delegate callback will ever come) the line — its remainder from `currentResumeFrom` — is
    /// re-spoken by the system voice under the same generation, so the queue never sticks. A resumed
    /// line seeks the whole cached clip to its clause (`SpeechResume.clipTime`, 0.25 s early): one
    /// cache entry per line, never per fragment. Main actor.
    private func playFile(_ url: URL, gen: Int) {
        backendName = "ElevenLabs"
        // The natural voice just worked, so any earlier complaint is history. Without this a
        // launch with no signal would leave "timed out" on the card for the rest of the day, even
        // once every line was coming out in the ElevenLabs voice.
        voiceError = nil
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            let relay = PlayerRelay(
                onEnd: { [weak self] in
                    Task { @MainActor [weak self] in self?.lineEnded(gen: gen) }
                },
                onDecodeError: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.playFileDecodeFallback(message: message, gen: gen)
                    }
                }
            )
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
                reportPlaybackFailure()
                speakSystem(SpeechResume.remainder(of: lastSpoken, from: currentResumeFrom), gen: gen)
            }
        } catch {
            voiceError = "Playback: \(error.localizedDescription)"
            reportPlaybackFailure()
            speakSystem(SpeechResume.remainder(of: lastSpoken, from: currentResumeFrom), gen: gen)
        }
    }

    /// A cached file can open successfully and still fail once AVAudioPlayer decodes it. Keep the
    /// safety line alive by switching that line to the system voice under the same generation;
    /// stale decode callbacks cannot replace a newer line.
    private func playFileDecodeFallback(message: String?, gen: Int) {
        guard gen == generation, isSpeaking, player != nil else { return }
        player?.stop()
        player = nil
        playerRelay = nil
        voiceError = message.map { "Playback decode: \($0)" } ?? "Playback decode failed"
        // Invalidate a possible finish callback from the failed player before starting AVSpeech;
        // both delegate methods can be delivered for one failed AVAudioPlayer instance.
        generation += 1
        let fallbackGen = generation
        let remainder = SpeechResume.remainder(of: currentText, from: currentResumeFrom)
        speakSystem(remainder, gen: fallbackGen)
        armWatchdog(gen: fallbackGen, text: remainder)
    }

    /// Last-resort unstick: if no end callback arrives well after the line should be over
    /// (interruption edge cases, a stalled player), treat it as ended so the queue keeps moving.
    ///
    /// Limit = 6 s + (characters / 6) s, counting the characters actually to be spoken (the resumed
    /// remainder for a cut line) — ≈ a slow speaking rate plus fetch headroom. The timer
    /// also covers a slow ElevenLabs fetch, since it is armed before the backend is chosen.
    /// A watchdog end is a natural end for `onLineEnd` (the priority is still current).
    /// Fires only if the same generation is still speaking. Safety gets one immediate system-voice
    /// fallback; lower-priority lines retain the old queue-unblocking behavior. A second failure is
    /// ended so a permanently stalled backend cannot loop forever. The task inherits the main actor.
    /// Called from `speakNow` only.
    private func armWatchdog(gen: Int, text: String) {
        watchdog?.cancel()
        let limit = 6.0 + Double(text.count) / 6.0          // ~25 s for a long crossing line
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard let self, !Task.isCancelled, self.generation == gen, self.isSpeaking else { return }
            self.voiceError = "Speech watchdog reset"
            let priority = self.currentPriority
            let wholeText = self.currentText
            let expires = self.currentExpires
            let replays = self.currentReplays
            let resumeFrom = self.currentResumeFrom
            let lastResumeOffset = self.currentLastResumeOffset
            let useSafetyFallback = priority == .safety && !self.watchdogFallbackUsed && !wholeText.isEmpty
            self.stopCurrent()                              // bumps generation: in-flight work stays stale
            if useSafetyFallback, let priority {
                self.speakNow(wholeText, priority, expires: expires, replays: replays,
                              resumeFrom: resumeFrom,
                              lastResumeOffset: lastResumeOffset, watchdogFallback: true)
            } else {
                self.lineEnded(gen: self.generation)
            }
        }
    }

    /// Silence whatever is playing and invalidate every in-flight callback for it: cancels the
    /// watchdog and any ElevenLabs fetch, stops the player and the synthesizer (at a word
    /// boundary), forgets `currentUtterance`, and bumps `generation`. The stop calls return
    /// before their delegate callbacks fire; those late callbacks are ignored by the generation /
    /// utterance-identity checks. Also ends a pending pause (`inGap = false`). Does *not* touch
    /// `isSpeaking`, `currentPriority` or the queue — callers either start a new line right after or
    /// reset those themselves. ⚠ Read mp3 progress (`requeueCurrent`) *before* calling this: it drops
    /// the player. A `.word` stop finishes the word being said, which `requeueCurrent` relies on.
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

    /// The system voice is about to say the word at `location` (UTF-16, within the utterance's own
    /// string — the remainder for a resumed line, hence `currentResumeFrom +`). Recorded as progress
    /// through the whole line for `requeueCurrent`; ignored for any utterance that is no longer
    /// current (a late callback from a cut line). Delivered by the `DelegateRelay` → `CallbackBox.onWord`
    /// hop, so a cut can land before the latest word's hop: the resume then starts a clause early,
    /// never late (Step 37).
    private func utteranceWillSpeak(_ id: ObjectIdentifier, location: Int) {
        guard let currentUtterance, ObjectIdentifier(currentUtterance) == id else { return }
        currentSpokenUTF16 = currentResumeFrom + location
        currentWordHeard = true
    }

    /// System-voice completion (finish *or* cancel), delivered on main by the relay hop.
    /// Ignored unless `id` is the utterance we still consider current — a `didCancel` from a
    /// line that `stopCurrent` already replaced arrives late and must not end its successor.
    /// Then ends the line with the *current* generation (the utterance identity already proved it
    /// is ours).
    private func utteranceEnded(_ id: ObjectIdentifier) {
        guard let currentUtterance, ObjectIdentifier(currentUtterance) == id else { return }
        self.currentUtterance = nil
        lineEnded(gen: generation)
    }

    /// The current line finished (or was declared finished): advance the queue.
    ///
    /// Stale calls (`gen != generation`) are ignored. Otherwise fires `onLineEnd` with the ended
    /// line's priority (when one was current), clears the current-line and resume state, and hands
    /// over to `startNext(after:)`, which purges expired queued lines (TTL) and either starts the head
    /// of the queue — after the 0.35 s cross-band pause when it is a different band — or, if the
    /// queue is empty, a call/Siri interruption is active, or the voice hold is on, sets
    /// `isSpeaking = false`. Callers: `utteranceEnded`, the muted-line timer,
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
    ///   (draining after a call or a voice hold, and the pause task's own second call).
    /// The head is started with its deadline, replay count and resume state
    /// (`resumeFrom` / `lastResumeOffset`), so a resumed line keeps its loop guard.
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
                 resumeFrom: next.resumeFrom,
                 lastResumeOffset: next.lastResumeOffset)
    }

    /// Prefer an enhanced/premium en-US voice when one is installed; fall back to the default.
    /// Evaluated once in `init`; premium/enhanced voices exist only if the user downloaded them
    /// in Settings › Accessibility › Spoken Content. A voice downloaded while the app runs is used
    /// from the next launch.
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

/// Holds the end-of-utterance and word-progress callbacks. Written once during
/// `SpeechQueue.init` (after `synthesizer.delegate` is set, before any utterance is spoken), then
/// only read.
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
    /// Where the callbacks are forwarded; immutable reference, its closures set once in `init`.
    private let box: CallbackBox
    /// - Parameter box: the shared box `SpeechQueue.init` fills in right after building this relay.
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
    /// Ends this relay's line: `SpeechQueue.playFile`'s closure, which captured that line's
    /// generation and hops to the main actor. Immutable, so sharing it across threads is safe.
    private let onEnd: @Sendable () -> Void
    /// Called when a cached clip cannot be decoded; the current line must use AVSpeech instead.
    private let onDecodeError: @Sendable (String?) -> Void
    /// - Parameter onEnd: called on an AVFoundation thread when the clip finishes or fails to decode.
    init(onEnd: @escaping @Sendable () -> Void,
         onDecodeError: @escaping @Sendable (String?) -> Void) {
        self.onEnd = onEnd
        self.onDecodeError = onDecodeError
    }

    /// Playback reached the end (successfully or not) → the line is over.
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if flag { onEnd() } else { onDecodeError(nil) }
    }
    /// A corrupt cached mp3 → fall back to the system voice for this line.
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onDecodeError(error?.localizedDescription)
    }
}

/// Async counterpart of `Result(catching:)`, so `speakNow` can await the ElevenLabs fetch and
/// then switch on success / failure in one place.
private extension Result where Failure == Error {
    /// Awaits `body` on the caller's executor; a thrown error (including cancellation) becomes
    /// `.failure`, which `speakNow` treats as a natural-voice failure only if the line is still ours.
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
