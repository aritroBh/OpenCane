//
//  SpokenPhrases.swift
//  CaneKitLogic
//
//  Every warning line the app can build from a template, enumerated.
//
//  Why this file exists (the bug it fixes): `SpeechQueue` deliberately never lets a warning wait
//  for the network — an `.obstacle` or `.safety` line that misses the mp3 cache is spoken by
//  `AVSpeechSynthesizer` *now* and the natural voice is only fetched for next time. Nav lines,
//  which are prefetched per route, almost always hit the cache. The walker therefore heard the
//  route in the ElevenLabs voice and the warnings in Apple's system voice, line after line
//  ("its switching back and forth", user report, demo −1 day). The safety rule is right; the
//  cache was simply cold. So: the warning phrase space is finite and small, because every warning
//  line is `noun + bucketed distance` and the buckets are half-metre steps inside a few metres.
//  Enumerate it here, prefetch all of it at launch, and every warning comes out of the cache in
//  the natural voice with no network wait at all.
//
//  Key invariants:
//    · Byte-identical by construction, not by copying. The line templates live *here*
//      (`obstacleLine`, `approachLine`) and production code calls them: `ObstacleNamer` (app) and
//      `CueSpeechPolicy` (NavSupport.swift) build their lines with these functions, and the ground
//      hazard lines come from `GroundHazard.spokenLine` itself. A hand-typed copy of a spoken
//      string would drift by one byte and miss the cache silently, which is the whole failure mode
//      (see AppModel's ⚠ on `commonLines`).
//    · The reachable *range* is derived too: `ObstacleNamer`'s two distance limits are the
//      constants below, the approach range comes from `CueThresholds`, and the ground-hazard
//      distances come from `GroundHazardDetector.Config` bin geometry. Widen any of those and the
//      enumeration widens with it.
//    · Pure and cheap: no state, no I/O, a few hundred `SpokenDistance.phrase` calls. Safe to
//      evaluate on a background task at launch.
//    · Cost is a hard constraint, not a detail: every line here is one ElevenLabs synthesis on a
//      10,000-character-per-month free tier, so `warningCharacterBudget` pins the total and
//      `spokenPhrasesStayInsideTheCharacterBudget` fails the build if it grows past it. Each line
//      is cached on disk forever after its first synthesis, so the spend is one-time.
//
//  Tests: SpokenPhrasesTests.swift — completeness is proven by sweeping the *production*
//  functions over the production ranges and asserting every result is a member of these sets.
//

import Foundation

/// The complete set of spoken warning lines the app can generate from a template, plus the line
/// templates themselves.
///
/// Used by `SpeechQueue.prefetch` (through `AppModel`) to warm the natural-voice cache at launch so
/// that warnings — which must never wait for the network — still come out in the natural voice.
/// Everything here is a pure function of the logic package's own tuning constants.
public enum SpokenPhrases {

    // MARK: Distance limits (the reachable range of each warning kind)

    /// How far ahead a classified mesh face is still named ("table ahead, two meters"), metres.
    /// The default of `ObstacleNamer.maxDistance` (the app) lives here so the enumeration below
    /// covers exactly the distances the namer can speak — AGENTS.md hard rule 3 (a number with a
    /// metre on it belongs in CaneKitLogic with a test).
    /// 3 m because ARKit mesh classification is unreliable further out and in sunlight.
    public static let obstacleMaxDistance: Float = 3.0

    /// Same, for walls, metres. Walls are everywhere, so they are only named when close;
    /// the default of `ObstacleNamer.wallMaxDistance`.
    public static let wallMaxDistance: Float = 1.5

    /// Step used when sweeping a distance range for the distinct phrases it produces, metres.
    /// 1 cm is far finer than the half-metre bucketing of `SpokenDistance.phrase`, so no bucket
    /// can be stepped over.
    private static let sweepStep: Float = 0.01

    // MARK: Templates (the single source of truth for each line's wording)

    /// The obstacle-name line: "One meter ahead, door" (no full stop — the namer never added one).
    ///
    /// Distance first, object second, on purpose: a blind walker needs the time-to-contact before
    /// the identity — the distance decides whether to stop now, the noun only says what stopped
    /// them. If speech is cut off mid-line (an interrupting route cue), the part already heard is
    /// the urgent one.
    ///
    /// Called by `ObstacleNamer.update` (the app) *and* by `obstacleNameLines` below, which is why
    /// the prefetched string cannot drift from the spoken one.
    /// - Parameters:
    ///   - name: `ObstacleClass.spokenName` ("wall", "table", "seat", "window", "door").
    ///   - distance: metres to the face; a non-finite distance drops the distance clause, as
    ///     `SpokenDistance.phrase` returns "" for it.
    /// - Returns: the line to speak.
    public static func obstacleLine(name: String, distance: Float) -> String {
        let phrase = SpokenDistance.phrase(distance)
        return phrase.isEmpty ? "\(name) ahead"
            : "\(SpokenDistance.leadingCapitalized(phrase)) ahead, \(name)"
    }

    /// The centre-approach cue line: "One and a half meters ahead."
    ///
    /// Called by `CueSpeechPolicy.line(for:phoneCannotBuzz:now:)` *and* by `approachLines` below.
    /// Only spoken when the phone cannot buzz (haptic engine down or silenced); otherwise the
    /// Taptic pattern is the channel.
    /// - Parameter distance: centre-lane distance in metres, already clamped to
    ///   `CueThresholds.centerNear` by `CueDecider`.
    /// - Returns: the line to speak.
    public static func approachLine(distance: Float) -> String {
        "\(SpokenDistance.leadingCapitalized(SpokenDistance.phrase(distance))) ahead."
    }

    // MARK: Bucket sampling

    /// One representative distance for each distinct phrase `SpokenDistance.phrase` produces in
    /// `[from, below)`, in ascending order.
    ///
    /// Sweeps at `sweepStep` and keeps the first distance that yields a phrase not seen yet. This
    /// is how the enumeration stays honest: it asks the production bucketing what it can say
    /// instead of assuming the half-metre steps are 0.5, 1.0, 1.5 … (they are not — above 2 m the
    /// phrasing switches to digits, and "2.5 meters" comes out of the `%.1f` branch).
    /// - Parameters:
    ///   - from: inclusive lower bound, metres.
    ///   - below: exclusive upper bound, metres (the reachable limit of the warning kind).
    /// - Returns: ascending representative distances, one per distinct phrase; empty if
    ///   `below <= from`.
    public static func bucketSamples(from: Float, below: Float) -> [Float] {
        var seen = Set<String>()
        var samples: [Float] = []
        var d = from
        while d < below {
            if seen.insert(SpokenDistance.phrase(d)).inserted { samples.append(d) }
            d += sweepStep
        }
        return samples
    }

    // MARK: Line sets

    /// Every obstacle name the mesh classifier can speak, at every distance phrase it can reach:
    /// "window ahead, one and a half meters" and 31 siblings.
    ///
    /// `ObstacleClass.spokenName` supplies the nouns (nil-named classes — none, floor, ceiling —
    /// are never announced) and `bucketSamples` the distances, with walls cut off at
    /// `wallMaxDistance` because `ObstacleNamer` only names a wall when it is close. Since Step 36
    /// names are off by default and `CueRules` never lets a wall through, so the wall lines here are
    /// prefetched but unreachable; kept so a future level that names walls needs no prefetch change
    /// (a few kB of cache). Prefetched first because, when names are on, they are the most frequent.
    public static let obstacleNameLines: [String] = ObstacleClass.allCases.flatMap { cls -> [String] in
        guard let name = cls.spokenName else { return [] }
        let limit = cls == .wall ? wallMaxDistance : obstacleMaxDistance
        return bucketSamples(from: 0, below: limit).map { obstacleLine(name: name, distance: $0) }
    }

    /// The centre-approach cue lines ("Ahead, half a meter." … "Ahead, two meters.").
    ///
    /// `CueDecider` fires `.centerApproach` with a distance clamped into
    /// `[centerNear, center + hysteresis)` — it enters the centre zone below `center` and only
    /// leaves it once the obstacle has receded past `center + hysteresis` — so those are the only
    /// distances `CueSpeechPolicy` can ever phrase. The other two cue lines ("Left.", "Right.")
    /// and the safety line ("Head height.") are fixed strings and already in
    /// `AppModel.commonLines`.
    public static let approachLines: [String] = {
        let t = CueThresholds()
        return bucketSamples(from: t.centerNear, below: t.center + t.hysteresis)
            .map { approachLine(distance: $0) }
    }()

    /// Every ground-hazard line ("Drop-off ahead, two meters." … "Low obstacle ahead, 3.5 meters.").
    ///
    /// Built with `GroundHazard.spokenLine` itself, at the distances `GroundHazardDetector` can
    /// actually report: it only looks past `Config.nearMax`, bins the scan in `Config.binSize`
    /// steps up to `Config.scanMax`, and reports a bin start or the end of the last visible ground
    /// bin — never a continuous value. Ground hazards ship off by default (AGENTS.md: new and
    /// untuned on the real cane), but the lines are `.safety` when they are on, i.e. exactly the
    /// band where a voice flip is loudest, so they are prefetched last rather than not at all.
    public static let groundHazardLines: [String] = {
        let c = GroundHazardDetector.Config()
        // Bin starts (nearMax, +binSize … < scanMax) plus one more step: the "end of the last
        // visible ground" the drop-off branch reports when bins are missing is `start + binSize`.
        var distances: [Float] = []
        var start = c.nearMax
        while start < c.scanMax {
            distances.append(start)
            start += c.binSize
        }
        distances.append(start)
        var seen = Set<String>()
        return GroundHazardKind.allCases.flatMap { kind in
            distances.compactMap { d -> String? in
                let line = GroundHazard(kind: kind, distance: d, delta: 0).spokenLine
                return seen.insert(line).inserted ? line : nil
            }
        }
    }()

    /// Every sign line on-device text recognition can speak ("Sign: sidewalk closed.").
    ///
    /// `SignPolicy.phrases` is a closed table of 18 safety and wayfinding phrases and the line is
    /// always `"Sign: " + phrase.lowercased() + "."`, so the whole set is 18 lines. Sign reading is
    /// **on** by default and the lines are spoken at `.obstacle` priority, so without this they
    /// are exactly the kind of line that arrives in the system voice mid-walk.
    public static let signLines: [String] = SignPolicy.phrases.map { "Sign: \($0.lowercased())." }

    /// Everything above, in the order it should be synthesized: the lines the walker hears
    /// constantly first.
    ///
    /// `VoicePrefetch.queue` preserves this order, drops repeats and drops anything already
    /// cached, and only `VoicePrefetch.maxConcurrent` (2) requests are in flight, so order decides
    /// which lines are warm first on a slow network. Obstacle names (on by default, every few
    /// seconds indoors) come before the approach cues (only spoken when the phone cannot buzz),
    /// then signs (on by default, at most one a minute), then ground hazards (off by default).
    public static let warningLines: [String] =
        obstacleNameLines + approachLines + signLines + groundHazardLines

    // MARK: Cost

    /// Characters of ElevenLabs quota `warningLines` may cost, one time.
    ///
    /// The free tier is 10,000 characters *per month* in total, so a careless cross-product
    /// (say, five nouns × every 0.1 m step, or a "Caution: …" template crossed with distances)
    /// could spend a month's quota in one launch. `warningLines` is 1,718 characters today —
    /// 17 % of a month, paid once because every line is cached on disk forever after its first
    /// synthesis. The budget is deliberately close to that: adding a whole new templated family
    /// should fail a test and be a decision, not a surprise on the bill.
    /// ⚠ Pinned by `spokenPhrasesStayInsideTheCharacterBudget`.
    public static let warningCharacterBudget = 2_000

    /// Total characters ElevenLabs would be billed for `lines` (its quota counts request text).
    /// - Parameter lines: the lines that would be synthesized.
    /// - Returns: the sum of their character counts.
    public static func characterCount(_ lines: [String]) -> Int {
        lines.reduce(0) { $0 + $1.count }
    }
}
