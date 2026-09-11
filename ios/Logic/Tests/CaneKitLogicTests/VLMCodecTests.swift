import Foundation
import Testing
@testable import CaneKitLogic

private func json(_ s: String) -> Data { Data(s.utf8) }

// MARK: Requests

@Test func geminiRequestCarriesImageAndPrompt() throws {
    let body = try VLMRequest.gemini(jpegBase64: "AAAA")
    let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    let contents = obj["contents"] as! [[String: Any]]
    let parts = contents[0]["parts"] as! [[String: Any]]
    #expect(parts[0]["text"] as? String == ScenePrompt.text)
    let inline = parts[1]["inlineData"] as! [String: Any]
    #expect(inline["mimeType"] as? String == "image/jpeg")
    #expect(inline["data"] as? String == "AAAA")
    let gen = obj["generationConfig"] as! [String: Any]
    #expect((gen["thinkingConfig"] as! [String: Any])["thinkingBudget"] as? Int == 0)
}

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

@Test func anthropicRequestShape() throws {
    let body = try VLMRequest.anthropic(model: "claude-opus-5", jpegBase64: "CCCC")
    let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    #expect(obj["model"] as? String == "claude-opus-5")
    #expect(obj["max_tokens"] as? Int == 1024)     // cap covers thinking + one sentence
    let blocks = ((obj["messages"] as! [[String: Any]])[0]["content"] as! [[String: Any]])
    #expect(blocks[0]["type"] as? String == "image")
    #expect(((blocks[0]["source"] as! [String: Any])["media_type"] as? String) == "image/jpeg")
    #expect(blocks[1]["text"] as? String == ScenePrompt.text)
}

// MARK: Responses

@Test func geminiResponseParses() throws {
    let ok = json(#"{"candidates":[{"content":{"parts":[{"text":" Bike rack at 10 o'clock, "},{"text":"two meters. "}]},"finishReason":"STOP"}]}"#)
    #expect(try VLMResponse.gemini(ok) == "Bike rack at 10 o'clock, two meters.")
    let blocked = json(#"{"candidates":[],"promptFeedback":{"blockReason":"SAFETY"}}"#)
    #expect(throws: VLMError.emptyResponse("SAFETY")) { try VLMResponse.gemini(blocked) }
    #expect(throws: (any Error).self) { try VLMResponse.gemini(json("nope")) }
}

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

@Test func anthropicResponseParsesAndDetectsRefusal() throws {
    let ok = json(#"{"content":[{"type":"text","text":"Pole at 1 o'clock, two meters."}],"stop_reason":"end_turn"}"#)
    #expect(try VLMResponse.anthropic(ok) == "Pole at 1 o'clock, two meters.")
    let refused = json(#"{"content":[],"stop_reason":"refusal"}"#)
    #expect(throws: VLMError.refused) { try VLMResponse.anthropic(refused) }
}

@Test func httpErrorsCarryProviderMessage() {
    let body = json(#"{"error":{"message":"API key not valid","type":"invalid_request_error"}}"#)
    #expect(throws: VLMError.http(400, "API key not valid")) { try VLMResponse.checkStatus(400, data: body) }
    #expect(throws: VLMError.http(500, "boom")) { try VLMResponse.checkStatus(500, data: json("boom")) }
    #expect(throws: Never.self) { try VLMResponse.checkStatus(200, data: Data()) }
}

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
