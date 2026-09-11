//
//  ObstacleNamer.swift
//  CaneKit
//
//  Turns the mesh classification at the image centre into a spoken name: "door ahead, two
//  meters". Speaks only on a change of class or half-metre bucket, at most once per 2.5 s, and
//  only indoors-ish ranges (mesh classification is unreliable past ~3 m and in sunlight).
//

import CaneKitLogic
import Foundation

@MainActor
final class ObstacleNamer {

    /// Minimum gap between spoken names (spec: one utterance per 2.5 s).
    var minInterval: TimeInterval = 2.5
    /// Name anything classified closer than this…
    var maxDistance: Float = 3.0
    /// …except walls, which are everywhere; only name them when close.
    var wallMaxDistance: Float = 1.5
    /// Forget the last announcement after this long without a hit, so re-approaching re-announces.
    var forgetAfter: TimeInterval = 2.0

    private var lastClass: ObstacleClass?
    private var lastBucket = -1
    private var lastSpoken: TimeInterval = -.infinity
    private var lastHit: TimeInterval = -.infinity

    init() {}

    func reset() {
        lastClass = nil
        lastBucket = -1
        lastSpoken = -.infinity
        lastHit = -.infinity
    }

    /// - Returns: a line to speak, or nil.
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
