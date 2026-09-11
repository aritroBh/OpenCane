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
    public static let maxConcurrent = 2

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
    public static func queue(_ lines: [String], isCached: (String) -> Bool) -> [String] {
        var seen = Set<String>()
        return lines.filter { line in
            !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && seen.insert(line).inserted
                && !isCached(line)
        }
    }
}
