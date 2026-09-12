//
//  SpeechLoadPolicy.swift
//  CaneKitLogic
//
//  Decides whether optional environmental narration should enter OpenCane's shared speech
//  channel. This is deliberately smaller than the AVFoundation queue: it only protects a walker
//  from repeated mesh obstacle names, while route, safety, haptic-fallback and user-requested
//  speech bypass it.
//
//  The seven-second default is a reversible calibration hypothesis for unsolicited callouts, not
//  a claim about human conversational turn-taking. The policy drops optional lines instead of
//  sleeping or stacking stale work behind a route instruction. The app owns effects; this file is
//  Foundation-only and clock-injected for deterministic tests.
//
//  Why (Step 30, docs/auditory-load.md): blind-navigation research says to emit discontinuously and
//  only on critical events, and headphone audio masks the traffic a walker listens to. Mesh
//  obstacle names are the one optional, unsolicited, high-frequency channel, so they are the one
//  channel this policy rations; nothing a walker must hear is ever dropped here. Open: tune the 7 s
//  window from trip logs (`speech_suppressed`) with a blind / O&M-trained tester.
//
//  Owner: `SpeechQueue` (app, main actor) holds one `loadPolicy` and calls `admit` inside `say`,
//  immediately after trimming a line and before queue insertion, with `isBusy` = speaking (the
//  pause between bands included) or interrupted; `stopAll()` calls `reset()`. The only producer of
//  `.ambientObstacleName` is `AppModel`'s obstacle-name path (`ObstacleNamer` line, TTL 4 s). A
//  suppressed line goes to `SpeechQueue.onSuppressed`, logged by `AppModel` as `speech_suppressed`
//  (`text`, `load`, `reason`).
//  Isolation: nonisolated `Sendable` value; mutated only by its main-actor owner.
//  Tests: `SpeechLoadPolicyTests.swift` (7).
//

import Foundation

/// The load class supplied by a speech producer (`SpeechQueue.say(load:)`, default `.normal`).
/// Raw values are logged as `speech_suppressed.load`.
public enum SpeechLoadClass: String, Sendable, Equatable {
    /// Route, safety, explicit-request, status, or other speech that must remain fail-open.
    case normal
    /// A supplementary mesh name such as "One meter ahead, door".
    case ambientObstacleName
}

/// Why an optional environmental line was not admitted. Raw values are logged as
/// `speech_suppressed.reason` and counted by `ios/scripts/cue_audit.py` (`suppressed`).
public enum SpeechSuppressionReason: String, Sendable, Equatable {
    /// Another optional environmental line was admitted too recently.
    case calmWindow
    /// A different line is already using the shared voice channel.
    case busy
    /// The caller supplied an unusable clock value.
    case invalidTime
}

/// The pure admission result consumed by `SpeechQueue`.
public enum SpeechLoadDecision: Sendable, Equatable {
    /// The line may proceed through the normal priority queue.
    case speak
    /// The line is optional and should be discarded with the supplied diagnostic reason.
    case suppress(reason: SpeechSuppressionReason)
}

/// Small state machine that prevents optional obstacle-name narration from crowding out listening.
///
/// The state records only the last admitted optional line. A busy or invalid request does not move
/// the clock, so a dropped detection cannot make the next real detection wait longer. The caller
/// supplies `now`; this type never reads a system clock, sleeps, or touches audio state.
public struct SpeechLoadPolicy: Sendable, Equatable {

    /// Numeric tuning for the optional narration channel.
    public struct Configuration: Sendable, Equatable {
        /// Minimum seconds between admitted optional obstacle-name lines. [H] 7 s — a calibration
        /// hypothesis, not a measurement (see the file header).
        public let minimumAmbientGap: TimeInterval

        /// Creates a configuration, clamping negative or non-finite gaps to a safe zero or default.
        /// The shipped seven-second default is pinned by `SpeechLoadPolicyTests`.
        public init(minimumAmbientGap: TimeInterval = 7.0) {
            self.minimumAmbientGap = minimumAmbientGap.isFinite ? max(0, minimumAmbientGap) : 7.0
        }
    }

    /// The configuration used by this policy instance.
    public let configuration: Configuration
    /// The last clock value (caller's seconds) at which an optional line was admitted; −∞ so the
    /// first name is always admitted (`firstObstacleNameIsAdmitted`).
    private var lastAmbientAt: TimeInterval = -.infinity

    /// Creates a policy with the calm default or an injected test/calibration gap.
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Determines whether one producer line may enter the speech queue.
    ///
    /// Normal content bypasses all load controls. Optional obstacle names are dropped while the
    /// queue is busy or until `minimumAmbientGap` has elapsed since the last admitted name. The
    /// boundary is inclusive: a seven-second gap is enough. A non-finite clock fails closed only
    /// for optional content; protected and explicit speech remains fail-open.
    /// - Parameters:
    ///   - kind: the producer's load class.
    ///   - now: a monotonic-ish caller timestamp in seconds.
    ///   - isBusy: whether another line, interruption, or pending audio session owns the channel.
    /// - Returns: `.speak` or a diagnostic suppression reason. Checks run invalid time → busy →
    ///   calm window, so a busy drop never reports `.calmWindow`.
    /// Pinned by `normalSpeechIsNeverSuppressed`, `obstacleNamesInsideCalmWindowAreDropped`,
    /// `calmWindowBoundaryIsInclusive`, `busyDropDoesNotConsumeTheClock`, `nonFiniteTimeIsRejected`.
    public mutating func admit(_ kind: SpeechLoadClass, now: TimeInterval,
                               isBusy: Bool) -> SpeechLoadDecision {
        guard kind == .ambientObstacleName else { return .speak }
        guard now.isFinite else { return .suppress(reason: .invalidTime) }
        guard !isBusy else { return .suppress(reason: .busy) }
        guard now - lastAmbientAt >= configuration.minimumAmbientGap else {
            return .suppress(reason: .calmWindow)
        }
        lastAmbientAt = now
        return .speak
    }

    /// Forget the previous optional narration timestamp. Called by `SpeechQueue.stopAll()` (route
    /// stop and other full-queue clears). Pinned by `resetClearsTheClock`.
    public mutating func reset() {
        lastAmbientAt = -.infinity
    }
}
