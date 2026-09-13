//
//  NaturalVoiceLatchTests.swift
//  CaneKitLogicTests
//
//  Pins the refused-key latch that must survive a restart (Step 63).
//
//  Why these tests exist: Step 61 kept the session in one voice *after* a fatal HTTP status, but
//  a warm cache never hits the API, so the next launch mixed ElevenLabs (cached) and Apple
//  (everything else) until the first miss. The key, the "do not wipe the 401" rule, and the
//  recovery exclusion are the contract `SpeechQueue` applies.
//
//  Source pinned: `NaturalVoiceLatch.swift`. Owner: `SpeechQueue` (app).
//

import Foundation
import Testing

@testable import CaneKitLogic

/// The persisted key is what `SpeechQueue` reads and writes; renaming it orphans the latch and
/// the next launch mixes voices again.
@Test func thePersistedKeyIsStable() {
    #expect(NaturalVoiceLatch.settingsKey == "naturalVoiceUnavailable")
}

/// After a refused key, a later prefetch (warning miss, breaker probe) must keep the HTTP 401
/// on the Haptics card. Clearing it made the card look healthy while every line was Apple's.
@Test func aLaterPrefetchKeepsTheRefusedKeyLine() {
    #expect(!NaturalVoiceLatch.shouldClearVoiceError(unavailable: true))
    #expect(NaturalVoiceLatch.shouldClearVoiceError(unavailable: false))
}

/// The restored card line is the same words as the spoken status clause, so a walker who asks
/// "status" and a helper who reads the Haptics card hear the same reason.
@Test func thePersistedErrorMatchesTheSpokenStatusClause() {
    let facts = VoiceFacts(hasKey: true, naturalEnabled: true, breakerOpen: false,
                           cachedShare: 1, unavailable: true)
    #expect(StatusSummary.voiceLine(facts).contains(NaturalVoiceLatch.persistedError))
}
