//
//  StopRouteConfirmation.swift
//  CaneKitLogic
//
//  Purpose: a small confirmation state machine for the destructive Stop route action. One tap
//  arms the action; a second tap inside the short window confirms it. This keeps an accidental
//  press from ending guidance for a blind walker while leaving the button's accessibility label
//  stable for the UI contract.
//
//  Owner / caller: `GuideCard`. Tests: `StopRouteConfirmationTests`.
//

import Foundation

/// Two-step confirmation for ending an active route.
public struct StopRouteConfirmation: Sendable, Equatable {
    /// Seconds allowed between the arming tap and the confirming tap.
    public static let window: TimeInterval = 3

    /// The result of a press.
    public enum PressResult: Sendable, Equatable {
        /// The first tap armed the action; no route should be stopped yet.
        case armed
        /// A second tap inside `window` confirmed the stop.
        case confirmed
    }

    private var armedAt: TimeInterval?

    /// Creates an idle confirmation state.
    public init() {
        armedAt = nil
    }

    /// Whether a still-valid confirmation is waiting for its second tap.
    public var isArmed: Bool { armedAt != nil }

    /// Registers a tap at the supplied monotonic timestamp.
    ///
    /// The caller supplies time so tests can cover the boundary without sleeping and the UI can
    /// use `ProcessInfo.systemUptime` without making this pure decision depend on a clock
    /// implementation.
    public mutating func press(at timestamp: TimeInterval) -> PressResult {
        if let armedAt, timestamp >= armedAt, timestamp - armedAt <= Self.window {
            self.armedAt = nil
            return .confirmed
        }
        armedAt = timestamp
        return .armed
    }

    /// Clears a pending confirmation, for example when navigation ends by another control.
    public mutating func reset() {
        armedAt = nil
    }
}
