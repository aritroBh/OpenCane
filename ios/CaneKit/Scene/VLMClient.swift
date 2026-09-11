//
//  VLMClient.swift
//  CaneKit
//
//  Pluggable vision-language providers for "Where am I". Request bodies and response parsing
//  live in CaneKitLogic (VLMRequest / VLMResponse, unit-tested); this file is only transport
//  and key plumbing. Provider order when `VLM_PROVIDER` is empty: custom (Muse) → Anthropic →
//  Gemini → OpenAI, whichever has a key.
//

import CaneKitLogic
import Foundation

nonisolated protocol VLMClient: Sendable {
    var name: String { get }
    func describe(jpeg: Data) async throws -> String
}

nonisolated enum VLMClientFactory {

    /// The configured provider, or nil when no key is present.
    static func fromSecrets() -> (any VLMClient)? {
        let requested = Secrets.string("VLM_PROVIDER").flatMap(VLMProvider.init(rawValue:))
        let order: [VLMProvider] = requested.map { [$0] } ?? [.custom, .anthropic, .gemini, .openai]
        for provider in order {
            if let client = make(provider) { return client }
        }
        // A requested provider without a key: try the others rather than fail silently.
        if requested != nil {
            for provider in VLMProvider.allCases where provider != requested {
                if let client = make(provider) { return client }
            }
        }
        return nil
    }

    private static func make(_ provider: VLMProvider) -> (any VLMClient)? {
        switch provider {
        case .custom:
            guard let base = Secrets.string("CUSTOM_BASE_URL"), let key = Secrets.string("CUSTOM_API_KEY") else { return nil }
            return OpenAICompatibleClient(name: "Muse", baseURL: base, apiKey: key,
                                          model: Secrets.string("CUSTOM_MODEL") ?? "muse-1.3")
        case .openai:
            guard let key = Secrets.string("OPENAI_API_KEY") else { return nil }
            return OpenAICompatibleClient(name: "OpenAI", baseURL: "https://api.openai.com/v1", apiKey: key,
                                          model: Secrets.string("OPENAI_MODEL") ?? "gpt-4o-mini")
        case .anthropic:
            guard let key = Secrets.string("ANTHROPIC_API_KEY") else { return nil }
            return AnthropicClient(apiKey: key, model: Secrets.string("ANTHROPIC_MODEL") ?? "claude-opus-5")
        case .gemini:
            guard let key = Secrets.string("GEMINI_API_KEY") else { return nil }
            return GeminiClient(apiKey: key, model: Secrets.string("GEMINI_MODEL") ?? "gemini-2.5-flash")
        }
    }
}

// MARK: - Shared transport

/// One session for all providers: waits briefly for connectivity (lock-screen cold start on
/// Wi-Fi) and caps the whole request at 20 s.
nonisolated private let vlmSession: URLSession = {
    let c = URLSessionConfiguration.default
    c.waitsForConnectivity = true
    c.timeoutIntervalForRequest = 20
    c.timeoutIntervalForResource = 20
    return URLSession(configuration: c)
}()

nonisolated private func post(_ url: URL, headers: [String: String], body: Data) async throws -> Data {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
    request.httpBody = body
    let (data, response) = try await vlmSession.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw VLMError.malformed("no HTTP response") }
    try VLMResponse.checkStatus(http.statusCode, data: data)
    return data
}

// MARK: - Providers

/// OpenAI's chat/completions and anything that speaks the same dialect (Muse 1.3 for this build).
nonisolated struct OpenAICompatibleClient: VLMClient {
    let name: String
    let baseURL: String
    let apiKey: String
    let model: String

    func describe(jpeg: Data) async throws -> String {
        // Accept "https://host/v1", "https://host/v1/", or a full ".../chat/completions".
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/chat/completions") { base += "/chat/completions" }
        guard let url = URL(string: base), url.scheme != nil else { throw VLMError.malformed("bad base URL") }
        let body = try VLMRequest.openAICompatible(model: model, jpegBase64: jpeg.base64EncodedString())
        let data = try await post(url, headers: ["Authorization": "Bearer \(apiKey)"], body: body)
        return try VLMResponse.openAICompatible(data)
    }
}

nonisolated struct AnthropicClient: VLMClient {
    let name = "Anthropic"
    let apiKey: String
    let model: String

    func describe(jpeg: Data) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        let body = try VLMRequest.anthropic(model: model, jpegBase64: jpeg.base64EncodedString())
        let data = try await post(url, headers: ["x-api-key": apiKey, "anthropic-version": "2023-06-01"], body: body)
        return try VLMResponse.anthropic(data)
    }
}

nonisolated struct GeminiClient: VLMClient {
    let name = "Gemini"
    let apiKey: String
    let model: String

    func describe(jpeg: Data) async throws -> String {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        let body = try VLMRequest.gemini(jpegBase64: jpeg.base64EncodedString())
        let data = try await post(url, headers: ["x-goog-api-key": apiKey], body: body)
        return try VLMResponse.gemini(data)
    }
}
