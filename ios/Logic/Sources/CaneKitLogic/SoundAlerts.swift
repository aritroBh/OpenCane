//
//  SoundAlerts.swift
//  CaneKitLogic
//
//  Which sounds a blind pedestrian needs to be told about, and how often.
//
//  Purpose: the phone's microphone hears traffic the LiDAR cannot see — a siren two blocks away, a
//  horn behind the walker, a car pulling out of a driveway. `SoundWatcher` (app target) runs
//  Apple's built-in `SNClassifySoundRequest(classifierIdentifier: .version1)` over the mic and
//  hands every (label, confidence) pair here; everything with a number in it — the confidence
//  gates, how many consecutive analysis windows must agree, and how long before the same sound is
//  announced again — lives in this file with tests (AGENTS.md hard rule 3).
//
//  Label identifiers: Apple documents "hundreds of sounds" for the built-in classifier but
//  publishes **no list of the label strings**, and the documented way to get them is
//  `SNClassifySoundRequest.knownClassifications` ("every prediction label in the request's
//  underlying sound classifier model"). So `candidateLabels` below is *not* a guess that ships:
//  `SoundWatcher` intersects it with `knownClassifications` at start-up, logs the matches and the
//  misses (`sound_watch_labels`), and only ever matches identifiers this phone actually has. The
//  `probe_f_sound_labels` record written by `SensorProbe` is the same measurement taken by hand.
//
//  ─────────────────────────────────────────────────────────────────────────────────────────────
//  WHY AN EMERGENCY SIREN IS NOT "ONE MORE TRAFFIC SOUND" (the research behind every number here)
//  ─────────────────────────────────────────────────────────────────────────────────────────────
//  R1. What a blind pedestrian actually does with a siren. A blind traveller crosses by listening
//      to the traffic: O&M teaches judging the crossable gap from the parallel traffic surge, and
//      the whole method rests on being able to *hear approaching vehicles with enough warning
//      time* (ACB, "Crossing Where There Is No Traffic Control"; NADTC, "Can I Cross the Street?").
//      The same two sources name the failure mode: **masking**. "Sounds from airplanes or receding
//      vehicles can mask the sounds of approaching vehicles, so when there is too much traffic or
//      environmental noise … blind people will be unable to know when there is a crossable gap"
//      (NADTC). A siren is the loudest masker a street produces. So the fact worth speaking is not
//      "there is a siren" — the walker's ears already have that — it is **"the cue you cross by is
//      unreliable right now."** The action that follows is a crossing decision, which is why the
//      line is an instruction and why it is spoken in the band route and crossing lines use.
//  R2. Why the sentence says "do not START crossing" and never "stop". Pedestrian guidance for an
//      approaching emergency vehicle is asymmetric: do not step into the crosswalk, but if you are
//      already in the intersection, clear it — "step to a safe spot on the curb or island and do
//      not stop in the middle of the intersection" (Roanoke VA, "What to Do When an Emergency
//      Vehicle Approaches"; the California and NY driver handbooks say the same for vehicles).
//      The app cannot tell which of the two the walker is doing — the microphone knows nothing
//      about the curb — so the line must be **correct in both cases**. "Do not start crossing" is
//      a no-op for someone already in the road and the right instruction for someone at the curb.
//      A bare "Stop." or "Do not cross." would be actively dangerous for the first walker, and a
//      false one of those is exactly the freeze-in-a-crossing this feature must never cause.
//  R3. Why direction is not spoken. Estimating direction of arrival needs an array: "estimating
//      the DOA of acoustic sources conventionally requires a microphone array consisting of at
//      least two microphones", and single-microphone methods need a known scattering body or a
//      moving microphone with a known trajectory (Frontiers in Signal Processing, 2024). The
//      published siren-localisation work is stereo — the 7.5° median error in "Listening for
//      Sirens" (arXiv:1810.04989) comes from two boom microphones on a car roof. This app gets one
//      mono stream through `SNAudioStreamAnalyzer`, from a phone strapped to a cane that is being
//      swung. There is no honest direction here, so none is claimed.
//  R4. Why the classifier is not trusted the way the old gates trusted it. Apple ships this same
//      model as the Sound Recognition accessibility feature and says of it: "Don't rely on your
//      iPhone to recognize sounds in circumstances where you may be harmed or injured, in
//      high-risk or emergency situations, or for navigation" (Apple Support, "Recognize sounds
//      using iPhone"). Apple's own documented failure mode for this class is a false positive —
//      early versions "confused whistling for police sirens". Published siren detectors report
//      94 % classification on curated stereo city audio (arXiv:1810.04989) and ~86 % AuPRC on
//      unfiltered real audio, and the recurring note in that literature is that false positives
//      under real-world noise stay a problem. On a university campus the confusable set is large
//      and constant: bicycle bells, fire-alarm tests, amplified music, brass practice, scooters.
//  R5. The trade that reverses the old comment. The previous version of this file said "a siren is
//      cheaper to get wrong than to miss", and gated it lowest. That was right while the line was
//      the passive "Siren nearby." It is wrong now. Missing a siren leaves the walker exactly
//      where they were — using the hearing that is their primary instrument and that hears a
//      pedestrian-audible siren far further than this phone's bottom microphone will. Getting one
//      wrong now stops a blind person at a kerb for no reason, in the band route instructions use,
//      and spends the trust the whole app runs on. False positives are treated here as a safety
//      defect, not an annoyance. Hence: the siren gate went UP (0.50 → 0.60) and the siren alone
//      needs THREE agreeing windows instead of two.
//
//  Key invariants:
//    · Emergency sirens are `.emergency` urgency and everything else is `.ambient`. The app maps
//      `.emergency` to the `.nav` speech band — the same band as crossing instructions, because it
//      *is* a crossing instruction — and `.ambient` to `.obstacle`, unchanged.
//    · Nothing reaches `.safety`. `.safety` is reserved for imminent physical danger the walker
//      cannot perceive ("Head height.", LiDAR drop-offs), and equal priorities queue FIFO in
//      `SpeechQueue`, so a siren line at `.safety` would *delay* a head-height warning by its own
//      length. That is forbidden outright. See the file header of SoundWatcher for the full
//      argument (AGENTS.md hard rule 8, docs/design.md §5.1).
//    · Nothing is announced on a single window, and an emergency needs three (R4, R5): at the
//      app's ~0.5 s window hop that is 1.5 s of continuous siren before anyone is told. 1.5 s is
//      nothing against an emergency vehicle audible for tens of seconds, and it is the cheapest
//      defence there is against a one-off confusable.
//    · An emergency candidate is never shadowed by an ambient one (`best(of:)`). On a street
//      `traffic_noise` and `engine` sit high in every window, so picking the window's
//      highest-confidence danger label would let the ambient class win window after window and
//      break the siren's agreement run before it ever completed.
//    · The same kind is not repeated inside `repeatInterval`, so standing at a busy corner does
//      not turn into a stream of speech over the route instructions.
//
//  Owners / callers: `SoundWatcher` (app, `ios/CaneKit/Audio/`, main actor) owns one
//  `SoundAlertPolicy`, filters `SoundAlerts.labels` against `knownClassifications`, picks each
//  window's candidate with `SoundAlerts.best(of:)` and calls `onAlert`; `AppModel.wireSounds()`
//  speaks `spokenLine` at `.nav` / `.obstacle` with `speechTTL`. `SensorProbe` reads
//  `candidateLabels`. `MicrophoneStart` is shared by `SoundWatcher` and `VoiceInputEngine`
//  (push-to-talk) for the input-format settle. The feature ("Listen for sirens and horns") is off
//  by default; its session lifetime rules are `SoundRecognitionGuard`.
//  Isolation: everything here is a nonisolated value or a stateless enum; `SoundAlertPolicy` is
//  held in one main-actor `var` by `SoundWatcher`.
//  Tests: SoundAlertsTests.swift (38, including the six `SoundRecognitionGuard` scenarios).
//

import Foundation

/// How urgent a danger sound is, which is what decides the speech band it is spoken in.
///
/// Two levels, not three, because the app's speech ladder already has the two bands that mean the
/// right things: `.nav` ("what you must do at this corner") and `.obstacle` ("something is near
/// you"). This enum is the logic-side name for that choice, so the number-free mapping lives in
/// `AppModel.wireSounds()` and the *decision* lives here with its tests (AGENTS.md hard rule 3).
/// ⚠ Nothing here maps to `.safety`, ever. See the file header, invariant 2.
public enum SoundUrgency: Int, Sendable, Comparable, CaseIterable {
    /// Something is audible near the walker that the cane will not find. Spoken at `.obstacle`.
    case ambient = 0
    /// An emergency vehicle is working nearby: the walker's own crossing cue is masked and the
    /// vehicle may cross against the signal. Spoken at `.nav`, the crossing-instruction band.
    case emergency = 1
    /// Orders by raw value so `urgency > .ambient` reads naturally.
    public static func < (a: SoundUrgency, b: SoundUrgency) -> Bool { a.rawValue < b.rawValue }
}

/// A danger sound worth speaking, and the line spoken for it.
/// Deliberately only three kinds: a blind walker acting on a sound needs to know *what* to do
/// (stop, check behind, wait), and a finer taxonomy ("ambulance" vs "police car") changes nothing.
public enum DangerSound: String, Sendable, CaseIterable {
    /// Emergency vehicle sirens, civil-defence sirens, alarms of that shape.
    case siren
    /// Car / truck / air / train horns — someone is warning *somebody*, possibly the walker.
    case horn
    /// Engines, tyres, a vehicle passing: something is moving nearby that the cane will not find.
    case vehicle

    /// What the walker hears.
    ///
    /// The siren line is the only one that tells the walker to do something, and the wording is
    /// load-bearing (file header R1, R2):
    ///   · It names an **action**, because "Siren nearby." is not actionable — a blind traveller
    ///     already hears the siren, and what the app adds is that their crossing cue is now masked.
    ///   · It governs **starting**, not stopping. Someone already in the crosswalk must clear it,
    ///     not freeze; "Do not start crossing." is a no-op for them and the right instruction for
    ///     someone at the kerb. Never reword this to "Stop." or "Do not cross."
    ///   · It stays short. `.nav` and `.obstacle` queue FIFO, so every syllable here delays the
    ///     next obstacle name: 29 characters ≈ 1.5 s, shorter than any route line in the app.
    /// The other two lines are unchanged and deliberately passive: a horn or an engine is a fact,
    /// not an instruction, and the classifier is nowhere near sure enough to direct anyone on them.
    /// ⚠ These strings are prefetched by the natural voice (`AppModel.commonLines`); changing one
    /// without changing that list costs a synthesis round-trip on the first play.
    /// Pinned by `spokenLinesAreThePrefetchedOnes`, `theSirenLineGovernsStartingToCrossAndNeverSaysStop`.
    public var spokenLine: String {
        switch self {
        case .siren: return "Siren. Do not start crossing."
        case .horn: return "Horn nearby."
        case .vehicle: return "Vehicle sound nearby."
        }
    }

    /// Which speech band the app speaks this kind in (`AppModel.wireSounds()` does the mapping).
    ///
    /// Only an emergency siren is `.emergency`, and it is `.emergency` because of what the walker
    /// must decide, not because of how loud it is: an emergency vehicle masks the traffic sound a
    /// blind traveller crosses by, and it may enter the intersection against the signal. That is a
    /// crossing fact, and crossing facts are `.nav` in this app.
    public var urgency: SoundUrgency {
        switch self {
        case .siren: return .emergency
        case .horn, .vehicle: return .ambient
        }
    }

    /// Confidence (0…1) this kind needs before it is even a candidate.
    ///
    /// The siren gate was **raised** from 0.50 to 0.60 when its line became an instruction spoken
    /// in the route band (file header R5). Missing a siren costs the walker nothing they did not
    /// already have — their own ears hear a pedestrian-audible siren much further than a phone
    /// microphone strapped to a swinging cane — while a false one stops a blind person at a kerb.
    /// Apple says outright not to rely on this classifier "in high-risk or emergency situations,
    /// or for navigation" (R4), so the app buys margin where it is cheap.
    /// A generic vehicle sound is still the commonest false positive on a sidewalk and is gated
    /// highest. ⚠ Do not lower the siren gate without a street test that counts false alarms.
    public var minimumConfidence: Double {
        switch self {
        case .siren: return 0.60
        case .horn: return 0.60
        case .vehicle: return 0.75
        }
    }

    /// Consecutive analysis windows that must name this kind above its gate before it is spoken.
    ///
    /// Three for a siren, two for everything else, at the app's ~0.5 s window hop:
    ///   · A siren is continuous for tens of seconds, so 1.5 s of confirmation costs the walker
    ///     nothing real and is the cheapest defence against a one-off confusable (a bell, an alarm
    ///     test, a note held on a brass instrument — R4). It also means the *momentary* things
    ///     that get classified as sirens cannot reach speech at all.
    ///   · A horn is the opposite shape: a honk is often under a second, so a third window would
    ///     not make it more certain, it would simply mean horns are never announced.
    /// ⚠ Raising the siren count further pushes the alert past the point where it can still change
    /// a crossing decision; lowering it re-admits the single-burst false positives.
    public var requiredWindows: Int {
        switch self {
        case .siren: return 3
        case .horn, .vehicle: return 2
        }
    }

    /// Seconds before this kind may be spoken again. A siren approaches, so it is worth a
    /// reminder sooner; standing next to traffic must not produce a running commentary.
    /// 15 s of an emergency vehicle's approach is ≈ 200 m at 50 km/h, so a siren that is still
    /// audible one interval later is meaningfully closer than it was — the repeat carries
    /// information, it is not nagging.
    public var repeatInterval: Double {
        switch self {
        case .siren: return 15
        case .horn: return 12
        case .vehicle: return 30
        }
    }

    /// Seconds the line may sit in the speech queue before it is dropped as stale
    /// (`SpeechQueue.say(_:_:ttl:)`).
    ///
    /// The siren gets its full repeat interval (15 s), not the 5 s first written here. 5 s assumed
    /// a siren queues behind "at most the route line already playing" — wrong: at `.nav` it queues
    /// behind ANY `.nav` line already playing or queued (crossing instructions run 4–8 s, the
    /// screen-lock warning 10 s, location-denied 20 s), and `SpeechQueue` purges expired lines when
    /// a line ends. A 5 s siren arriving mid-crossing-instruction expired unheard: the walker was
    /// told to cross and never told about the siren. 15 s survives every `.nav` line but the 20 s
    /// location-denied edge, and it cannot go stale past usefulness: an emergency vehicle is
    /// audible for tens of seconds, so a line up to one interval old is at most one reminder early,
    /// never news about a gone vehicle — the next interval re-announces anyway. A late hold at a
    /// kerb is a false restriction, bounded and self-correcting; a dropped siren is a missed
    /// crossing decision. Horn keeps 4 s (a honk is momentary; a longer TTL would announce it after
    /// it passed) and vehicle 6 s.
    public var speechTTL: Double {
        switch self {
        case .siren: return 15
        case .horn: return 4
        case .vehicle: return 6
        }
    }

    /// Rank used when one analysis window offers more than one danger label (`SoundAlerts.best`).
    /// Higher wins regardless of confidence, as long as it clears its own gate: siren > horn >
    /// vehicle. This is the anti-shadowing rule — see `best(of:)`.
    public var selectionRank: Int {
        switch self {
        case .siren: return 2
        case .horn: return 1
        case .vehicle: return 0
        }
    }
}

/// The label table and the gates shared by `SoundWatcher` and `SensorProbe`.
public enum SoundAlerts {

    /// Candidate label identifiers for each kind, in the snake_case style Apple's built-in
    /// classifier uses. This is a *superset* on purpose: `SoundWatcher` keeps only the entries
    /// that appear in `SNClassifySoundRequest.knownClassifications` on the running phone and logs
    /// the rest, so a label that does not exist in this iOS version costs nothing and is visible
    /// in the trip log rather than silently never firing.
    /// ⚠ Never match a label that is not in `knownClassifications`: that is how a feature ends up
    /// looking enabled while being dead.
    ///
    /// Two identifiers were **removed** when the siren line became an instruction, and both
    /// removals are load-bearing rather than tidying:
    ///   · `car_alarm` was in the siren set. A parked car's alarm is not an emergency vehicle and
    ///     is not a reason to hold at a kerb; it is also a common campus and car-park sound. It
    ///     happens not to exist in `knownClassifications` on the demo phone, so removing it costs
    ///     nothing today — and stops a future iOS that adds the label from silently wiring a car
    ///     alarm to "Siren. Do not start crossing." (pinned by `carAlarmIsNotASiren`).
    ///   · `bicycle_bell` was in the horn set, and it *does* exist on the demo phone. On a
    ///     university campus a bicycle bell is one of the most frequent sounds there is, and it
    ///     would have been announced as "Horn nearby.", which is both wrong and constant. A
    ///     campus bell deserves its own cue one day; it does not deserve the horn's words.
    /// `civil_defense_siren` deliberately stays: an outdoor warning siren is not an emergency
    /// vehicle, but "do not start crossing" is not wrong advice under one either, and in Champaign
    /// it sounds on a published monthly test rather than at random. Do not treat a first-Tuesday
    /// alert as a bug — see the risk list in CHANGELOG.
    public static let labels: [DangerSound: [String]] = [
        .siren: ["siren", "emergency_vehicle", "police_siren", "ambulance_siren",
                 "fire_engine_siren", "civil_defense_siren", "emergency_vehicle_siren"],
        .horn: ["car_horn", "vehicle_horn", "vehicle_horn_car_horn_honking", "air_horn",
                "train_horn", "honk", "truck_horn"],
        .vehicle: ["vehicle", "motor_vehicle_road", "car_passing_by", "traffic_noise",
                   "engine", "engine_accelerating", "engine_idling", "engine_revving",
                   "bus", "truck", "motorcycle", "tire_squeal", "skidding", "car"],
    ]

    /// Every candidate identifier, sorted — what `SensorProbe` checks against the phone and what
    /// `SoundWatcher` filters at start-up. No identifier is in two kinds
    /// (`candidateLabelsAreTheWholeTableWithoutDuplicates`).
    public static var candidateLabels: [String] {
        labels.values.flatMap { $0 }.sorted()
    }

    /// The kind a label belongs to, or nil when the label is not a danger sound.
    /// Exact, case-sensitive match against `labels` (Apple's identifiers are lower snake_case).
    /// Pinned by `measuredLabelsMapToTheRightKind`, `everydaySoundsAreNotDangerSounds`.
    /// - Parameter label: an identifier from `SNClassificationResult.classifications`.
    public static func kind(for label: String) -> DangerSound? {
        for (kind, names) in labels where names.contains(label) { return kind }
        return nil
    }

    /// Pick the one candidate from a single classification window that the policy should judge.
    ///
    /// **The bug this exists to stop.** `SNClassificationResult` carries every label with a
    /// confidence, and the old code forwarded whichever *danger* label had the highest confidence.
    /// On a real street that is almost always the ambient class: `traffic_noise`, `engine` and
    /// `car_passing_by` sit high in every single window next to a road. An approaching siren rises
    /// through that, so window after window would report `vehicle` while `siren` was second — and
    /// because `SoundAlertPolicy` requires *consecutive agreeing* windows, the siren's run would be
    /// broken by the ambient class every time and the alert would simply never fire. The one
    /// hazard the cane and the LiDAR can never detect must not be shadowed by the one class that is
    /// always present.
    ///
    /// So: among the candidates that clear their own `minimumConfidence`, the highest
    /// `selectionRank` wins (siren > horn > vehicle), ties broken by confidence. If nothing clears
    /// a gate, the highest-confidence danger label is returned unchanged — the policy still needs
    /// to see a sub-gate window so it can break the run, which is exactly what it did before.
    /// - Parameter candidates: `(identifier, confidence)` for this window. Identifiers that are not
    ///   danger sounds are ignored, so callers may pass the whole window.
    /// - Returns: the label and confidence to hand to `SoundAlertPolicy`, or nil when the window
    ///   held no danger sound at all.
    public static func best(of candidates: [(label: String, confidence: Double)])
        -> (label: String, confidence: Double)? {
        var qualified: (label: String, confidence: Double, rank: Int)?
        var fallback: (label: String, confidence: Double)?
        for c in candidates {
            // A non-finite confidence is dropped outright. NaN compares false against everything,
            // so a NaN that arrived first would sit in `fallback` and never be displaced by a real
            // candidate — it would win by being unrankable.
            guard let kind = kind(for: c.label), c.confidence.isFinite else { continue }
            if let f = fallback {
                if c.confidence > f.confidence { fallback = (c.label, c.confidence) }
            } else {
                fallback = (c.label, c.confidence)
            }
            guard c.confidence >= kind.minimumConfidence else { continue }
            let rank = kind.selectionRank
            // Rank first, confidence only as the tie-break. Spelled out rather than compared as a
            // tuple so the ordering is impossible to misread at a glance.
            if let q = qualified, q.rank > rank || (q.rank == rank && q.confidence >= c.confidence) {
                continue
            }
            qualified = (c.label, c.confidence, rank)
        }
        if let q = qualified { return (q.label, q.confidence) }
        return fallback
    }
}

/// Turns a stream of classifier results into at most one spoken line per danger kind per
/// `repeatInterval`, requiring agreement across consecutive analysis windows.
///
/// A value type with no clock of its own (like `StraightWalkDetector` and `GroundHazardPolicy`):
/// the owner passes `now` in seconds and writes the mutated copy back.
public struct SoundAlertPolicy: Sendable, Equatable {

    // Design note (not a property — kept where the old one was): how many consecutive agreeing
    // windows each kind needs is `DangerSound`'s own number (`requiredWindows`), not the policy's,
    // because the right answer differs by the *shape* of the sound: a siren is continuous and can
    // afford a third window, a honk is not and cannot.
    //
    // This used to be one policy-wide `var requiredWindows = 2`. It was made per kind when the
    // siren line became an instruction spoken in the route band: the extra 0.5 s of confirmation
    // is the cheapest false-positive defence available, and it may not be charged to horns.
    // ⚠ Pinned by `sirenNeedsThreeWindowsAndHornStillNeedsTwo`.

    /// The kind the current run of windows agrees on; nil after a window that broke the run.
    private var pending: DangerSound?
    /// How many consecutive windows (including this one) have agreed on `pending`. Not reset when
    /// a line is announced, so a siren that stays audible is held by `repeatInterval`, not re-armed.
    private var pendingCount = 0
    /// When each kind was last announced (seconds), so `repeatInterval` is per kind.
    private var lastSpoken: [DangerSound: Double] = [:]

    /// Creates an empty policy: no run in progress and no kind inside its repeat interval.
    public init() {}

    /// Feed one classification window's best danger-sound candidate.
    ///
    /// The caller passes the window's chosen candidate — `SoundAlerts.best(of:)` makes that choice
    /// so an ambient label cannot shadow a siren. A window with no danger sound passes `nil`,
    /// which breaks the run. Confidence below the kind's own gate also breaks it: a half-heard
    /// siren is not a siren.
    /// - Parameters:
    ///   - kind: the danger sound this window suggests, or nil.
    ///   - confidence: 0…1 from `SNClassification.confidence`.
    ///   - now: monotonic seconds.
    /// - Returns: the kind to announce, or nil. Returns non-nil at most once per
    ///   `kind.repeatInterval`, and only after `kind.requiredWindows` agreeing windows.
    public mutating func update(kind: DangerSound?, confidence: Double, now: Double) -> DangerSound? {
        guard let kind, confidence >= kind.minimumConfidence else {
            pending = nil
            pendingCount = 0
            return nil
        }
        if pending == kind {
            pendingCount += 1
        } else {
            pending = kind
            pendingCount = 1
        }
        guard pendingCount >= kind.requiredWindows else { return nil }
        if let last = lastSpoken[kind], now - last < kind.repeatInterval { return nil }
        lastSpoken[kind] = now
        // Keep the run going: a siren that stays audible must not re-announce until the interval
        // is up, and resetting here would let it re-arm on the very next window.
        return kind
    }

    /// Forget the run and every repeat timer, so a new listening session never inherits the last
    /// one's silence window. `SoundWatcher` calls it when the analyser starts and in its stop path
    /// (switch off, background, failure) — not at route start or stop. Pinned by
    /// `resetClearsTheRunAndTheTimers`.
    public mutating func reset() {
        pending = nil
        pendingCount = 0
        lastSpoken.removeAll()
    }
}

/// When the microphone's input format may be trusted, and how long to wait for it if it is not.
///
/// Why this exists: `SoundWatcher` asks `AVAudioEngine.inputNode` for its format immediately after
/// the audio session is moved to `.playAndRecord`. iOS settles a route change **asynchronously**,
/// so on the first-ever enable — especially with AirPods, where the input has to be negotiated —
/// that read can come back as 0 Hz / 0 channels for a few hundred milliseconds. The old code
/// failed on that first read and told the walker "No microphone input available", which was not
/// true a quarter of a second later. Installing a tap with such a format is not an option either:
/// `AVAudioEngine` traps on an invalid format, so the check itself must stay.
///
/// The numbers live here (AGENTS.md hard rule 3) and are pinned by `SoundAlertsTests`
/// (`onlyAFullySettledInputFormatIsUsable`, `theInputFormatIsRetriedExactlyOnce`,
/// `theRetryLoopReadsTheFormatExactlyFormatAttemptsTimes`, `theWholeRetryBudgetStaysUnderHalfASecond`).
/// Callers: `SoundWatcher` (sound alerts) and `VoiceInputEngine.startEngine` (push-to-talk), which
/// hit the same first-read race when they move the session to `.playAndRecord`.
/// They are deliberately tiny: this is a settling delay, not a retry loop around a broken
/// microphone. A genuinely refused or missing input still fails, just ~0.25 s later.
public enum MicrophoneStart {

    /// How many times the input format is read in total before giving up (the first read plus
    /// `formatAttempts - 1` retries). Two: one read that catches the common case at no cost, and
    /// one retry after the route has settled. A third would push a real failure past half a
    /// second of the walker waiting for a switch to do something.
    public static let formatAttempts = 2

    /// Seconds to wait before re-reading the input format. 0.25 s covers the ~0.1–0.2 s iOS takes
    /// to publish a new route (measured for the route-change notification on this phone) with
    /// margin, and is short enough that a flipped switch still feels immediate.
    public static let formatRetryDelay: Double = 0.25

    /// Whether an `AVAudioFormat` read off the input node can be used to install a tap.
    ///
    /// Both halves matter: a stale format reports `sampleRate == 0`, and a session that has an
    /// input route but no channels yet reports `channelCount == 0`. Either one crashes
    /// `installTap(onBus:bufferSize:format:)`.
    /// - Parameters:
    ///   - sampleRate: `AVAudioFormat.sampleRate`.
    ///   - channels: `AVAudioFormat.channelCount`.
    public static func isUsableInputFormat(sampleRate: Double, channels: UInt32) -> Bool {
        sampleRate > 0 && channels > 0
    }

    /// How long to wait before the next read, or nil when the attempts are used up and the start
    /// should fail.
    /// - Parameter attempt: the zero-based attempt that just failed (0 = the first read).
    public static func retryDelay(afterAttempt attempt: Int) -> Double? {
        guard attempt >= 0, attempt + 1 < formatAttempts else { return nil }
        return formatRetryDelay
    }
}
