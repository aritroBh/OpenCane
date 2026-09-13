//
//  NavigationHealth.swift
//  CaneKitLogic
//
//  Pure freshness rule for GPS-driven navigation. The app adapter owns CoreLocation lifecycle;
//  this type owns the wall-clock test that decides whether a retained fix may still drive route
//  cues. A failed or revoked location stream therefore has a deterministic, testable fail-safe:
//  guidance loses its target once the last fix is older than the bound.
//
//  Owner / callers: `NavigationEngine.tick` (route ticker) and its Logic tests. The timestamp and
//  `now` values are both `timeIntervalSinceReferenceDate`; invalid or future-dated clocks are not
//  considered fresh. Tests: `NavigationHealthTests.swift`.
//

import Foundation

/// Safety gate for using a retained GPS fix in active navigation.
public enum NavigationHealth {
    /// Maximum age of a retained fix before route cues must be withheld.
    public static let maxFixAge: TimeInterval = 5

    /// Whether a fix timestamp is usable at `now` on the shared wall clock.
    /// A future timestamp is rejected as a clock anomaly rather than treated as indefinitely fresh.
    public static func isFresh(timestamp: TimeInterval, now: TimeInterval) -> Bool {
        guard timestamp.isFinite, now.isFinite else { return false }
        let age = now - timestamp
        return age >= 0 && age < maxFixAge
    }
}
