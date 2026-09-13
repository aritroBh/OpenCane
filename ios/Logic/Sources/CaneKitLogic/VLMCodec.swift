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
//    · The prompt is fixed (`ScenePrompt.text`): one sentence, < 20 words, hazards first, left /
//      center / right, and no numbers — the LiDAR fact supplies the only distance a walker hears.
//    · Parsers never return an empty string: empty → `.emptyResponse(reason)`; undecodable →
//      `.malformed`; provider refusal → `.refused`; non-2xx → `.http` (via `checkStatus`).
//    · Anthropic `max_tokens` 1024 covers thinking + answer (256 starved the answer); the
//      OpenAI-compatible path uses the same 1024 (`openAIMaxTokens`) because Muse Spark's reasoning
//      tokens count against it too.
//    · Every reply is still untrusted: `CloudSceneGate` (and `SceneVocabulary` on-device) decide
//      whether a parsed sentence may be spoken. This file only guarantees "non-empty or thrown".
//
//  Callers: `VLMClient.swift` (app) — the provider clients build bodies with `VLMRequest.*`, post
//  through `post(_:headers:body:)` which calls `VLMResponse.checkStatus`, then parse with
//  `VLMResponse.*`; `VLMClientFactory` resolves `VLMProvider` from Secrets. "Where am I" passes
//  `ScenePrompt.text`, the hazard watch `HazardPrompt.text`, "Ask OpenCane" `QuestionPrompt.text(for:)`.
//  `SpokenDistance` is used by `CueSpeechPolicy`, `ObstacleNamer`, `SpokenPhrases`,
//  `GroundHazard.spokenLine`, `PeopleAhead`, `AppModel.contextLine` and `LaneGridView`.
//  Isolation: stateless and nonisolated; the providers call it from their own async tasks.
//  Tests: VLMCodecTests.swift (11 tests; shapes only, not provider acceptance).
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
/// The app's `FallbackVLMClient` treats every case (any error but cancellation) as "try on-device
/// instead"; the "Ask OpenCane" path calls the cloud client directly and has no fallback.
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

/// The fixed prompt. One sentence, under 20 words, hazards first, sides not clock faces, and no
/// numbers at all — the app supplies the distance from LiDAR.
public enum ScenePrompt {
    /// The exact prompt sent with every image. Pinned by `geminiRequestCarriesImageAndPrompt`,
    /// `anthropicRequestShape`, `scenePromptAsksForSidesNotNumbers`.
    ///
    /// It used to ask for "clock-face directions and distances in meters". Both were measured
    /// mistakes:
    ///   · clock face — VLMs read the clock off the image frame, not the walker's body (GuideDog,
    ///     ACL 2026), so "10 o'clock" points somewhere the walker is not facing. Left / center /
    ///     right survives a rotated cane mount;
    ///   · metres — the same benchmark has small VLMs judging distance BELOW chance (22.2 % against
    ///     a 25 % baseline) while naming objects at 80–87 %, and counting is the worst measured
    ///     task of all (52.7 % for Gemini 3.5 Flash-Lite). Asking for a number asks the model to
    ///     invent the one thing it is worst at, so the prompt forbids numbers entirely and
    ///     `SceneDescriber` puts the measured LiDAR distance in front of the sentence, exactly as
    ///     `OnDeviceVLMClient` does.
    /// The "clear, empty or safe" line exists because a solid white frame produced "The path ahead
    /// is clear and unobstructed" 4 times out of 4. The last sentence (Step 49) gives a model
    /// looking at a black frame a way to say so — `CloudSceneGate.tooDark` — instead of inventing
    /// a scene; `SceneDescriber` speaks it as the answer. `CloudSceneGate` enforces all of this on
    /// the reply; the prompt is what makes enforcement rare. ⚠ Under 400 characters
    /// (`scenePromptAsksForSidesNotNumbers`): it rides on every request.
    public static let text = "You are describing what a cane-mounted camera sees, for a blind pedestrian. One sentence, under 20 words. Name what is actually there, hazards first, and say whether each thing is on the left, in the center or on the right. Never give a number, a distance or a count. Never say the way is clear, empty or safe. No preamble. If it is too dark to see, answer exactly: It is too dark to see."
}

// MARK: - Requests

/// JSON request-body builders, one per provider. Every builder takes the image as base64 JPEG
/// (no data-URI prefix) and returns the encoded body; the app adds URL and headers.
public enum VLMRequest {

    /// Gemini generateContent. Header: x-goog-api-key.
    /// Body: text + inline JPEG, `maxOutputTokens` 120, temperature 0.2, `thinkingBudget` 0
    /// (no thinking: latency matters more than depth for a one-liner).
    /// - Parameters:
    ///   - jpegBase64: the frame as base64 JPEG, no data-URI prefix.
    ///   - prompt: the instruction text (default "Where am I").
    /// - Throws: only if `JSONEncoder` fails (never in practice).
    /// Pinned by `geminiRequestCarriesImageAndPrompt`.
    public static func gemini(jpegBase64: String, prompt: String = ScenePrompt.text) throws -> Data {
        // Wire shape (camelCase is Gemini's own REST naming): `contents[0]` is one user turn whose
        // `parts` are the text then `inlineData{mimeType, data}`; `generationConfig` carries
        // `maxOutputTokens`, `temperature` and `thinkingConfig.thinkingBudget`. A part leaves its
        // unused optional nil so the encoder omits it (a part is text XOR inline data).
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

    /// Output-token budget for a *reasoning* model on the OpenAI-compatible path.
    ///
    /// 1024, not the 120 a one-sentence answer needs, because on this endpoint `max_tokens` caps
    /// **reasoning plus visible output together**. Measured on the phone: Muse Spark 1.3 with
    /// `max_tokens` 120 spent the whole budget thinking and returned `finish_reason: "length"` with
    /// `content: null`, which the app could only read as a failure — so it waited 11 s and then
    /// spoke the on-device template instead. The walker heard nothing the cloud model saw. 1024 is
    /// the same figure the Anthropic path already uses for the same reason (see the file header).
    public static let openAIMaxTokens = 1024

    /// Reasoning depth asked of a reasoning model for scene description: the lowest the endpoint
    /// allows.
    ///
    /// Naming what a camera sees is a direct-answer task, and Meta's own guidance is to use "low"
    /// for those — higher effort buys nothing here and costs the one thing a blind walker cannot
    /// spare, latency. `"none"` is documented to return HTTP 400 on Muse Spark, so "low" is the
    /// floor, not a compromise.
    public static let lowReasoningEffort = "low"

    /// OpenAI-compatible chat/completions (OpenAI itself and the `custom` provider).
    /// Body: one user message `[text, image_url(data:image/jpeg;base64,…)]`,
    /// `max_tokens` `openAIMaxTokens`, temperature 0.2.
    /// - Parameters:
    ///   - model: model id sent verbatim (e.g. "muse-spark-1.3-contributor").
    ///   - jpegBase64: the frame as base64 JPEG (wrapped here in a `data:image/jpeg;base64,` URI).
    ///   - prompt: the instruction text.
    ///   - reasoningEffort: value for the top-level `reasoning_effort` field, or nil to omit it.
    ///     Omitted by default because a plain OpenAI chat model rejects the field outright; the
    ///     `custom` provider passes `lowReasoningEffort` because Muse Spark always reasons and, left
    ///     to itself, reasons for longer than a walking pace allows.
    /// Pinned by `openAIRequestUsesDataURI`, `openAIRequestBudgetsForReasoningTokens`,
    /// `openAIRequestOmitsReasoningEffortUnlessAsked`.
    public static func openAICompatible(model: String, jpegBase64: String,
                                        prompt: String = ScenePrompt.text,
                                        reasoningEffort: String? = nil) throws -> Data {
        // Wire shape (snake_case property names are the API's own keys, hence no CodingKeys):
        // `model`, one user `messages[0]` whose `content` parts are `{type:"text", text}` and
        // `{type:"image_url", image_url:{url:"data:image/jpeg;base64,…"}}`, then `max_tokens`,
        // `temperature` and the optional top-level `reasoning_effort`.
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
            // Qualified: a nested struct cannot default a property from the enclosing scope.
            var max_tokens = VLMRequest.openAIMaxTokens
            var temperature = 0.2
            /// nil is encoded as absent, not null: an endpoint that does not know the field must
            /// not see it at all.
            var reasoning_effort: String?
        }
        let body = Body(model: model, messages: [.init(content: [
            .init(type: "text", text: prompt),
            .init(type: "image_url", image_url: .init(url: "data:image/jpeg;base64,\(jpegBase64)")),
        ])], reasoning_effort: reasoningEffort)
        return try JSONEncoder().encode(body)
    }

    /// Anthropic Messages API. Headers: x-api-key, anthropic-version: 2023-06-01.
    /// Body: content `[image (base64 JPEG), text]`, `max_tokens` 1024, `output_config.effort` "low".
    /// - Parameters:
    ///   - model: model id sent verbatim (e.g. "claude-opus-5").
    ///   - jpegBase64: the frame as base64 JPEG, no data-URI prefix.
    ///   - prompt: the instruction text.
    /// - Throws: only if `JSONEncoder` fails (never in practice).
    /// Pinned by `anthropicRequestShape`.
    public static func anthropic(model: String, jpegBase64: String, prompt: String = ScenePrompt.text) throws -> Data {
        // Wire shape: `model`, `max_tokens`, `output_config{effort}`, and one user message whose
        // `content` blocks are the image first (`{type:"image", source:{type:"base64",
        // media_type:"image/jpeg", data}}`) then `{type:"text", text}` — image before text, as the
        // Messages API recommends and `anthropicRequestShape` pins.
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
        /// The inner error object; only `message` is used (`type` is decoded for completeness).
        struct Inner: Decodable { var message: String?; var type: String? }
        /// The `error` member; a body without it fails to decode and `checkStatus` falls back to raw bytes.
        var error: Inner
    }

    /// Shared HTTP-status handling: throws `.http` with the provider's message when not 2xx.
    /// Called first by `post(_:headers:body:)` in the app's VLMClient.swift, before any parser.
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
        // Only the fields read are declared, all optional, so an extra or missing field never
        // throws: `candidates[].content.parts[].text`, `candidates[].finishReason`,
        // `promptFeedback.blockReason` (set when the prompt itself was blocked, e.g. "SAFETY").
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
        // Only `choices[0].message.content` (string or parts — `ContentValue`), `.refusal` and
        // `choices[0].finish_reason` are read; "length" there with no content means a reasoning
        // model spent `max_tokens` thinking (why `openAIMaxTokens` is 1024).
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
        // Only `content[].type` / `.text` and `stop_reason` are read; thinking blocks carry no
        // `text` and are filtered out by `type == "text"`.
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
    /// Every whitespace run (newlines included) becomes one space and the ends are trimmed; one
    /// pair of surrounding straight double quotes is removed (a lone `"` is left alone).
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
/// `CueSpeechPolicy` ("One meter ahead."), the app's `ObstacleNamer` ("One meter ahead, door"),
/// `GroundHazard.spokenLine` ("Two meters ahead, drop-off."), `PeopleAhead` ("About 3 meters
/// ahead, two people."), `AppModel.contextLine`, `SpokenPhrases` (which enumerates the buckets for
/// the voice prefetch) and the lane grid's accessibility labels.
/// ⚠ Changing a phrase changes every cached natural-voice warning line: the new wording misses the
/// mp3 cache until it is re-synthesized (`SpokenPhrases.warningLines`).
public enum SpokenDistance {
    /// "One meter", "Two meters", "Half a meter" — `phrase` with its first letter upper-cased,
    /// for the distance-first warning lines ("Two meters ahead, door."). `.capitalized` is wrong
    /// here: it title-cases every word ("One And A Half Meters"). Empty stays empty.
    /// - Parameter phrase: a `phrase(_:)` result.
    /// - Returns: the same words with the first character upper-cased.
    public static func leadingCapitalized(_ phrase: String) -> String {
        guard let first = phrase.first else { return phrase }
        return String(first).uppercased() + phrase.dropFirst()
    }

    /// "very close", "half a meter", "one meter", "one and a half meters", "two meters", "3 meters"…
    /// Rounds `meters × 2` half-away-from-zero, then: < 0.5 → "very close" (negative too); 0.5, 1,
    /// 1.5, 2 → words; any other whole number → digits ("3 meters"); otherwise one decimal
    /// ("2.5 meters"). `SpokenPhrases.bucketSamples` sweeps this function rather than assuming the
    /// buckets, so a change here re-shapes the prefetch set by itself (and must stay inside
    /// `SpokenPhrases.warningCharacterBudget`).
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
