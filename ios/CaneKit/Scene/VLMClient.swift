//
//  VLMClient.swift
//  CaneKit
//
//  Pluggable vision-language providers for "Where am I". Request bodies and response parsing
//  live in CaneKitLogic (VLMRequest / VLMResponse, unit-tested); this file is only transport
//  and key plumbing. Provider order when `VLM_PROVIDER` is empty: custom (Muse) → Anthropic →
//  Gemini → OpenAI, whichever has a key.
//
//  Threading / isolation: everything here is `nonisolated` and Sendable (immutable structs,
//  a shared `URLSession`), so a client can be held by the main-actor `SceneDescriber` and
//  awaited from it. With NonisolatedNonsendingByDefault (ios/project.yml) `describe(jpeg:)` runs
//  on the caller's executor — main, for SceneDescriber: URL/body building and base64 happen
//  there, the URLSession await suspends, and parsing resumes there. None of it blocks main for
//  long; the heavy JPEG encode happens earlier, off main.
//
//  Keys (hard rule 4): read from Secrets.plist only, sent only as request headers to the
//  provider's own host, never logged. Error text surfaced to the UI comes from CaneKitLogic's
//  `VLMResponse.checkStatus` / `VLMError`, not from request headers.
//

import CaneKitLogic
import Foundation

/// A vision-language provider that turns one JPEG into one short spoken sentence.
nonisolated protocol VLMClient: Sendable {
    /// Display name for the UI ("Muse", "Anthropic", "Gemini", "OpenAI", "On-device").
    var name: String { get }
    /// One image + a prompt → text. `prompt` is `ScenePrompt.text` for "Where am I" and
    /// `HazardPrompt.text` for the hazard watch. Throws `VLMError` (HTTP status, malformed body)
    /// or `URLError` (transport, 8 s request / 12 s total timeout).
    func describe(jpeg: Data, prompt: String) async throws -> String
}

nonisolated extension VLMClient {
    /// "Where am I": the scene prompt. Caller: `SceneDescriber.describe()`.
    func describe(jpeg: Data) async throws -> String {
        try await describe(jpeg: jpeg, prompt: ScenePrompt.text)
    }
}

/// Cloud first, on-device when the cloud fails (no network, bad key, quota, timeout) — so
/// "Where am I" and the hazard watch always answer something.
nonisolated struct FallbackVLMClient: VLMClient {
    let primary: any VLMClient
    let fallback: any VLMClient
    var name: String { "\(primary.name) + \(fallback.name)" }

    /// The hazard watch cannot wait for the cloud's full 8–12 s timeout: a reply that late is about
    /// a place the walker has left. For `HazardPrompt.text` the cloud gets this long, then the
    /// on-device client answers instead (review round 5).
    var hazardDeadline: Duration = .seconds(2.5)

    func describe(jpeg: Data, prompt: String) async throws -> String {
        if prompt == HazardPrompt.text {
            let primary = self.primary
            do {
                return try await Self.first(within: hazardDeadline) {
                    try await primary.describe(jpeg: jpeg, prompt: prompt)
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
            }
            return try await fallback.describe(jpeg: jpeg, prompt: prompt)
        }
        do { return try await primary.describe(jpeg: jpeg, prompt: prompt) }
        catch is CancellationError { throw CancellationError() }
        catch { return try await fallback.describe(jpeg: jpeg, prompt: prompt) }
    }

    /// Runs `op`, but gives up after `limit` (throws `URLError(.timedOut)` and cancels `op`).
    static func first(within limit: Duration,
                      _ op: @escaping @Sendable () async throws -> String) async throws -> String {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await op() }
            group.addTask { try await Task.sleep(for: limit); return nil }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let reply = first else { throw URLError(.timedOut) }
            return reply
        }
    }
}

/// Picks and builds the provider from Secrets.plist. Namespace only.
nonisolated enum VLMClientFactory {

    /// What the app actually uses: `VLM_PROVIDER = ondevice` → on-device only; a cloud key →
    /// cloud with on-device fallback; no key → on-device. Never nil, never needs the network.
    static func resolved(context: SceneContext) -> any VLMClient {
        let onDevice = OnDeviceVLMClient(context: context)
        if Secrets.string("VLM_PROVIDER")?.lowercased() == "ondevice" { return onDevice }
        guard let cloud = fromSecrets() else { return onDevice }
        return FallbackVLMClient(primary: cloud, fallback: onDevice)
    }

    /// The configured provider, or nil when no key is present.
    /// `VLM_PROVIDER` (custom / anthropic / gemini / openai) pins one; if that provider lacks a
    /// key, the others are tried in `VLMProvider.allCases` order. Empty or unknown
    /// `VLM_PROVIDER` uses custom → anthropic → gemini → openai. Called once by
    /// `SceneDescriber.init`.
    static func fromSecrets() -> (any VLMClient)? {
        // Case-insensitive: "Gemini" in Secrets.plist must not silently fall back (Antigravity review).
        let requested = Secrets.string("VLM_PROVIDER").flatMap { VLMProvider(rawValue: $0.lowercased()) }
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

    /// Build `provider` if its key (and, for custom, base URL) is set; nil otherwise. Model
    /// defaults when the `*_MODEL` key is empty: custom "muse-1.3", OpenAI "gpt-4o-mini",
    /// Anthropic "claude-opus-5", Gemini "gemini-2.5-flash".
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

/// One session for all providers: no waiting for connectivity, 8 s idle / 12 s total per request,
/// so a dead network falls through to the on-device client quickly and "Where am I" always
/// answers. The hazard watch cuts the cloud off even sooner (FallbackVLMClient.hazardDeadline).
/// A lazily initialised global `let` — thread-safe one-time init.
nonisolated private let vlmSession: URLSession = {
    let c = URLSessionConfiguration.default
    // Fail fast on a dead network: the on-device fallback answers instead of 20 s of silence.
    c.waitsForConnectivity = false
    c.timeoutIntervalForRequest = 8
    c.timeoutIntervalForResource = 12
    return URLSession(configuration: c)
}()

/// JSON POST shared by every provider: sets Content-Type, adds `headers` (auth), sends `body`
/// on `vlmSession`, and returns the response body after `VLMResponse.checkStatus` (CaneKitLogic)
/// has turned any non-2xx status into a `VLMError`.
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
    /// "Muse" (custom endpoint) or "OpenAI".
    let name: String
    /// API root, e.g. "https://api.openai.com/v1"; normalised in `describe` (see below).
    let baseURL: String
    /// Sent as `Authorization: Bearer <key>`.
    let apiKey: String
    /// `model` field of the chat request.
    let model: String

    /// POST `<base>/chat/completions` with the image as a base64 data-URL message part.
    func describe(jpeg: Data, prompt: String) async throws -> String {
        // Accept "https://host/v1", "https://host/v1/", or a full ".../chat/completions".
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/chat/completions") { base += "/chat/completions" }
        guard let url = URL(string: base), url.scheme != nil else { throw VLMError.malformed("bad base URL") }
        let body = try VLMRequest.openAICompatible(model: model, jpegBase64: jpeg.base64EncodedString(), prompt: prompt)
        let data = try await post(url, headers: ["Authorization": "Bearer \(apiKey)"], body: body)
        return try VLMResponse.openAICompatible(data)
    }
}

/// Anthropic Messages API (`/v1/messages`, `anthropic-version: 2023-06-01`).
nonisolated struct AnthropicClient: VLMClient {
    let name = "Anthropic"
    /// Sent as `x-api-key`.
    let apiKey: String
    /// Claude model ID (default "claude-opus-5" from `VLMClientFactory.make`).
    let model: String

    /// POST the image as a base64 `image` content block plus the scene prompt.
    func describe(jpeg: Data, prompt: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!      // constant: cannot fail
        let body = try VLMRequest.anthropic(model: model, jpegBase64: jpeg.base64EncodedString(), prompt: prompt)
        let data = try await post(url, headers: ["x-api-key": apiKey, "anthropic-version": "2023-06-01"], body: body)
        return try VLMResponse.anthropic(data)
    }
}

/// Google Gemini `generateContent` (v1beta).
nonisolated struct GeminiClient: VLMClient {
    let name = "Gemini"
    /// Sent as `x-goog-api-key` (header, not a URL query parameter, so it never lands in logs).
    let apiKey: String
    /// Gemini model ID; part of the URL path.
    let model: String

    /// POST the image as inline base64 data plus the scene prompt. The model goes in the URL, so
    /// `VLMRequest.gemini` takes no model argument.
    func describe(jpeg: Data, prompt: String) async throws -> String {
        // The model name comes from Secrets.plist: encode it and never force-unwrap.
        let m = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(m):generateContent") else {
            throw VLMError.malformed("bad Gemini model name")
        }
        let body = try VLMRequest.gemini(jpegBase64: jpeg.base64EncodedString(), prompt: prompt)
        let data = try await post(url, headers: ["x-goog-api-key": apiKey], body: body)
        return try VLMResponse.gemini(data)
    }
}
