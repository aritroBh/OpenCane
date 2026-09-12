//
//  GrokBotClient.swift
//  CaneKit
//
//  Transport for the Grok Bot routine "OpenCane cane events" (folder opencane-cane-events):
//  one POST of one `OpenCaneEvent` as JSON, with the routine's key as a bearer token. The event
//  shape and every "should this be sent" decision live in CaneKitLogic (`GrokBotEvent`,
//  `FamilyAlertPolicy`, both unit-tested); this file is only transport and key plumbing, the same
//  split as `VLMClient`.
//
//  ⚠ What a 200 means: the bot **accepted the call and started a run**. It does NOT mean a family
//  member was texted — the bot decides that, later, from `severity` and `type`. Nothing here, and
//  no caller, may say or speak "family notified". `Accepted` is the name of the success case for
//  exactly that reason.
//
//  Threading / isolation: `nonisolated` and Sendable (immutable struct + a shared `URLSession`),
//  so `FamilyAlerts` can hold it on the main actor and await it. With
//  NonisolatedNonsendingByDefault (ios/project.yml) `send(_:)` runs on the caller's executor: the
//  JSON encode is a few hundred bytes on main, then the URLSession await suspends.
//
//  Keys (hard rule 4): read from `Secrets.plist` (git-ignored) or the process environment, sent
//  only as the Authorization header to the routine's own host, and never logged — `describe` in
//  the log line below prints the status and the response body, never the request headers.
//

import CaneKitLogic
import Foundation
import os

/// What happened to one POST. Deliberately not `Bool`: the UI has to be able to say "the bot took
/// it" without implying anyone was texted.
enum GrokBotResult: Sendable, Equatable {
    /// HTTP 2xx. The routine started a run. Family alerting is the bot's decision, not ours.
    case accepted
    /// No webhook URL / key configured. The feature is simply off; not an error to shout about.
    case notConfigured
    /// The bot answered with a non-2xx status. `body` is truncated for the log / UI.
    case rejected(status: Int, body: String)
    /// Transport failed twice (the first attempt and the one retry).
    case failed(String)

    /// One short line for the UI and the trip log. Never claims an SMS was sent.
    var summary: String {
        switch self {
        case .accepted: return "Grok Bot accepted the event"
        case .notConfigured: return "No Grok Bot webhook configured"
        case .rejected(let status, let body):
            return "Grok Bot refused it (HTTP \(status))" + (body.isEmpty ? "" : ": \(body)")
        case .failed(let message): return "Could not reach Grok Bot: \(message)"
        }
    }
}

/// POSTs one event to the Grok Bot webhook. Create with `fromSecrets()`.
nonisolated struct GrokBotClient: Sendable {
    /// The routine's webhook URL (`WEBHOOK_URL` in its panel).
    let url: URL
    /// The routine's key (`WEBHOOK_KEY`), sent as `Authorization: Bearer …`.
    private let key: String
    private let session: URLSession

    /// Seconds before one attempt is abandoned. Short on purpose: this runs while someone is
    /// walking, and a hung POST must never be the reason the next cue is late.
    private static let requestTimeout: TimeInterval = 10
    /// Seconds to wait before the single retry. One retry only — the contract asks for one, and a
    /// fall is re-reported by the next detection anyway.
    private static let retryDelay: Duration = .seconds(2)
    /// Response bytes kept for the log / UI. Enough to read an error, short enough not to dump a
    /// page of HTML into a trip log.
    private static let maxLoggedBody = 300

    private static let log = Logger(subsystem: "com.aritro.canekit", category: "grokbot")

    init(url: URL, key: String, session: URLSession = .shared) {
        self.url = url
        self.key = key
        self.session = session
    }

    /// The configured client, or nil when the walker has not pasted the routine's URL + key.
    ///
    /// Environment first so `CANEKIT_UITEST` / e2e runs and a `swift`-launched build can point at
    /// a throwaway endpoint without editing the plist; `Secrets.plist` (git-ignored) otherwise.
    /// Both are the same two names: `OPENCANE_GROKBOT_WEBHOOK_URL`, `OPENCANE_GROKBOT_WEBHOOK_KEY`.
    static func fromSecrets() -> GrokBotClient? {
        let env = ProcessInfo.processInfo.environment
        func value(_ name: String) -> String? {
            if let v = env[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
            return Secrets.string(name)
        }
        guard let raw = value("OPENCANE_GROKBOT_WEBHOOK_URL"),
              let url = URL(string: raw), url.scheme == "https",
              let key = value("OPENCANE_GROKBOT_WEBHOOK_KEY")
        else { return nil }
        return GrokBotClient(url: url, key: key)
    }

    /// POSTs one event. Stamps `timestamp` when the caller left it empty (contract: ISO-8601 UTC).
    /// Retries once on a transport failure, never on a non-2xx status — a 401 will be a 401 again,
    /// and re-POSTing a `fall` the bot already accepted would double-text the family.
    func send(_ event: OpenCaneEvent, now: Date = Date()) async -> GrokBotResult {
        let body: Data
        do {
            body = try event.stamped(at: now).jsonBody()
        } catch {
            return .failed("could not encode the event: \(error.localizedDescription)")
        }

        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        var lastError = "unknown"
        for attempt in 1...2 {
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200...299).contains(status) {
                    // The run started. Whether family gets an SMS is the bot's call, not ours.
                    Self.log.info("event \(event.type.rawValue, privacy: .public) accepted (HTTP \(status))")
                    return .accepted
                }
                let text = String(decoding: data.prefix(Self.maxLoggedBody), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Status + body, as the contract asks. The key is in a header, never in either.
                Self.log.error("event \(event.type.rawValue, privacy: .public) refused: HTTP \(status) \(text, privacy: .public)")
                return .rejected(status: status, body: text)
            } catch {
                lastError = error.localizedDescription
                Self.log.error("event \(event.type.rawValue, privacy: .public) attempt \(attempt) failed: \(lastError, privacy: .public)")
                if attempt == 1 { try? await Task.sleep(for: Self.retryDelay) }
            }
        }
        return .failed(lastError)
    }
}
