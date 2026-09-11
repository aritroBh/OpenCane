//
//  VLMCodec.swift
//  CaneKitLogic
//
//  Request bodies and response parsing for the scene-description providers. Pure data in/out;
//  the app owns URLSession, keys and the audio side.
//
//  Purpose: the "Describe" button (watch / Camera Control / UI) sends one JPEG to a vision
//  model and speaks a one-sentence answer. This file builds the JSON body for each provider
//  (Gemini, OpenAI-compatible incl. the `custom` Muse endpoint, Anthropic) and turns each
//  provider's reply — or its error / refusal — into one clean spoken string or a `VLMError`.
//  Also hosts `SpokenDistance`, the shared metres → words phrasing.
//
//  Key invariants:
//    · No networking, no keys, no headers here; headers are noted in comments only.
//    · The prompt is fixed by spec (`ScenePrompt.text`): one sentence, < 20 words, clock-face
//      directions, metres, hazards first.
//    · Parsers never return an empty string: empty → `.emptyResponse(reason)`; undecodable →
//      `.malformed`; provider refusal → `.refused`; non-2xx → `.http` (via `checkStatus`).
//    · Anthropic `max_tokens` 1024 covers thinking + answer (256 starved the answer).
//  Tests: VLMCodecTests.swift (8 tests; shapes only, not provider acceptance).
//

import Foundation

/// Which scene-description backend to call. Raw values are the `VLM_PROVIDER` values accepted
/// in Secrets.plist; with none set the app tries them in declaration order (custom first).
public enum VLMProvider: String, Sendable, Codable, CaseIterable {
    /// Any OpenAI-compatible chat endpoint (Muse 1.3 for this build).
    case custom
    /// Anthropic Messages API (`VLMRequest.anthropic` / `VLMResponse.anthropic`).
    case anthropic
    /// Google Gemini generateContent (`VLMRequest.gemini` / `VLMResponse.gemini`).
    case gemini
    /// OpenAI chat/completions (`VLMRequest.openAICompatible` / `VLMResponse.openAICompatible`).
    case openai
}

/// Why a scene description failed. `errorDescription` is loggable (and short enough to speak).
public enum VLMError: Error, Equatable, LocalizedError {
    /// Non-2xx status and the provider's error message (or the first 200 bytes of the body).
    case http(Int, String)
    /// Decoded fine but no text; the associated reason is the block / finish / stop reason.
    case emptyResponse(String)
    /// The model declined (OpenAI `refusal`, Anthropic `stop_reason == "refusal"`).
    case refused
    /// The body was not the expected JSON; the string names the provider and decoding error.
    case malformed(String)

    /// Human-readable description for logs and the debug UI.
    public var errorDescription: String? {
        switch self {
        case .http(let code, let msg): return "HTTP \(code): \(msg)"
        case .emptyResponse(let why): return "Empty response (\(why))"
        case .refused: return "The model declined to describe the image"
        case .malformed(let why): return "Malformed response: \(why)"
        }
    }
}

/// The fixed prompt (spec). Under 20 words, clock-face directions, metres, hazards first.
public enum ScenePrompt {
    /// The exact prompt sent with every image. Pinned by `geminiRequestCarriesImageAndPrompt`,
    /// `anthropicRequestShape`.
    public static let text = "You are describing a scene to a blind pedestrian. One sentence, under 20 words, use clock-face directions and distances in meters. Mention hazards first."
}

// MARK: - Requests

/// JSON request-body builders, one per provider. Every builder takes the image as base64 JPEG
/// (no data-URI prefix) and returns the encoded body; the app adds URL and headers.
public enum VLMRequest {

    /// Gemini generateContent. Header: x-goog-api-key.
    /// Body: text + inline JPEG, `maxOutputTokens` 120, temperature 0.2, `thinkingBudget` 0
    /// (no thinking: latency matters more than depth for a one-liner).
    /// - Throws: only if `JSONEncoder` fails (never in practice).
    /// Pinned by `geminiRequestCarriesImageAndPrompt`.
    public static func gemini(jpegBase64: String, prompt: String = ScenePrompt.text) throws -> Data {
        struct Body: Encodable {
            struct Part: Encodable { var text: String? = nil; var inlineData: Inline? = nil }
            struct Inline: Encodable { var mimeType: String; var data: String }
            struct Content: Encodable { var role = "user"; var parts: [Part] }
            struct Thinking: Encodable { var thinkingBudget: Int }
            struct Gen: Encodable { var maxOutputTokens: Int; var temperature: Double; var thinkingConfig: Thinking }
            var contents: [Content]
            var generationConfig: Gen
        }
        let body = Body(
            contents: [.init(parts: [.init(text: prompt), .init(inlineData: .init(mimeType: "image/jpeg", data: jpegBase64))])],
            generationConfig: .init(maxOutputTokens: 120, temperature: 0.2, thinkingConfig: .init(thinkingBudget: 0)))
        return try JSONEncoder().encode(body)
    }

    /// OpenAI-compatible chat/completions (OpenAI itself and the `custom` provider).
    /// Body: one user message `[text, image_url(data:image/jpeg;base64,…)]`, `max_tokens` 120,
    /// temperature 0.2.
    /// - Parameter model: model id sent verbatim (e.g. "muse-1.3").
    /// Pinned by `openAIRequestUsesDataURI`.
    public static func openAICompatible(model: String, jpegBase64: String, prompt: String = ScenePrompt.text) throws -> Data {
        struct Body: Encodable {
            struct ImageURL: Encodable { var url: String }
            struct Part: Encodable {
                var type: String
                var text: String? = nil
                var image_url: ImageURL? = nil
            }
            struct Message: Encodable { var role = "user"; var content: [Part] }
            var model: String
            var messages: [Message]
            var max_tokens = 120
            var temperature = 0.2
        }
        let body = Body(model: model, messages: [.init(content: [
            .init(type: "text", text: prompt),
            .init(type: "image_url", image_url: .init(url: "data:image/jpeg;base64,\(jpegBase64)")),
        ])])
        return try JSONEncoder().encode(body)
    }

    /// Anthropic Messages API. Headers: x-api-key, anthropic-version: 2023-06-01.
    /// Body: content `[image (base64 JPEG), text]`, `max_tokens` 1024, `output_config.effort` "low".
    /// - Parameter model: model id sent verbatim (e.g. "claude-opus-5").
    /// Pinned by `anthropicRequestShape`.
    public static func anthropic(model: String, jpegBase64: String, prompt: String = ScenePrompt.text) throws -> Data {
        struct Body: Encodable {
            struct Source: Encodable { var type = "base64"; var media_type = "image/jpeg"; var data: String }
            struct Block: Encodable {
                var type: String
                var source: Source? = nil
                var text: String? = nil
            }
            struct Message: Encodable { var role = "user"; var content: [Block] }
            struct Output: Encodable { var effort: String }
            var model: String
            /// Cap on thinking + text. Opus/Sonnet 5 think by default, so 256 would starve the
            /// answer; 1024 is a ceiling, not a target — the prompt bounds the reply to one sentence.
            var max_tokens = 1024
            var output_config: Output
            var messages: [Message]
        }
        let body = Body(model: model, output_config: .init(effort: "low"), messages: [.init(content: [
            .init(type: "image", source: .init(data: jpegBase64)),
            .init(type: "text", text: prompt),
        ])])
        return try JSONEncoder().encode(body)
    }
}

// MARK: - Responses

/// Response parsers, one per provider, plus the shared status check. Each returns a cleaned,
/// non-empty sentence ready to speak or throws a `VLMError`.
public enum VLMResponse {

    /// The `{"error": {"message", "type"}}` shape OpenAI, Anthropic and Gemini all use.
    private struct ErrorEnvelope: Decodable {
        struct Inner: Decodable { var message: String?; var type: String? }
        var error: Inner
    }

    /// Shared HTTP-status handling: throws `.http` with the provider's message when not 2xx.
    /// - Parameters:
    ///   - status: HTTP status code.
    ///   - data: response body (used for the message; first 200 bytes if not the error envelope).
    /// Pinned by `httpErrorsCarryProviderMessage`.
    public static func checkStatus(_ status: Int, data: Data) throws {
        guard !(200..<300).contains(status) else { return }
        let msg = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
            ?? String(decoding: data.prefix(200), as: UTF8.self)
        throw VLMError.http(status, msg)
    }

    /// Parses a Gemini generateContent reply: joins `candidates[0].content.parts[].text`.
    /// - Throws: `.malformed` if undecodable; `.emptyResponse(blockReason ?? finishReason ?? "no text")`.
    /// Pinned by `geminiResponseParses`.
    public static func gemini(_ data: Data) throws -> String {
        struct R: Decodable {
            struct Part: Decodable { var text: String? }
            struct Content: Decodable { var parts: [Part]? }
            struct Candidate: Decodable { var content: Content?; var finishReason: String? }
            struct Feedback: Decodable { var blockReason: String? }
            var candidates: [Candidate]?
            var promptFeedback: Feedback?
        }
        let r: R
        do { r = try JSONDecoder().decode(R.self, from: data) } catch { throw VLMError.malformed("gemini: \(error)") }
        let text = clean((r.candidates?.first?.content?.parts ?? []).compactMap(\.text).joined(separator: " "))
        guard !text.isEmpty else {
            throw VLMError.emptyResponse(r.promptFeedback?.blockReason ?? r.candidates?.first?.finishReason ?? "no text")
        }
        return text
    }

    /// Parses an OpenAI-compatible chat/completions reply (`content` as string or parts array).
    /// - Throws: `.malformed`; `.emptyResponse("no choices")`; `.refused` on a non-empty
    ///   `refusal`; `.emptyResponse(finish_reason ?? "no content")` when the text is empty.
    /// Pinned by `openAIResponseParsesStringAndPartsAndRefusal`.
    public static func openAICompatible(_ data: Data) throws -> String {
        struct R: Decodable {
            struct Message: Decodable {
                var content: ContentValue?
                var refusal: String?
            }
            struct Choice: Decodable { var message: Message?; var finish_reason: String? }
            var choices: [Choice]?
        }
        let r: R
        do { r = try JSONDecoder().decode(R.self, from: data) } catch { throw VLMError.malformed("openai: \(error)") }
        guard let msg = r.choices?.first?.message else { throw VLMError.emptyResponse("no choices") }
        if let refusal = msg.refusal, !refusal.isEmpty { throw VLMError.refused }
        let text = clean(msg.content?.text ?? "")
        guard !text.isEmpty else { throw VLMError.emptyResponse(r.choices?.first?.finish_reason ?? "no content") }
        return text
    }

    /// Parses an Anthropic Messages reply: joins the `text` blocks (thinking blocks ignored).
    /// - Throws: `.malformed`; `.refused` when `stop_reason == "refusal"`;
    ///   `.emptyResponse(stop_reason ?? "no text")` when no text survived.
    /// Pinned by `anthropicResponseParsesAndDetectsRefusal`.
    public static func anthropic(_ data: Data) throws -> String {
        struct R: Decodable {
            struct Block: Decodable { var type: String; var text: String? }
            var content: [Block]?
            var stop_reason: String?
        }
        let r: R
        do { r = try JSONDecoder().decode(R.self, from: data) } catch { throw VLMError.malformed("anthropic: \(error)") }
        if r.stop_reason == "refusal" { throw VLMError.refused }
        let text = clean((r.content ?? []).filter { $0.type == "text" }.compactMap(\.text).joined(separator: " "))
        guard !text.isEmpty else {
            // "max_tokens" with no text means thinking consumed the whole budget.
            throw VLMError.emptyResponse(r.stop_reason ?? "no text")
        }
        return text
    }

    /// Collapse whitespace; drop surrounding quotes some models add.
    /// Pinned by `geminiResponseParses`, `openAIResponseParsesStringAndPartsAndRefusal`.
    static func clean(_ s: String) -> String {
        var t = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count > 1 { t = String(t.dropFirst().dropLast()) }
        return t
    }

    /// OpenAI `content` is either a string or an array of {type, text} parts.
    struct ContentValue: Decodable {
        /// The string content, or the parts' texts joined with single spaces.
        var text: String
        /// Tries a plain string first, then an array of parts.
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                text = s
                return
            }
            struct Part: Decodable { var type: String?; var text: String? }
            let parts = try c.decode([Part].self)
            text = parts.compactMap(\.text).joined(separator: " ")
        }
    }
}

// MARK: - Spoken distances (shared with obstacle names)

/// Metres → natural spoken words, rounded to the nearest half metre. Used by
/// `CueSpeechPolicy` ("Ahead, …"), the app's `ObstacleNamer` and the debug grid's labels.
public enum SpokenDistance {
    /// "very close", "half a meter", "one meter", "one and a half meters", "two meters", "3 meters"…
    /// - Parameter meters: distance in metres.
    /// - Returns: the phrase; "" for a non-finite distance. Pinned by `spokenDistances`.
    public static func phrase(_ meters: Float) -> String {
        guard meters.isFinite else { return "" }
        let half = (meters * 2).rounded() / 2
        if half < 0.5 { return "very close" }
        if half == 0.5 { return "half a meter" }
        if half == 1 { return "one meter" }
        if half == 1.5 { return "one and a half meters" }
        if half == 2 { return "two meters" }
        if half == half.rounded() { return "\(Int(half)) meters" }
        return String(format: "%.1f meters", half)
    }
}
