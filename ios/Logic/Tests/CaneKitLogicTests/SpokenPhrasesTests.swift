//
//  SpokenPhrasesTests.swift
//  CaneKitLogicTests
//
//  Pins `SpokenPhrases`: the enumerated warning lines the launch prefetch synthesizes so that a
//  warning — which must never wait for the network — still plays in the natural voice.
//
//  Two things have to hold, and both are about *drift*, not about wording:
//    1. Completeness. Every line the production code can build must be in the set. So each test
//       drives the production function itself (`SpokenPhrases.obstacleLine` via a distance sweep,
//       a real `CueSpeechPolicy`, `GroundHazard.spokenLine`, a real `SignPolicy`) and asserts the
//       result is a member. Hand-typed expectations would drift by a byte, and a one-byte
//       difference is a silent cache miss — the exact bug this file exists to prevent.
//    2. Cost. Every line is one ElevenLabs synthesis on a 10,000-characters-per-month free tier,
//       so the total is asserted against `warningCharacterBudget`.
//
//  Source pinned: `ios/Logic/Sources/CaneKitLogic/SpokenPhrases.swift` (`obstacleNameLines`,
//  `approachLines`, `signLines`, `groundHazardLines`, `warningLines`, `obstacleLine`,
//  `bucketSamples`, `characterCount`). Callers: `AppModel` (launch warm-up of `warningLines`),
//  `ObstacleNamer` (`obstacleLine`, the same template the set is built from) and `SpeechQueue`
//  (`backgroundLines` re-appended to every prefetch batch). ⚠ `spokenPhrasesStayInsideTheCharacterBudget`
//  pins the exact total (1,718 characters, 74 lines): a reworded warning changes it on purpose.
//

import Foundation
import Testing
@testable import CaneKitLogic

// MARK: Completeness — obstacle names

/// Sweeps the namer's whole reachable range at 1 cm and asserts every line the *production*
/// template produces is one the prefetch enumerated. Walls are cut off at `wallMaxDistance`, the
/// rest at `obstacleMaxDistance`, matching `ObstacleNamer`'s guard.
@Test func everyObstacleNameLineIsPrefetched() {
    let set = Set(SpokenPhrases.obstacleNameLines)
    for cls in ObstacleClass.allCases {
        guard let name = cls.spokenName else { continue }
        let limit = cls == .wall ? SpokenPhrases.wallMaxDistance : SpokenPhrases.obstacleMaxDistance
        var d: Float = 0.01
        while d < limit {
            let line = SpokenPhrases.obstacleLine(name: name, distance: d)
            #expect(set.contains(line), "uncached obstacle line: \(line)")
            d += 0.01
        }
    }
}

/// The classes that are never announced (none, floor, ceiling) must not appear in the set: their
/// `spokenName` is nil, and prefetching "One meter ahead, …" for one would waste quota on a line nobody says.
@Test func silentObstacleClassesAreNotPrefetched() {
    for cls in [ObstacleClass.none, .floor, .ceiling] {
        #expect(cls.spokenName == nil)
    }
    #expect(SpokenPhrases.obstacleNameLines.allSatisfy { line in
        ObstacleClass.allCases.contains { $0.spokenName.map { line.hasSuffix("ahead, \($0)") } ?? false }
    })
}

/// The distance clause is dropped for a non-finite distance (`SpokenDistance.phrase` returns "").
/// `ObstacleNamer` guards `distance.isFinite`, so this line is unreachable in the app and is
/// deliberately *not* prefetched — pinned so a future guard removal shows up here.
@Test func aNonFiniteObstacleDistanceHasNoDistanceClause() {
    #expect(SpokenPhrases.obstacleLine(name: "door", distance: .infinity) == "door ahead")
    #expect(!SpokenPhrases.obstacleNameLines.contains("door ahead"))
}

// MARK: Completeness — centre-approach cue lines

/// Drives a real `CueSpeechPolicy` with `.centerApproach` cues across the whole range
/// `CueDecider` can clamp a centre distance into, and asserts every spoken line was prefetched.
/// `phoneCannotBuzz: true` because that is the only condition under which these lines are spoken,
/// and `now` advances past `sideInterval` so the rate limiter never hides a line.
@Test func everySpokenApproachCueLineIsPrefetched() {
    let set = Set(SpokenPhrases.approachLines)
    let t = CueThresholds()
    var policy = CueSpeechPolicy()
    var now: TimeInterval = 0
    var d = t.centerNear
    while d < t.center + t.hysteresis {
        now += policy.sideInterval + 1
        let spoken = policy.line(for: .centerApproach(distance: d), phoneCannotBuzz: true, now: now)
        #expect(spoken != nil)
        if let spoken { #expect(set.contains(spoken.text), "uncached approach line: \(spoken.text)") }
        d += 0.01
    }
}

/// The fixed cue lines are not `SpokenPhrases`' job: "Head height.", "Left." and "Right." are
/// literals in `CueSpeechPolicy` and live in `AppModel.commonLines`, which the launch prefetch
/// already covered before this change. Pinned so nobody "tidies" them into both sets and pays
/// twice — and so a reworded literal is noticed here.
@Test func fixedCueLinesAreLeftToCommonLines() {
    var policy = CueSpeechPolicy()
    #expect(policy.line(for: .head, phoneCannotBuzz: false, now: 0)?.text == "Head height.")
    #expect(policy.line(for: .left, phoneCannotBuzz: true, now: 100)?.text == "Left.")
    #expect(policy.line(for: .right, phoneCannotBuzz: true, now: 200)?.text == "Right.")
    #expect(!SpokenPhrases.warningLines.contains("Head height."))
}

// MARK: Completeness — ground hazards

/// Every distance `GroundHazardDetector` can report, for every kind, phrased by the production
/// `GroundHazard.spokenLine`. The detector only reports bin starts from `nearMax` up to one
/// `binSize` past the last bin, so the sweep walks that grid rather than a continuum.
@Test func everyGroundHazardLineIsPrefetched() {
    let set = Set(SpokenPhrases.groundHazardLines)
    let c = GroundHazardDetector.Config()
    for kind in GroundHazardKind.allCases {
        var d = c.nearMax
        while d <= c.scanMax + c.binSize {
            let line = GroundHazard(kind: kind, distance: d, delta: -0.2).spokenLine
            #expect(set.contains(line), "uncached hazard line: \(line)")
            d += c.binSize
        }
    }
}

// MARK: Completeness — signs

/// Every phrase in `SignPolicy`'s closed table, spoken through a real `SignPolicy`, must be
/// prefetched. The policy is fed each phrase as close, full-confidence text, one per fresh policy
/// so its 60 s repeat limiter never swallows one.
@Test func everySignLineIsPrefetched() {
    let set = Set(SpokenPhrases.signLines)
    for phrase in SignPolicy.phrases {
        var policy = SignPolicy()
        let spoken = policy.line(for: [(text: phrase, confidence: 0.9)], now: 0)
        #expect(spoken != nil, "SignPolicy would not speak \(phrase)")
        if let spoken { #expect(set.contains(spoken), "uncached sign line: \(spoken)") }
    }
}

// MARK: Shape and cost

/// No repeats: `VoicePrefetch.queue` would drop them anyway, but a duplicate here means the
/// arithmetic in the header (and the budget below) is counting a line twice.
@Test func warningLinesHaveNoRepeats() {
    #expect(Set(SpokenPhrases.warningLines).count == SpokenPhrases.warningLines.count)
}

/// The lines the walker hears constantly are synthesized first. `VoicePrefetch.queue` keeps this
/// order and only two requests are in flight, so on a slow network the obstacle names are warm
/// long before the off-by-default ground hazards.
@Test func warningLinesAreOrderedByHowOftenTheyAreHeard() {
    let lines = SpokenPhrases.warningLines
    let firstHazard = lines.firstIndex(of: SpokenPhrases.groundHazardLines[0])
    let lastName = lines.lastIndex(of: SpokenPhrases.obstacleNameLines.last!)
    #expect(lastName != nil && firstHazard != nil && lastName! < firstHazard!)
    #expect(lines.first == SpokenPhrases.obstacleNameLines.first)
}

/// The whole point of enumerating rather than cross-producting: the one-time ElevenLabs spend
/// must stay a small fraction of the 10,000-character monthly free tier. Fails loudly if a new
/// templated family is added without doing the arithmetic.
/// Breakdown at the time of writing: 777 (32 obstacle names) + 80 (4 approach cues)
/// + 290 (18 signs) + 571 (20 ground hazards) = 1,718 characters. The distance-first reorder
/// is 4 characters cheaper ("Ahead, X." → "X ahead." drops one comma per approach line).
@Test func spokenPhrasesStayInsideTheCharacterBudget() {
    let total = SpokenPhrases.characterCount(SpokenPhrases.warningLines)
    #expect(total == 1_718, "warning-line cost changed: \(total) characters")
    #expect(total <= SpokenPhrases.warningCharacterBudget)
    #expect(SpokenPhrases.characterCount(SpokenPhrases.obstacleNameLines) == 777)
    #expect(SpokenPhrases.characterCount(SpokenPhrases.approachLines) == 80)
    #expect(SpokenPhrases.characterCount(SpokenPhrases.signLines) == 290)
    #expect(SpokenPhrases.characterCount(SpokenPhrases.groundHazardLines) == 571)
    #expect(SpokenPhrases.warningLines.count == 74)
}

/// `bucketSamples` returns one distance per distinct phrase, ascending, and nothing for an empty
/// range — the helper every set above is built from.
@Test func bucketSamplesReturnOneDistancePerDistinctPhrase() {
    let samples = SpokenPhrases.bucketSamples(from: 0, below: 1.6)
    #expect(samples.map { SpokenDistance.phrase($0) }
            == ["very close", "half a meter", "one meter", "one and a half meters"])
    #expect(samples == samples.sorted())
    #expect(SpokenPhrases.bucketSamples(from: 2, below: 2).isEmpty)
}

// MARK: Resuming an interrupted warm-up

/// The property `SpeechQueue.backgroundLines` relies on: re-listing the whole warning set after a
/// batch was cancelled costs only the lines that never reached the disk, and they keep their order.
///
/// `SpeechQueue.prefetch` cancels the batch before it, and a warning that misses the cache calls
/// `prefetch` itself — so the launch warm-up *will* be interrupted, several times, on a normal
/// walk. It survives that only because `VoicePrefetch.queue` drops what is already cached: each
/// restart is the remainder, never a re-run. Simulated here with the first 20 lines cached and a
/// just-missed warning at the head, the way `speakNow` calls it.
@Test func aCancelledWarmUpResumesInsteadOfStartingOver() {
    let all = SpokenPhrases.warningLines
    let done = Set(all.prefix(20))
    let missed = all[40]                      // a warning the walker just heard in the system voice
    let queued = VoicePrefetch.queue([missed] + all) { done.contains($0) }
    #expect(queued.first == missed, "the line just spoken must be synthesized first")
    #expect(queued.count == all.count - 20)   // nothing already on disk is paid for twice
    #expect(queued.dropFirst() == all.dropFirst(20).filter { $0 != missed }[...])
}
