//
//  SupabaseClient.swift
//  CaneKit
//
//  The transport half of OpenCane's cloud mirror: a hand-rolled PostgREST + Storage client over
//  `URLSession`. No SDK — AGENTS.md hard rule 2 forbids third-party packages, and the REST surface
//  this app needs is four verbs wide.
//
//  Owner: `CloudSync` (one instance, built by `CloudSync.init` from `Secrets`). Nothing else
//  constructs one. `CloudSchema` (CaneKitLogic) owns the row shapes and every number; this file
//  owns URLs, headers and status codes and decides nothing.
//
//  Threading / isolation: `nonisolated` (AGENTS.md hard rule 1, same as `VLMClient` and
//  `ElevenLabsVoice`) so a request never touches the main actor. Every method is `async throws`
//  and returns raw `Data`; the caller decodes.
//
//  Configuration: `SUPABASE_URL` and `SUPABASE_ANON_KEY` (or `SUPABASE_PUBLISHABLE_KEY`) in the git-ignored
//  `CaneKit/Resources/Secrets.plist` (template: `ios/Secrets.example.plist`). Missing either one
//  makes `fromSecrets()` return nil, `CloudSync` stays idle and the app behaves exactly as it did
//  before Step 45 — the phone keeps its own logs and the Settings row says the cloud is off.
//
//  ⚠ The key in the plist is the **publishable** (anon) key, which is meant to be shipped in a
//  client. It is not a service-role key, and a service-role key must never go near this file: it
//  would hand anyone who unzips the .ipa full write access to every walker's data. Row-level
//  security in migration `opencane_05` is what bounds the anon key.
//
//  Key invariants:
//    · Timeouts are short (15 s request). A cane that cannot reach the network must fail fast and
//      let `CloudSync` re-queue; it must never hold a cue, a Task, or a walk.
//    · A non-2xx status throws `SupabaseError.http` carrying the body, because PostgREST puts the
//      actual reason there (`PGRST102`, a check-constraint name) and a bare status code has never
//      once been enough to debug one of these.
//    · `bulkInsert` sends an array. ⚠ Every row must carry the same key set — see
//      `CloudSchema`/`CloudSchemaTests`; PostgREST rejects the whole batch otherwise.
//  Tests: none (network I/O). The REST contract was verified against the live project on
//  2026-09-13 with curl — register, bulk insert, patch, RPC and a storage upload — and the row
//  shapes are unit-tested in `CloudSchemaTests`.
//

import CaneKitLogic
import Foundation

/// What went wrong talking to Supabase, in the words a log line needs.
enum SupabaseError: Error, CustomStringConvertible {
    /// Non-2xx. Carries the PostgREST body, which is where the real reason lives.
    case http(status: Int, body: String)
    /// The response was not an HTTP response at all (a cancelled or malformed request).
    case notHTTP
    /// A path could not be turned into a URL (a table or bucket name with something odd in it).
    case badURL(String)

    var description: String {
        switch self {
        case .http(let status, let body):
            let trimmed = body.prefix(300)
            return trimmed.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(trimmed)"
        case .notHTTP: return "No HTTP response"
        case .badURL(let path): return "Bad URL: \(path)"
        }
    }
}

/// REST access to one Supabase project with the publishable key.
///
/// Four verbs: `insert` / `bulkInsert` (POST to `/rest/v1/<table>`), `upsert` (the same POST with
/// `Prefer: resolution=merge-duplicates`), `patch` (PATCH with a PostgREST filter) and `rpc`
/// (POST to `/rest/v1/rpc/<function>`), plus `uploadObject` for the hazard-photo bucket.
nonisolated final class SupabaseClient: Sendable {

    /// Project base, e.g. `https://<ref>.supabase.co`, with no trailing slash.
    private let baseURL: URL
    /// The publishable (anon) key. Sent as both `apikey` and `Authorization: Bearer` — PostgREST
    /// wants the first, GoTrue-derived RLS wants the second, and Storage wants the second.
    private let apiKey: String
    private let session: URLSession

    /// Encoder for every body. Snake-case column names are spelled out in each row's `CodingKeys`
    /// (they are the contract), so no key strategy is applied here.
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    /// - Parameters:
    ///   - baseURL: the project URL; a trailing slash is trimmed.
    ///   - apiKey: the publishable key (never the service-role key — see the file header).
    init(baseURL: URL, apiKey: String) {
        let text = baseURL.absoluteString
        self.baseURL = text.hasSuffix("/") ? URL(string: String(text.dropLast())) ?? baseURL : baseURL
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        // Short, because the caller re-queues. A walk must not wait on a campus dead spot.
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        config.allowsConstrainedNetworkAccess = true
        self.session = URLSession(configuration: config)
    }

    /// The client the app ships with, or nil when the project is not configured.
    /// Reads `SUPABASE_URL` / `SUPABASE_ANON_KEY` from `Secrets.plist`; either one missing (or
    /// empty, which `Secrets` counts as missing) means no cloud, and the app runs exactly as it
    /// did before. Never crashes and never logs the key.
    static func fromSecrets() -> SupabaseClient? {
        guard let raw = Secrets.string("SUPABASE_URL"),
              let url = URL(string: raw),
              url.scheme?.hasPrefix("http") == true,
              // Both names are accepted: Supabase renamed "anon key" to "publishable key", and a
              // teammate's local plist may carry either.
              let key = Secrets.string("SUPABASE_ANON_KEY")
                     ?? Secrets.string("SUPABASE_PUBLISHABLE_KEY")
        else { return nil }
        return SupabaseClient(baseURL: url, apiKey: key)
    }

    /// The project host, for the Settings row ("Syncing to ppmuqgswuyniwiwsdnto.supabase.co").
    /// Never includes the key.
    var host: String { baseURL.host() ?? baseURL.absoluteString }

    // MARK: Reads

    /// Read rows from a table or view.
    /// - Parameters:
    ///   - table: a `public` table or view name.
    ///   - query: PostgREST query items — `select`, filters (`walker_id=eq.…`), `order`, `limit`.
    /// - Returns: the JSON array body.
    func select(_ table: String, query: [URLQueryItem]) async throws -> Data {
        try await send(method: "GET", path: "/rest/v1/\(table)", query: query, body: nil)
    }

    // MARK: Writes

    /// Insert one row.
    /// - Parameters:
    ///   - table: a `public` table name.
    ///   - row: an encodable row from `CloudSchema`.
    ///   - returning: ask PostgREST to echo the inserted row (needed when the caller wants the
    ///     generated id). `false` sends `Prefer: return=minimal`, which is cheaper.
    /// - Returns: the response body (the row array when `returning`, empty otherwise).
    @discardableResult
    func insert(into table: String, row: some Encodable, returning: Bool = false) async throws -> Data {
        try await send(method: "POST", path: "/rest/v1/\(table)", body: encoder.encode(row),
                       prefer: returning ? "return=representation" : "return=minimal")
    }

    /// Insert many rows in one request.
    /// ⚠ Every row must encode the same key set or PostgREST rejects the whole batch with
    /// `PGRST102` and writes nothing. The `CloudSchema` row types that get bulk-inserted encode
    /// their nils explicitly for exactly this reason; `CloudSchemaTests` pins it.
    /// An empty array is a no-op rather than an empty POST.
    @discardableResult
    func bulkInsert(into table: String, rows: [some Encodable], returning: Bool = false) async throws -> Data {
        guard !rows.isEmpty else { return Data() }
        return try await send(method: "POST", path: "/rest/v1/\(table)", body: encoder.encode(rows),
                              prefer: returning ? "return=representation" : "return=minimal")
    }

    /// Insert or update, keyed on `onConflict` columns.
    /// - Parameter onConflict: the unique column(s) that decide a collision, comma-separated
    ///   (`"walker_id"`, `"walker_id,day"`). Must match a unique constraint or Postgres errors.
    @discardableResult
    func upsert(into table: String, row: some Encodable, onConflict: String,
                returning: Bool = false) async throws -> Data {
        let prefer = "resolution=merge-duplicates,return=" + (returning ? "representation" : "minimal")
        return try await send(method: "POST",
                              path: "/rest/v1/\(table)",
                              query: [URLQueryItem(name: "on_conflict", value: onConflict)],
                              body: encoder.encode(row), prefer: prefer)
    }

    /// Update the rows matching a PostgREST filter.
    /// - Parameter filter: query items in PostgREST form, e.g.
    ///   `URLQueryItem(name: "id", value: "eq.\(tripID)")`. An empty filter would update the whole
    ///   table, so it is refused.
    @discardableResult
    func patch(_ table: String, filter: [URLQueryItem], row: some Encodable,
               returning: Bool = false) async throws -> Data {
        guard !filter.isEmpty else { throw SupabaseError.badURL("\(table) (patch with no filter)") }
        return try await send(method: "PATCH", path: "/rest/v1/\(table)", query: filter,
                              body: encoder.encode(row),
                              prefer: returning ? "return=representation" : "return=minimal")
    }

    /// Call a Postgres function (`register_cane`, `save_family_contacts`, `hazards_near`).
    /// - Returns: the function's JSON result.
    @discardableResult
    func rpc(_ function: String, body: some Encodable) async throws -> Data {
        try await send(method: "POST", path: "/rest/v1/rpc/\(function)", body: encoder.encode(body))
    }

    // MARK: Storage

    /// Upload a hazard photo (or any object) to a bucket.
    /// - Parameters:
    ///   - bucket: `hazard-photos`.
    ///   - path: the object path inside the bucket, e.g. `<walker-id>/hazard-3.jpg`.
    ///   - data: the JPEG bytes.
    ///   - contentType: defaults to JPEG (the bucket only allows JPEG and PNG).
    /// - Returns: `path`, so the caller can store it on the hazard row.
    @discardableResult
    func uploadObject(bucket: String, path: String, data: Data,
                      contentType: String = "image/jpeg") async throws -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        _ = try await send(method: "POST", path: "/storage/v1/object/\(bucket)/\(encoded)",
                           body: data, contentType: contentType)
        return path
    }

    /// The public URL of an uploaded object, for a row a human will click in the dashboard.
    func publicURL(bucket: String, path: String) -> URL? {
        URL(string: "\(baseURL.absoluteString)/storage/v1/object/public/\(bucket)/\(path)")
    }

    // MARK: Plumbing

    /// One request. Throws `SupabaseError.http` with the body on any non-2xx, because PostgREST's
    /// body is where the real reason is.
    /// A nil `body` sends no body at all (GET); anything else sets `Content-Type`.
    private func send(method: String, path: String, query: [URLQueryItem] = [],
                      body: Data?, prefer: String? = nil,
                      contentType: String = "application/json") async throws -> Data {
        guard var components = URLComponents(string: baseURL.absoluteString + path) else {
            throw SupabaseError.badURL(path)
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw SupabaseError.badURL(path) }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SupabaseError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw SupabaseError.http(status: http.statusCode,
                                     body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}
