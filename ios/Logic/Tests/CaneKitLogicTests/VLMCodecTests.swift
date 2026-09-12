//
//  VLMCodecTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins VLMCodec.swift — the JSON request shapes for Gemini, OpenAI-compatible (Muse)
//  and Anthropic, each provider's response parsing (joining, quote / whitespace cleaning,
//  refusals, empty and malformed bodies), HTTP error messages, and `SpokenDistance` phrasing.
//
//  Key invariants: shapes only — these tests do not prove a provider accepts the body; that
//  needs one live "Describe" per provider on the phone.
//
//  Also pins `ScenePrompt.text` (the fixed "Where am I" prompt: sides, hazards first, never a
//  number, never "clear", < 400 characters) and the OpenAI-compatible reasoning budget
//  (`VLMRequest.openAIMaxTokens` ≥ 1024, `reasoning_effort` only when passed, "low" not "none").
//  Caller: `VLMClient` (app) builds every request and parses every response here; `SpokenDistance`
//  is shared by the obstacle / ground-hazard / people lines. Breaks these catch: a prompt that asks
//  the model for metres or clock directions (its worst tasks), a reasoning model spending its whole
//  token budget and returning no sentence (measured on Muse Spark 1.3), a field a plain chat model
//  rejects, a refusal or safety block spoken as an answer, and a raw decimal distance.
//

import Foundation
import Testing
@testable import CaneKitLogic

/// UTF-8 `Data` from a JSON literal, for the response-parser fixtures.
private func json(_ s: String) -> Data { Data(s.utf8) }

// MARK: Requests

/// The prompt asks for what VLMs measure well (naming, side) and forbids what they do not.
/// GuideDog (ACL 2026) measured distance judgement BELOW chance (22.2 % vs a 25 % baseline) and
/// clock directions read off the image frame rather than the walker's body; counting is worse
/// still (52.7 %). The distance a walker hears comes from LiDAR, never from the model.
@Test func scenePromptAsksForSidesNotNumbers() {
    let p = ScenePrompt.text.lowercased()
    #expect(p.contains("left"), "the prompt must ask for a side")
    #expect(p.contains("center") && p.contains("right"))
    #expect(!p.contains("clock"), "clock-face directions are read from the image frame, not the walker")
    #expect(!p.contains("meter"), "asking for metres asks the model to invent its worst task")
    #expect(p.contains("never give a number"))
    #expect(p.contains("hazards first"))
    #expect(p.contains("never say the way is clear"))
    #expect(ScenePrompt.text.count < 400)   // it rides on every request
}

/// Describe via Gemini sends the fixed prompt plus the JPEG, with thinking off for latency.
@Test func geminiRequestCarriesImageAndPrompt() throws {
    let body = try VLMRequest.gemini(jpegBase64: "AAAA")
    let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    let contents = obj["contents"] as! [[String: Any]]
    let parts = contents[0]["parts"] as! [[String: Any]]
    #expect(parts[0]["text"] as? String == ScenePrompt.text)   // content: scenePromptAsksForSidesNotNumbers
    let inline = parts[1]["inlineData"] as! [String: Any]
    #expect(inline["mimeType"] as? String == "image/jpeg")
    #expect(inline["data"] as? String == "AAAA")
    let gen = obj["generationConfig"] as! [String: Any]
    #expect((gen["thinkingConfig"] as! [String: Any])["thinkingBudget"] as? Int == 0)
}

/// Describe via Muse / OpenAI sends the JPEG as a data URI in a user message.
@Test func openAIRequestUsesDataURI() throws {
    let body = try VLMRequest.openAICompatible(model: "muse-1.3", jpegBase64: "BBBB")
    let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    #expect(obj["model"] as? String == "muse-1.3")
    let msg = (obj["messages"] as! [[String: Any]])[0]
    #expect(msg["role"] as? String == "user")
    let content = msg["content"] as! [[String: Any]]
    #expect(content[0]["type"] as? String == "text")
    #expect((content[1]["image_url"] as! [String: Any])["url"] as? String == "data:image/jpeg;base64,BBBB")
}

/// A reasoning model's thinking must not eat the sentence.
///
/// Measured on the phone: with `max_tokens` 120, Muse Spark 1.3 spent the whole budget reasoning and
/// returned `finish_reason: "length"` with `content: null`. The app could only read that as a
/// failure, so it waited 11 s and spoke the on-device template — the walker never heard what the
/// model saw. On this endpoint `max_tokens` caps reasoning *plus* visible output.
@Test func openAIRequestBudgetsForReasoningTokens() throws {
    let body = try VLMRequest.openAICompatible(model: "muse-spark-1.3-contributor", jpegBase64: "BBBB")
    let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    #expect(obj["max_tokens"] as? Int == VLMRequest.openAIMaxTokens)
    // One sentence needs ~30 tokens; the rest is headroom for the private chain of thought.
    #expect(VLMRequest.openAIMaxTokens >= 1024)
}

/// `reasoning_effort` is sent only when asked for, and asks for the shallowest depth allowed.
///
/// A plain (non-reasoning) chat model rejects the field outright, so it must be absent unless a
/// caller opts in — nil has to encode as *missing*, not as null. "none" is documented to return
/// HTTP 400 on Muse Spark, so "low" is the floor; naming what a camera sees is a direct-answer task
/// and deeper reasoning buys only latency a walking pace cannot spare.
@Test func openAIRequestOmitsReasoningEffortUnlessAsked() throws {
    let plain = try JSONSerialization.jsonObject(
        with: try VLMRequest.openAICompatible(model: "gpt-4o-mini", jpegBase64: "BBBB")) as! [String: Any]
    #expect(plain.keys.contains("reasoning_effort") == false)

    let muse = try JSONSerialization.jsonObject(
        with: try VLMRequest.openAICompatible(model: "muse-spark-1.3-contributor", jpegBase64: "BBBB",
                                              reasoningEffort: VLMRequest.lowReasoningEffort)) as! [String: Any]
    #expect(muse["reasoning_effort"] as? String == "low")
    #expect(VLMRequest.lowReasoningEffort != "none")   // documented HTTP 400 on Muse Spark
}

/// Describe via Anthropic sends image then prompt with a 1024-token cap so thinking cannot starve the answer.
@Test func anthropicRequestShape() throws {
    let body = try VLMRequest.anthropic(model: "claude-opus-5", jpegBase64: "CCCC")
    let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    #expect(obj["model"] as? String == "claude-opus-5")
    #expect(obj["max_tokens"] as? Int == 1024)     // cap covers thinking + one sentence
    let blocks = ((obj["messages"] as! [[String: Any]])[0]["content"] as! [[String: Any]])
    #expect(blocks[0]["type"] as? String == "image")
    #expect(((blocks[0]["source"] as! [String: Any])["media_type"] as? String) == "image/jpeg")
    #expect(blocks[1]["text"] as? String == ScenePrompt.text)   // content: scenePromptAsksForSidesNotNumbers
}

// MARK: Responses

/// Gemini's split answer is joined and cleaned; a safety block becomes a speakable empty-response error.
@Test func geminiResponseParses() throws {
    let ok = json(#"{"candidates":[{"content":{"parts":[{"text":" Bike rack at 10 o'clock, "},{"text":"two meters. "}]},"finishReason":"STOP"}]}"#)
    #expect(try VLMResponse.gemini(ok) == "Bike rack at 10 o'clock, two meters.")
    let blocked = json(#"{"candidates":[],"promptFeedback":{"blockReason":"SAFETY"}}"#)
    #expect(throws: VLMError.emptyResponse("SAFETY")) { try VLMResponse.gemini(blocked) }
    #expect(throws: (any Error).self) { try VLMResponse.gemini(json("nope")) }
}

/// OpenAI-style answers parse as string or parts; quotes are stripped; refusals and no choices are errors.
@Test func openAIResponseParsesStringAndPartsAndRefusal() throws {
    let str = json(#"{"choices":[{"message":{"role":"assistant","content":"\"Door ahead, one meter.\""},"finish_reason":"stop"}]}"#)
    #expect(try VLMResponse.openAICompatible(str) == "Door ahead, one meter.")
    let parts = json(#"{"choices":[{"message":{"content":[{"type":"text","text":"Curb at 12 o'clock,"},{"type":"text","text":"one meter."}]}}]}"#)
    #expect(try VLMResponse.openAICompatible(parts) == "Curb at 12 o'clock, one meter.")
    let refusal = json(#"{"choices":[{"message":{"content":null,"refusal":"I can't help with that."}}]}"#)
    #expect(throws: VLMError.refused) { try VLMResponse.openAICompatible(refusal) }
    let empty = json(#"{"choices":[]}"#)
    #expect(throws: VLMError.emptyResponse("no choices")) { try VLMResponse.openAICompatible(empty) }
}

/// Anthropic text blocks are spoken; a refusal stop reason becomes `.refused`.
@Test func anthropicResponseParsesAndDetectsRefusal() throws {
    let ok = json(#"{"content":[{"type":"text","text":"Pole at 1 o'clock, two meters."}],"stop_reason":"end_turn"}"#)
    #expect(try VLMResponse.anthropic(ok) == "Pole at 1 o'clock, two meters.")
    let refused = json(#"{"content":[],"stop_reason":"refusal"}"#)
    #expect(throws: VLMError.refused) { try VLMResponse.anthropic(refused) }
}

/// A bad key or server error surfaces the provider's message instead of a generic failure.
@Test func httpErrorsCarryProviderMessage() {
    let body = json(#"{"error":{"message":"API key not valid","type":"invalid_request_error"}}"#)
    #expect(throws: VLMError.http(400, "API key not valid")) { try VLMResponse.checkStatus(400, data: body) }
    #expect(throws: VLMError.http(500, "boom")) { try VLMResponse.checkStatus(500, data: json("boom")) }
    #expect(throws: Never.self) { try VLMResponse.checkStatus(200, data: Data()) }
}

/// Distances are spoken as natural half-metre phrases ("one and a half meters"), never raw decimals.
@Test func spokenDistances() {
    #expect(SpokenDistance.phrase(0.2) == "very close")
    #expect(SpokenDistance.phrase(0.6) == "half a meter")
    #expect(SpokenDistance.phrase(1.1) == "one meter")
    #expect(SpokenDistance.phrase(1.6) == "one and a half meters")
    #expect(SpokenDistance.phrase(2.2) == "two meters")
    #expect(SpokenDistance.phrase(3.0) == "3 meters")
    #expect(SpokenDistance.phrase(3.4) == "3.5 meters")
    #expect(SpokenDistance.phrase(.infinity) == "")
}
