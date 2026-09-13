//
//  TripRefreshGeneration.swift
//  CaneKitLogic
//
//  Generation fence for asynchronous trip-metric reads. A HealthKit query can finish after the
//  route that started it has ended; only a result carrying the current generation may update the
//  visible trip. The app target owns HealthKit I/O, while this Foundation-only value keeps the
//  race rule testable.
//

import Foundation

/// Monotonic token source for asynchronous trip refreshes.
public struct TripRefreshGeneration: Sendable, Equatable {
    /// The token currently belonging to the active (or most recently stopped) trip.
    private(set) public var current: UInt64 = 0

    /// Creates an empty fence. The first trip receives token 1.
    public init() {}

    /// Starts a new trip and invalidates every outstanding read from an older trip.
    @discardableResult
    public mutating func begin() -> UInt64 {
        current &+= 1
        return current
    }

    /// Invalidates outstanding reads without starting a replacement trip.
    public mutating func invalidate() {
        current &+= 1
    }

    /// Returns whether a result belongs to the current trip generation.
    public func accepts(_ token: UInt64) -> Bool { token == current }
}
