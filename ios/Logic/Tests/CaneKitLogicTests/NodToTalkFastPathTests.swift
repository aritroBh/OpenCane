//
//  NodToTalkFastPathTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins the "Nod to talk" rule in `FastPathIntentClassifier` (rule 5b) — the on-device
//  path for "turn on nod to talk", which `ConversationCoordinator` resolves to
//  `HandsFreeOption.nodToTalk` by raw value. Kept in its own file so the option's app half can be
//  reviewed on its own; the rest of the classifier is pinned in ConversationLogicTests.swift.
//
//  Key invariants:
//    · The raw value string is `"nodToTalk"`, matching the `HandsFreeOption` case name exactly.
//    · A nod phrase with no on/off verb is not a setting change (falls through to the cloud).
//
//  Breaks these catch: a renamed option string (the coordinator's `HandsFreeOption(rawValue:)`
//  lookup silently fails and the switch never moves), the AirPods / headphones status rule eating
//  "head nod", and a question about the feature toggling it.
//

import Testing
@testable import CaneKitLogic

/// On and off phrasings, including the "head nod" synonym that the AirPods status rule must not eat.
@Test func nodToTalkSwitchesByVoice() {
    #expect(FastPathIntentClassifier.classify(query: "turn on nod to talk") == .updateSetting(option: "nodToTalk", enabled: true))
    #expect(FastPathIntentClassifier.classify(query: "Enable head nod.") == .updateSetting(option: "nodToTalk", enabled: true))
    #expect(FastPathIntentClassifier.classify(query: "turn off nod to talk") == .updateSetting(option: "nodToTalk", enabled: false))
    #expect(FastPathIntentClassifier.classify(query: "disable nodding") == .updateSetting(option: "nodToTalk", enabled: false))
}

/// "What is nod to talk" is a question, not a switch; the fast path stays out of it.
@Test func nodToTalkWithoutAVerbIsNotASetting() {
    #expect(FastPathIntentClassifier.classify(query: "what is nod to talk") == nil)
}
