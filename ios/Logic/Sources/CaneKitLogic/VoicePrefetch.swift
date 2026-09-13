//
//  VoicePrefetch.swift
//  CaneKitLogic
//
//  What the natural voice synthesizes ahead of time, in what order, and how many at once.
//  `ElevenLabsVoice.prefetch` (the app) does the network work; the rules live here because they
//  are the kind of thing that looks arbitrary in a network file and is wrong in a way nobody
//  notices until a walk: a prefetch that runs out of order leaves the *first* cue uncached, which
//  is the one cue prefetch existed to make instant.
//
//  Callers: `ElevenLabsVoice.prefetch` (queue + `maxConcurrent` workers) and its error type's
//  fatal check (`isFatal`); `SpeechQueue.prefetch` (app) builds its backlog with `merge` — the
//  caller's new lines first, then what an earlier batch had not reached, then the standing tail
//  (the route's lines, then `backgroundLines` = `SpokenPhrases.warningLines`) — and one worker
//  drains it `chunk` lines at a time (Step 54: prefetch is additive; a warning's cache miss appends
//  to the backlog and never cancels the route batch that is running). Dropping cached lines here is
//  what keeps a re-merged line from being paid for twice.
//  Isolation: stateless and nonisolated; `isCached` is called synchronously on the caller's task.
//  Tests: VoicePrefetchTests.swift (8; `SpokenPhrasesTests.aCancelledWarmUpResumesInsteadOfStartingOver`
//  covers the resume).
//

import Foundation

/// Ordering and concurrency rules for pre-synthesizing spoken lines.
public enum VoicePrefetch {

    /// How many synthesis requests may be in flight at once.
    ///
    /// Two, because the ElevenLabs free tier allows two concurrent text-to-speech requests. The
    /// app also makes a *live* request whenever a line misses the cache, so a third prefetch slot
    /// would put four in flight and earn an HTTP 429 on the one line a walker is waiting to hear.
    /// Raising this makes the cache warm sooner at the cost of rate-limiting live speech, which is
    /// the wrong trade for a blind walker: a warm cache is a convenience, a late turn is a wrong turn.
    /// Pinned by `prefetchConcurrencyLeavesRoomForALiveRequest`.
    public static let maxConcurrent = 2

    /// Whether an HTTP status from the voice service means "stop asking" rather than "try the next
    /// line".
    ///
    /// 401 and 403 are a wrong, expired or unscoped key, and 422 is a voice or model the account
    /// cannot use: every remaining line would fail identically. Without this, one bad key turns a
    /// route prefetch into twenty rejected requests — noise in the log, and a way to get an IP
    /// rate-limited right before a demo. Everything else (429, 5xx, transport errors) is
    /// per-request bad luck and the next line is still worth trying.
    /// - Parameter status: the HTTP status code of a failed synthesis request.
    /// - Returns: true for 401, 403 and 422 only. Pinned by
    ///   `aBadKeyStopsThePrefetchInsteadOfRepeatingItselfTwentyTimes`.
    public static func isFatal(status: Int) -> Bool {
        status == 401 || status == 403 || status == 422
    }

    /// The lines actually worth requesting, in the order they should be requested.
    ///
    /// Callers pass lines in the order they will be spoken (route intro, then waypoint 1, 2, 3 …).
    /// This keeps that order, drops repeats, and drops anything already cached. Order matters:
    /// with `maxConcurrent` requests in flight, whatever is requested first finishes first, and
    /// the walker needs waypoint 1 long before waypoint 9. Deduplicating through a `Set` — the
    /// obvious one-liner — makes the order arbitrary, so the first line of the route can be
    /// synthesized last and the first cue of the walk misses the cache anyway.
    ///
    /// - Parameters:
    ///   - lines: spoken lines, in speaking order. Blank lines are dropped (nothing to synthesize).
    ///   - isCached: whether this exact line is already on disk.
    /// - Returns: the lines to request, in speaking order, without repeats.
    /// Repeats are exact byte matches (the cache is keyed by exact text); blank means empty after
    /// trimming whitespace and newlines, but a kept line is returned untrimmed.
    /// Pinned by `prefetchKeepsSpeakingOrderSoTheFirstCueIsReadyFirst`,
    /// `prefetchDropsRepeatsAndAlreadyCachedLinesButKeepsTheRest`, `prefetchIgnoresBlankLines`.
    public static func queue(_ lines: [String], isCached: (String) -> Bool) -> [String] {
        var seen = Set<String>()
        return lines.filter { line in
            !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && seen.insert(line).inserted
                && !isCached(line)
        }
    }

    /// How many backlog lines one worker pass hands to `ElevenLabsVoice.prefetch` (Step 54). Equal
    /// to `maxConcurrent` so a line merged in while a long batch runs (a route start during the
    /// warning warm-up, a warning that just missed) is requested within one pass rather than after
    /// the whole backlog. Pinned by `prefetchChunkIsTheConcurrencyLimit`.
    public static let chunk = maxConcurrent

    /// The additive backlog (Step 54): what a prefetch worker should still request, in order.
    ///
    /// `new` first — it was asked for *now*: a route's lines at route start (waypoint 1 is needed
    /// in seconds) or a warning that just came out in the system voice and may repeat within
    /// seconds ("Head height." every 4 s). Then `backlog`, what an earlier batch had not reached,
    /// in its own order. Then `tail`, the standing set (route lines, then warning lines). The
    /// union goes through `queue`, so repeats and cached lines are dropped and nothing uncached is
    /// ever lost. Before Step 54 a new batch *cancelled* the running one; the standing tail existed
    /// to survive that, and now simply keeps the warm-up complete.
    /// - Parameters:
    ///   - new: the caller's lines, in speaking order.
    ///   - backlog: lines not yet requested from earlier calls.
    ///   - tail: `routeLines + backgroundLines`.
    ///   - isCached: whether this exact line is already on disk.
    /// - Returns: the lines still worth requesting, in the order above, without repeats.
    /// Pinned by `aNewBatchGoesAheadOfTheBacklogAndTheTailFollows`,
    /// `mergeDropsCachedAndRepeatedLinesButNeverAnUncachedOne`.
    public static func merge(new: [String], backlog: [String], tail: [String],
                             isCached: (String) -> Bool) -> [String] {
        queue(new + backlog + tail, isCached: isCached)
    }
}
