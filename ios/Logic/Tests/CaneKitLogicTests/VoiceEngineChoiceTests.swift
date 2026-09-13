//
//  VoiceEngineChoiceTests.swift
//  CaneKitLogicTests
//
//  Pins the one table that decides which voice speaks a line (Step 53) and the breaker that keeps
//  the answer stable across a network outage (Step 54).
//
//  Why these tests exist: the first cane-mounted walk (2026-09-13, `canekit-2026-09-13T04-36-32Z`)
//  flipped between the ElevenLabs voice and Apple's every few lines and no log field said why. The
//  decision now lives in `VoiceEngineChoice.decide` and is written to every `speech_dispatch`
//  record as `engine` / `engine_reason`, so the raw values below are a log contract: renaming one
//  silently breaks `cue_audit.py`'s engine-flip count. The breaker (`VoiceBreaker`) is
//  session-sticky on purpose — owner decision 2026-09-13 "one voice": a flip happens once per
//  outage, never once per line, and only a *successful* background fetch may close it.
//
//  Source pinned: `VoiceEngineChoice.swift` (`decide`, `raceDeadline`, `resolvedEngine`,
//  `describe`), `VoiceBreaker.swift`. Owner: `SpeechQueue.speakNow` / `prefetch` (app).
//

import Foundation
import Testing

@testable import CaneKitLogic

// MARK: - The decision table

/// Automation mute wins over everything: no key, no cache, no network question is asked.
@Test func mutedNeverMakesASound() {
    let d = VoiceEngineChoice.decide(muted: true, hasKey: true, naturalEnabled: true, cached: true,
                                     isWarning: false, breakerOpen: false)
    #expect(d == VoiceEngineDecision(engine: .muted, reason: .muted))
}

/// Without an ElevenLabs key every line is the system voice, whatever else is true (hard rule 4:
/// no key, no crash, no silence).
@Test func noKeyAlwaysSystem() {
    for cached in [true, false] {
        let d = VoiceEngineChoice.decide(hasKey: false, naturalEnabled: true, cached: cached,
                                         isWarning: false, breakerOpen: false)
        #expect(d == VoiceEngineDecision(engine: .system, reason: .noKey))
    }
}

/// The Settings picker on "System" is the founder's emergency valve at a venue with bad Wi-Fi: it
/// must win even over a warm cache, or the picker would look broken on the lines that matter least.
@Test func naturalOffAlwaysSystem() {
    let d = VoiceEngineChoice.decide(hasKey: true, naturalEnabled: false, cached: true,
                                     isWarning: false, breakerOpen: false)
    #expect(d == VoiceEngineDecision(engine: .system, reason: .naturalOff))
}

/// A cached line plays in the natural voice with no network question at all — including a
/// warning, and including while the breaker is open (the breaker is about *fetching*, and a file
/// on disk needs no fetch). This is the case the launch prefetch exists to make universal.
@Test func cacheHitIsNaturalEvenForAWarningWithTheBreakerOpen() {
    let d = VoiceEngineChoice.decide(hasKey: true, naturalEnabled: true, cached: true,
                                     isWarning: true, breakerOpen: true)
    #expect(d == VoiceEngineDecision(engine: .natural, reason: .cached))
}

/// Warnings never wait for the network (AGENTS.md): an uncached `.obstacle` / `.safety` line is
/// the system voice *now*, breaker or not. 2.5 s of fetch is 3.5 m of walking into the obstacle.
@Test func warningMissIsSystemNow() {
    for breaker in [true, false] {
        let d = VoiceEngineChoice.decide(hasKey: true, naturalEnabled: true, cached: false,
                                         isWarning: true, breakerOpen: breaker)
        #expect(d == VoiceEngineDecision(engine: .system, reason: .warningMiss))
    }
}

/// With the breaker open an uncached line does not race the network again: one outage, one flip.
@Test func breakerOpenIsSystemNow() {
    let d = VoiceEngineChoice.decide(hasKey: true, naturalEnabled: true, cached: false,
                                     isWarning: false, breakerOpen: true)
    #expect(d == VoiceEngineDecision(engine: .system, reason: .breakerOpen))
}

/// Everything else — a novel answer, a route line the prefetch has not reached — is a race: fetch
/// for at most `raceDeadline`, then the system voice. The dispatch record says `race`; the
/// `speech_engine` record that follows says who won.
@Test func anyOtherMissRaces() {
    let d = VoiceEngineChoice.decide(hasKey: true, naturalEnabled: true, cached: false,
                                     isWarning: false, breakerOpen: false)
    #expect(d == VoiceEngineDecision(engine: .race, reason: .race))
}

/// 2.5 s total (not URLRequest's idle timeout): at walking pace that is ~3.5 m, the most a
/// direction may arrive late by. Moved here from `SpeechQueue` (hard rule 3).
@Test func raceDeadlineIsPinned() {
    #expect(VoiceEngineChoice.raceDeadline == 2.5)
}

/// ⚠ Log contract. These strings are what `speech_dispatch.engine` / `engine_reason` and
/// `speech_engine.engine_reason` carry; `cue_audit.py` matches them by name.
@Test func engineAndReasonRawValuesArePinned() {
    #expect(VoiceEngine.natural.rawValue == "elevenlabs")
    #expect(VoiceEngine.system.rawValue == "system")
    #expect(VoiceEngine.race.rawValue == "race")
    #expect(VoiceEngine.muted.rawValue == "muted")
    let expected: [VoiceEngineReason: String] = [
        .muted: "muted", .noKey: "no_key", .naturalOff: "natural_off", .cached: "cached",
        .warningMiss: "warning_miss", .breakerOpen: "breaker_open", .race: "race",
        .raceWon: "race_won", .raceTimeout: "race_timeout", .raceFailed: "race_failed",
        .playbackFailed: "playback_failed", .watchdogFallback: "watchdog_fallback",
    ]
    for reason in VoiceEngineReason.allCases {
        #expect(reason.rawValue == expected[reason], "\(reason) is not pinned")
    }
    #expect(expected.count == VoiceEngineReason.allCases.count)
}

/// A race resolves to exactly one engine: only a won race is the natural voice.
@Test func aResolvedRaceNamesTheEngineThatSpoke() {
    #expect(VoiceEngineChoice.resolvedEngine(.raceWon) == .natural)
    #expect(VoiceEngineChoice.resolvedEngine(.raceTimeout) == .system)
    #expect(VoiceEngineChoice.resolvedEngine(.raceFailed) == .system)
    #expect(VoiceEngineChoice.resolvedEngine(.playbackFailed) == .system)
}

/// The Details card's last line: every reason has words, never a raw value, and the words name
/// the voice first (what the walker heard) and the reason second (why).
@Test func everyReasonHasWordsForTheDetailsCard() {
    for reason in VoiceEngineReason.allCases {
        for engine in [VoiceEngine.natural, .system, .race, .muted] {
            let line = VoiceEngineChoice.describe(engine: engine, reason: reason)
            #expect(!line.isEmpty)
            #expect(!line.contains("_"), "raw value leaked: \(line)")
        }
    }
    #expect(VoiceEngineChoice.describe(engine: .natural, reason: .cached) == "Natural voice · cached")
    #expect(VoiceEngineChoice.describe(engine: .system, reason: .warningMiss) == "System voice · warning not cached yet")
    #expect(VoiceEngineChoice.describe(engine: .system, reason: .raceTimeout) == "System voice · natural voice took over 2.5 s")
}

// MARK: - The breaker

/// A race that times out or fails opens the breaker; opening twice is not a change.
@Test func breakerOpensOnARaceTimeoutOrFailure() {
    // (Mutating calls are bound first: `#expect` cannot call a mutating member inside its macro.)
    var b = VoiceBreaker()
    #expect(!b.isOpen)
    let opened = b.trip(.raceTimeout, now: 10)
    #expect(opened)
    #expect(b.isOpen)
    let reopened = b.trip(.raceFailed, now: 11)
    #expect(!reopened)                               // already open: no state change
    var c = VoiceBreaker()
    let openedOnFailure = c.trip(.raceFailed, now: 10)
    #expect(openedOnFailure)
    #expect(c.isOpen)
}

/// Session-sticky: time alone never closes it. The old 60 s self-reset flipped the voice back
/// every minute of a long outage, and every flip was a wrong-voice line at a street corner.
@Test func breakerNeverClosesOnTimeAlone() {
    var b = VoiceBreaker()
    _ = b.trip(.raceTimeout, now: 0)
    #expect(b.isOpen)
    #expect(b.probeDue(now: 10_000))
    b.probed(now: 10_000)
    #expect(b.isOpen)
}

/// Only proof closes it: a background prefetch that actually fetched at least one line. A
/// prefetch with nothing left to request proves nothing about the network and leaves it open.
@Test func breakerClosesOnlyWhenAPrefetchActuallyFetchedSomething() {
    var b = VoiceBreaker()
    _ = b.trip(.raceFailed, now: 0)
    let closedByNothing = b.prefetchSucceeded(requested: 0)
    #expect(!closedByNothing)
    #expect(b.isOpen)
    let closedByAFetch = b.prefetchSucceeded(requested: 1)
    #expect(closedByAFetch)
    #expect(!b.isOpen)
    let closedAgain = b.prefetchSucceeded(requested: 3)
    #expect(!closedAgain)                            // already closed: no state change
}

/// While open, a probe is due every `probeInterval`, counted from the trip or the last probe.
@Test func probeIsDueEverySixtySecondsWhileOpenAndNeverWhileClosed() {
    var b = VoiceBreaker()
    #expect(!b.probeDue(now: 1_000))                 // closed: nothing to probe
    _ = b.trip(.raceTimeout, now: 100)
    #expect(!b.probeDue(now: 159.9))
    #expect(b.probeDue(now: 160))
    b.probed(now: 160)
    #expect(!b.probeDue(now: 219))
    #expect(b.probeDue(now: 220))
    _ = b.prefetchSucceeded(requested: 1)
    #expect(!b.probeDue(now: 10_000))
}

/// 60 s between probes ([H]): often enough that a venue's Wi-Fi coming back is noticed within a
/// minute, rare enough that a dead network costs one small request a minute, not one per line.
@Test func breakerProbeIntervalAndReasonsArePinned() {
    #expect(VoiceBreaker.probeInterval == 60)
    #expect(VoiceBreaker.Reason.raceTimeout.rawValue == "race_timeout")
    #expect(VoiceBreaker.Reason.raceFailed.rawValue == "race_failed")
    #expect(VoiceBreaker.Reason.prefetchSucceeded.rawValue == "prefetch_succeeded")
}
