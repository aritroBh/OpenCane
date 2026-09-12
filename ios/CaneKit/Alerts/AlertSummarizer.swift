//
//  AlertSummarizer.swift
//  CaneKit
//
//  Asks a cheap text model for one family-facing sentence about a cane event. Transport only:
//  the prompt and its bans are `AlertContextPrompt` (CaneKitLogic, unit-tested), and the response
//  parsing reuses `VLMResponse.openAICompatible` / `.anthropic`, which read the same JSON shapes
//  whether or not the request carried an image.
//
//  ⚠ This is **best effort and never load-bearing**. Every failure path — no key, timeout, HTTP
//  error, empty reply — returns nil, and `FamilyAlerts` then sends the event with its facts and no
//  `ai_context`. A cane alert must never be lost because a language model was slow. The one cost
//  of a slow model is that the webhook POST happens a few seconds later, and that is bounded by
//  `requestTimeout` below.
//
//  ⚠ The model never writes `note`. See AlertContext.swift — its sentence lands in
//  `extra.ai_context`, beside the facts it was given, so it can always be checked against them.
//
//  Model choice: deliberately NOT `ANTHROPIC_MODEL` / the "Where am I" provider, which is a large
//  reasoning model chosen for describing photographs. This is a one-sentence rewrite of a dozen
//  labelled facts, it happens on every alert, and it is in the walker's alert path — so it gets the
//  cheapest thing available, overridable with `ALERT_MODEL`.
//
//  Threading / isolation: `nonisolated` and Sendable; awaited from `FamilyAlerts`'s send `Task`.
//
//  Keys (hard rule 4): read from `Secrets.plist` / the environment, sent only as the provider's
//  own auth header, never logged.
//

import CaneKitLogic
import Foundation
import os

/// A cheap text model that turns cane-event facts into one sentence. `fromSecrets()` or nil.
nonisolated struct AlertSummarizer: Sendable {

    /// Which dialect to speak. Both parse back through `VLMResponse`.
    enum Provider: Sendable {
        /// Anthropic Messages API.
        case anthropic(key: String, model: String)
        /// OpenAI `chat/completions` and anything speaking it (Muse, for this build).
        case openAICompatible(name: String, baseURL: String, key: String, model: String, effort: String?)

        /// For the log line and the Settings row.
        var name: String {
            switch self {
            case .anthropic(_, let model): return "Anthropic \(model)"
            case .openAICompatible(let name, _, _, let model, _): return "\(name) \(model)"
            }
        }
    }

    let provider: Provider

    /// Cheapest current Claude. Used when `ALERT_MODEL` is unset and an Anthropic key exists.
    static let defaultAnthropicModel = "claude-haiku-4-5-20251001"

    /// Seconds before the summary is abandoned and the event goes out without it. This is the
    /// worst case added to an alert's latency, so it is short: a fall reaching family three
    /// seconds later with context is fine, thirty seconds later is not.
    private static let requestTimeout: TimeInterval = 6

    private static let log = Logger(subsystem: "com.aritro.canekit", category: "alertsummary")

    /// Its own session: the alert path must not queue behind a "Where am I" image upload on the
    /// shared one, and it wants a much shorter timeout than scene description does.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout
        config.waitsForConnectivity = false          // offline: fail now, do not hold the alert
        return URLSession(configuration: config)
    }()

    /// The configured summarizer, or nil when no text-model key is present (then alerts simply
    /// carry their facts and no `ai_context`).
    ///
    /// Order: Anthropic (cheapest model, via `ALERT_MODEL`), then the custom OpenAI-compatible
    /// endpoint, then OpenAI. Environment first, like every other key in this app.
    static func fromSecrets() -> AlertSummarizer? {
        func value(_ name: String) -> String? {
            let env = ProcessInfo.processInfo.environment
            if let v = env[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
            return Secrets.string(name)
        }
        let override = value("ALERT_MODEL")

        if let key = value("ANTHROPIC_API_KEY") {
            return AlertSummarizer(provider: .anthropic(key: key,
                                                        model: override ?? defaultAnthropicModel))
        }
        if let base = value("CUSTOM_BASE_URL"), let key = value("CUSTOM_API_KEY"),
           let model = override ?? value("CUSTOM_MODEL") {
            // ⚠ "minimal", NOT the "low" the scene path uses. Measured on the real endpoint
            // (see TextRequest.maxOutputTokens): "low" spends ~800 reasoning tokens and 7.1 s on
            // this prompt, over `requestTimeout`, so the summary would usually be abandoned;
            // "minimal" spends 154 and 2.1 s for an equally good sentence. Overridable with
            // ALERT_REASONING_EFFORT without a rebuild.
            return AlertSummarizer(provider: .openAICompatible(
                name: "Muse", baseURL: base, key: key, model: model,
                effort: value("ALERT_REASONING_EFFORT") ?? "minimal"))
        }
        if let key = value("OPENAI_API_KEY") {
            return AlertSummarizer(provider: .openAICompatible(
                name: "OpenAI", baseURL: "https://api.openai.com/v1", key: key,
                model: override ?? value("OPENAI_MODEL") ?? "gpt-4o-mini", effort: nil))
        }
        return nil
    }

    /// One sentence for `extra.ai_context`, or nil on any failure at all.
    /// - Parameter prompt: `AlertContextPrompt.text(…)`.
    func summarize(prompt: String) async -> String? {
        do {
            let (url, headers, body) = try request(prompt: prompt)
            var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            request.httpBody = body

            let (data, response) = try await Self.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            try VLMResponse.checkStatus(status, data: data)

            let text: String
            switch provider {
            case .anthropic: text = try VLMResponse.anthropic(data)
            case .openAICompatible: text = try VLMResponse.openAICompatible(data)
            }
            return Self.clean(text)
        } catch {
            // Best effort: say why in the log, then let the event go without a summary.
            Self.log.error("summary skipped: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// URL + auth headers + body for the configured dialect.
    private func request(prompt: String) throws -> (URL, [String: String], Data) {
        switch provider {
        case .anthropic(let key, let model):
            let url = URL(string: "https://api.anthropic.com/v1/messages")!   // constant: cannot fail
            return (url, ["x-api-key": key, "anthropic-version": "2023-06-01"],
                    try TextRequest.anthropic(model: model, prompt: prompt))

        case .openAICompatible(_, let baseURL, let key, let model, let effort):
            // Accept "https://host/v1", a trailing slash, or a full ".../chat/completions".
            var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while base.hasSuffix("/") { base.removeLast() }
            if !base.hasSuffix("/chat/completions") { base += "/chat/completions" }
            guard let url = URL(string: base), url.scheme != nil else {
                throw VLMError.malformed("bad base URL")
            }
            return (url, ["Authorization": "Bearer \(key)"],
                    try TextRequest.openAICompatible(model: model, prompt: prompt,
                                                     reasoningEffort: effort))
        }
    }

    /// Trims, unwraps a model that answered in quotes, collapses newlines (this ends up in an SMS)
    /// and enforces the character budget the prompt asked for. nil when nothing usable is left.
    static func clean(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if text.count > AlertContextPrompt.maxReplyCharacters {
            text = String(text.prefix(AlertContextPrompt.maxReplyCharacters))
        }
        return text.isEmpty ? nil : text
    }
}
