//
//  ObstacleNamer.swift
//  CaneKit
//
//  Turns the mesh classification at the image centre into a spoken name: "door ahead, two
//  meters". Speaks only on a change of class or half-metre bucket, at most once per 2.5 s, and
//  only indoors-ish ranges (mesh classification is unreliable past ~3 m and in sunlight).
//
//  Threading / isolation: `@MainActor`, synchronous, no timers or callbacks. `AppModel.handle`
//  calls `update` for every depth report (~15 Hz) on main and forwards a non-nil line to
//  `SpeechQueue.say(_, .obstacle, ttl: 4)` — obstacle band, below route lines and "Head height.",
//  so a name never cuts guidance and a 4 s TTL keeps a queued name from being spoken stale.
//  Times are the caller's clock (`LaneReport.timestamp`, ARKit seconds), never wall time.
//  Only called while obstacle names are enabled in settings.
//

import CaneKitLogic
import Foundation

/// Rate-limited, change-triggered namer for the mesh class straight ahead. Pure state machine
/// over `LaneReport.centerHit`; returns text, speaks nothing itself.
@MainActor
final class ObstacleNamer {

    /// Minimum gap between spoken names (spec: one utterance per 2.5 s).
    var minInterval: TimeInterval = 2.5
    /// Name anything classified closer than this…
    /// Metres, measured along the camera axis (`MeshHit.distance` = centre-window depth).
    var maxDistance: Float = 3.0
    /// …except walls, which are everywhere; only name them when close.
    /// Metres.
    var wallMaxDistance: Float = 1.5
    /// Forget the last announcement after this long without a hit, so re-approaching re-announces.
    /// Seconds of report time.
    var forgetAfter: TimeInterval = 2.0

    /// Class of the last announcement; nil = nothing announced (or forgotten).
    private var lastClass: ObstacleClass?
    /// Half-metre bucket (distance × 2, rounded) of the last announcement; -1 = none.
    private var lastBucket = -1
    /// Report time of the last returned line (enforces `minInterval`).
    private var lastSpoken: TimeInterval = -.infinity
    /// Report time of the last nameable, in-range hit (drives `forgetAfter`).
    private var lastHit: TimeInterval = -.infinity

    init() {}

    /// Forget all history so the next nameable hit is announced at once. Called by
    /// `AppModel.scenePhaseChanged(.background)` alongside `CueDecider.reset()`, so whatever is
    /// in front of the user after returning to the app is named afresh.
    func reset() {
        lastClass = nil
        lastBucket = -1
        lastSpoken = -.infinity
        lastHit = -.infinity
    }

    /// - Returns: a line to speak, or nil.
    ///
    /// A line is returned only when the report is trusted (cane not mid-sweep), the centre hit
    /// has a speakable class (`ObstacleClass.spokenName`: wall/table/seat/window/door) within
    /// range, the class or distance changed (≥ 1 m, i.e. two half-metre buckets), and
    /// `minInterval` has passed. Format: "door ahead, one meter" (`SpokenDistance.phrase`).
    /// - Parameters:
    ///   - r: the latest depth report (its `centerHit` is refreshed at ~4 Hz by the processor).
    ///   - now: report time in seconds (`r.timestamp`).
    func update(_ r: LaneReport, now: TimeInterval) -> String? {
        // Nothing nameable straight ahead (or out of range): forget after a while so that
        // re-approaching the same door announces it again.
        guard r.isTrusted, let hit = r.centerHit, let name = hit.classification.spokenName,
              hit.distance.isFinite,
              hit.distance < (hit.classification == .wall ? wallMaxDistance : maxDistance) else {
            if now - lastHit > forgetAfter { lastClass = nil; lastBucket = -1 }
            return nil
        }
        lastHit = now

        // Half-metre buckets with hysteresis: the same class re-announces only after moving a
        // full metre, so jitter around a bucket edge never repeats "wall ahead" while standing.
        let bucket = Int((hit.distance * 2).rounded())
        let changed = hit.classification != lastClass || abs(bucket - lastBucket) >= 2
        guard changed, now - lastSpoken >= minInterval else { return nil }

        lastClass = hit.classification
        lastBucket = bucket
        lastSpoken = now
        let dist = SpokenDistance.phrase(hit.distance)
        return dist.isEmpty ? "\(name) ahead" : "\(name) ahead, \(dist)"
    }
}
