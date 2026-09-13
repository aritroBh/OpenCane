//
//  PeopleDetection.swift
//  CaneKitLogic
//
//  Purpose: the validation gate and persisted metadata for the optional people-ahead detector.
//  The detector has no measured cane evidence yet, so an enabled setting must remain visibly
//  experimental and may never become a silent default.
//
//  Owner / caller: `AppModel.namePeopleEnabled` and `HazardsCard`. Tests:
//  `PeopleDetectionTests` pins the off-by-default gate and the metadata state.
//

import Foundation

/// State exposed for the optional people-ahead detector.
///
/// There is intentionally no `validated` case: the detector may be enabled for an experiment,
/// but an enabled build must continue to identify itself as unverified until cane evidence is
/// recorded and reviewed.
public enum PeopleDetection {
    /// The persisted default. A setting left over from an older build is still read, but a fresh
    /// install and a recovery-cleared setting both start disabled.
    public static let defaultEnabled = false

    /// State written to diagnostics and exposed to the UI.
    public enum State: String, Codable, Sendable, Equatable {
        /// Detection is disabled.
        case off
        /// Detection is enabled for an experiment, but has not been validated on the cane.
        case experimentalUnverified = "experimental_unverified"

        /// Whether the detector is allowed to run.
        public var isEnabled: Bool { self != .off }

        /// Human-readable caption shown beside the switch. It states the limitation even when
        /// the switch is on, so a color-blind or VoiceOver user does not infer validation.
        public var userFacingDescription: String {
            switch self {
            case .off: "Experimental — off until validated on the cane."
            case .experimentalUnverified: "Experimental — enabled, not validated on the cane."
            }
        }
    }

    /// Converts the user setting to the only allowed metadata state.
    public static func state(enabled: Bool) -> State {
        enabled ? .experimentalUnverified : .off
    }
}

