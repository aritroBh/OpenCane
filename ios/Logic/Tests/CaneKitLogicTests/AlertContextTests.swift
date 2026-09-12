//
//  AlertContextTests.swift
//  CaneKitLogicTests
//
//  Pins what context reaches the Grok Bot payload and what the cheap model is told. The prompt
//  bans are the important part: a small model asked to summarise a fall will, unprompted, offer
//  reassurance it has no basis for ("they are fine", "help is on the way"), and that is the worst
//  sentence this system could text to a parent.
//

import Foundation
import Testing
@testable import CaneKitLogic

private func filledContext() -> AlertContext {
    var c = AlertContext()
    c.navigating = true
    c.destination = "CIF"
    c.instruction = "Cross Springfield Avenue"
    c.distanceToNextM = 42.37
    c.batteryPct = 64
    c.thermalState = "fair"
    c.speedMps = 1.38
    c.headingDeg = 271.6
    c.activeCue = "center"
    c.lastGroundHazard = "Two meters ahead, drop-off."
    c.hasFix = true
    return c
}

/// Every fact the phone had becomes an extra field, rounded to something an SMS writer can read.
@Test func extraFieldsCarryTheContext() {
    let extra = filledContext().extraFields()
    #expect(extra["navigating"] == .bool(true))
    #expect(extra["has_fix"] == .bool(true))
    #expect(extra["destination"] == .string("CIF"))
    #expect(extra["instruction"] == .string("Cross Springfield Avenue"))
    #expect(extra["distance_to_next_m"] == .number(42.4))      // one decimal
    #expect(extra["battery_pct"] == .number(64))
    #expect(extra["speed_mps"] == .number(1.4))
    #expect(extra["heading_deg"] == .number(272))              // whole degrees
    #expect(extra["active_cue"] == .string("center"))
    #expect(extra["thermal_state"] == .string("fair"))
}

/// Unknown must never arrive as zero: an empty context sends only the two booleans it is sure of.
@Test func unknownFieldsAreOmittedNotZeroed() {
    let extra = AlertContext().extraFields()
    #expect(extra.keys.sorted() == ["has_fix", "navigating"])
    #expect(extra["battery_pct"] == nil)
    #expect(extra["speed_mps"] == nil)
}

/// CoreLocation's −1 sentinels and an unknown battery are dropped, not forwarded as real values.
@Test func invalidSentinelsAreDropped() {
    var c = AlertContext()
    c.batteryPct = -1
    c.speedMps = -1
    c.distanceToNextM = .infinity
    let extra = c.extraFields()
    #expect(extra["battery_pct"] == nil)
    #expect(extra["speed_mps"] == nil)
    #expect(extra["distance_to_next_m"] == nil)
}

/// An empty or whitespace-only string is absent, not an empty field.
@Test func blankStringsAreOmitted() {
    var c = AlertContext()
    c.destination = "   "
    c.instruction = ""
    #expect(c.extraFields()["destination"] == nil)
    #expect(c.extraFields()["instruction"] == nil)
}

/// Instructions come from a model upstream and can be any length; the payload stays readable.
@Test func longTextIsTruncated() {
    var c = AlertContext()
    c.instruction = String(repeating: "x", count: AlertContext.maxTextLength + 50)
    guard case .string(let kept)? = c.extraFields()["instruction"] else {
        Issue.record("instruction should be present")
        return
    }
    #expect(kept.count == AlertContext.maxTextLength)
}

/// The prompt carries the facts the model is allowed to use.
@Test func promptCarriesTheFacts() {
    let prompt = AlertContextPrompt.text(eventType: "fall", severity: "critical",
                                         note: "Possible fall detected",
                                         lat: 40.1106, lng: -88.2284, context: filledContext())
    #expect(prompt.contains("event: fall"))
    #expect(prompt.contains("severity: critical"))
    #expect(prompt.contains("detector said: Possible fall detected"))
    #expect(prompt.contains("40.11060, -88.22840"))
    #expect(prompt.contains("destination: CIF"))
    #expect(prompt.contains("phone battery percent: 64"))
    #expect(prompt.contains("metres to next waypoint: 42"))
}

/// ⚠ The bans are the safety contract: no false reassurance, no invented places, no instructions
/// to the family. Removing one of these lines is a product decision, not a copy edit.
@Test func promptBansFalseReassuranceAndInvention() {
    let prompt = AlertContextPrompt.text(eventType: "fall", severity: "critical", note: nil,
                                         lat: nil, lng: nil, context: AlertContext())
    #expect(prompt.contains("never say the person is safe"))
    #expect(prompt.contains("never invent a street"))
    #expect(prompt.contains("never tell the family what to do"))
    #expect(prompt.contains("position: unknown"))
    #expect(prompt.contains("gps fix: no"))
}

/// The reply budget is stated to the model, so a one-line SMS does not arrive as an essay.
@Test func promptStatesTheLengthBudget() {
    let prompt = AlertContextPrompt.text(eventType: "status", severity: nil, note: nil,
                                         lat: nil, lng: nil, context: AlertContext())
    #expect(prompt.contains("at most \(AlertContextPrompt.maxSentences) plain sentences"))
    #expect(prompt.contains("under \(AlertContextPrompt.maxReplyCharacters) characters"))
    #expect(!prompt.contains("severity:"))     // omitted when the caller has none
}

/// Both request dialects are text-only and bounded.
@Test func textRequestBodiesAreWellFormed() throws {
    let openAI = try TextRequest.openAICompatible(model: "muse-spark-1.3-contributor",
                                                  prompt: "hello", reasoningEffort: "low")
    let a = try #require(JSONSerialization.jsonObject(with: openAI) as? [String: Any])
    #expect(a["model"] as? String == "muse-spark-1.3-contributor")
    #expect(a["max_completion_tokens"] as? Int == TextRequest.maxOutputTokens)
    #expect(a["reasoning_effort"] as? String == "low")

    let anthropic = try TextRequest.anthropic(model: "claude-haiku-4-5-20251001", prompt: "hello")
    let b = try #require(JSONSerialization.jsonObject(with: anthropic) as? [String: Any])
    #expect(b["model"] as? String == "claude-haiku-4-5-20251001")
    #expect(b["max_tokens"] as? Int == TextRequest.maxOutputTokens)
    let messages = try #require(b["messages"] as? [[String: Any]])
    #expect(messages.count == 1)
    #expect(messages[0]["role"] as? String == "user")
}

/// ⚠ The budget must cover a REASONING model's thinking, not just its two sentences. At 200 the
/// real Muse endpoint returned `content: null` with `finish_reason: "length"` at both 200 and 1024
/// summary silently never arrived. Do not lower this to "what the answer needs".
@Test func outputBudgetCoversReasoningTokens() {
    #expect(TextRequest.maxOutputTokens >= 4096)
}

/// `reasoning_effort` is omitted (not null) when the provider does not take it — a plain chat
/// model rejects the field outright.
@Test func reasoningEffortIsOmittedWhenNil() throws {
    let data = try TextRequest.openAICompatible(model: "gpt-4o-mini", prompt: "hi")
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(!json.contains("reasoning_effort"))
}
