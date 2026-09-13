//
//  NaturalVoiceLatch.swift
//  CaneKitLogic
//
//  How a refused ElevenLabs key stays one voice across launches (Step 63).
//
//  Why this file exists: Step 61 latched `SpeechQueue.naturalVoiceUnavailable` for the rest of
//  *this* session, but a warm mp3 cache never calls the API (`ElevenLabsVoice.prefetch` documents
//  that), so the latch only armed after the first miss. Trip log `canekit-2026-09-13T08-51-14Z`
//  and the first launch after a restart then played cached lines in ElevenLabs and new ones in
//  Apple's. The latch must survive the process, and a later prefetch must not wipe the HTTP 401
//  off the Haptics card.
//
//  Owner / callers: `SpeechQueue.applyPersistedNaturalVoiceLatch` / `markNaturalVoiceUnavailable`
//  / `retryNaturalVoice` / `prefetch` (app). Isolation: stateless and nonisolated.
//  Tests: NaturalVoiceLatchTests.swift; `LaunchRecoveryTests.recoveryNeverClearsTheRefusedVoiceLatch`.
//

import Foundation

/// Persistence and Haptics-card rules for a refused ElevenLabs key.
public enum NaturalVoiceLatch {

    /// `UserDefaults` key written when ElevenLabs returns a fatal status (401 / 403 / 422).
    ///
    /// ⚠ Not in `LaunchRecovery.optionalFeatureKeys`: a crash recovery must not restore two-voice
    /// mixing after the account has already refused the key. Pinned by
    /// `thePersistedKeyIsStable` and `recoveryNeverClearsTheRefusedVoiceLatch`.
    public static let settingsKey = "naturalVoiceUnavailable"

    /// Haptics-card line when the latch is restored and this session has not yet seen a new HTTP
    /// body. Matches the spoken status clause (`StatusSummary.voiceLine`). Never spoken from here.
    public static let persistedError =
        "The natural voice account is out of credit or refused the key."

    /// A later `prefetch` (warning miss, breaker probe) must not wipe the refused-key line.
    /// Pinned by `aLaterPrefetchKeepsTheRefusedKeyLine`.
    public static func shouldClearVoiceError(unavailable: Bool) -> Bool {
        !unavailable
    }
}
