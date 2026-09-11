//
//  ElevenLabsVoice.swift
//  CaneKit
//
//  Natural voice via ElevenLabs text-to-speech, with an on-disk cache so any line we have heard
//  before (and every route line, pre-synthesized when a route starts) plays with zero network
//  latency. `SpeechQueue` calls `audio(for:)`; a miss with no network falls back to AVSpeech.
//
//  Secrets.plist: ELEVENLABS_API_KEY, ELEVENLABS_VOICE_ID (default: a warm premade voice),
//  ELEVENLABS_MODEL (default eleven_flash_v2_5 — lowest latency).
//
//  Threading / isolation: a `nonisolated` Sendable value type with no mutable shared state, so
//  it can be called from any context. The target enables NonisolatedNonsendingByDefault
//  (ios/project.yml), so its nonisolated `async` methods run on the *caller's* executor:
//    · `SpeechQueue.speakNow` awaits `audio(for:)` from a main-actor task — the request build,
//      hashing and the small mp3 file write run on main; the URLSession await suspends (the
//      network wait never blocks main).
//    · `SpeechQueue.prefetch` calls `prefetch(_:)` from a detached `.utility` task, and its
//      task-group children run on the global concurrent executor — off main.
//  Cache files are written atomically, so two concurrent fetches of the same line (a prefetch
//  racing a live miss) just write the same bytes twice — harmless.
//
//  Invariants: the key is never logged or spoken (hard rule 4; it lives only in the git-ignored
//  Secrets.plist). No key → `fromSecrets()` returns nil and the app uses the system voice.
//  The cache key covers voice + model + text, so changing either in Secrets never replays a
//  stale voice. The cache lives in Caches/, which iOS may purge; a purge only costs latency.
//

import CryptoKit
import Foundation

/// ElevenLabs text-to-speech client with a content-addressed mp3 cache. Built once by
/// `SpeechQueue.naturalVoice`; see the file header for threading.
nonisolated struct ElevenLabsVoice: Sendable {

    /// ElevenLabs API key (`xi-api-key` header). Never logged.
    let apiKey: String
    /// ElevenLabs voice ID (path component of the TTS endpoint); part of the cache key.
    let voiceID: String
    /// ElevenLabs model ID (`model_id` in the body); part of the cache key.
    let model: String
    /// Hard cap on a live synth call; beyond this the queue speaks with AVSpeech instead.
    /// Seconds; applied as the `URLRequest.timeoutInterval` (idle timeout between bytes). At
    /// walking pace 2.5 s is ~3.5 m, which is why warnings never wait for it at all.
    var timeout: TimeInterval = 2.5

    /// nil when no key is configured.
    /// Reads `ELEVENLABS_API_KEY` (required), `ELEVENLABS_VOICE_ID` (default
    /// "21m00Tcm4TlvDq8ikWAM", a premade voice) and `ELEVENLABS_MODEL` (default
    /// "eleven_flash_v2_5", the low-latency model). Empty values count as missing (`Secrets`).
    static func fromSecrets() -> ElevenLabsVoice? {
        guard let key = Secrets.string("ELEVENLABS_API_KEY") else { return nil }
        return ElevenLabsVoice(apiKey: key,
                               voiceID: Secrets.string("ELEVENLABS_VOICE_ID") ?? "21m00Tcm4TlvDq8ikWAM",
                               model: Secrets.string("ELEVENLABS_MODEL") ?? "eleven_flash_v2_5")
    }

    // MARK: Cache

    /// `Library/Caches/elevenlabs/`, created on demand (every access re-checks; creation errors
    /// are ignored and surface later as a failed write, i.e. a cache miss).
    private static var cacheDir: URL {
        let dir = URL.cachesDirectory.appendingPathComponent("elevenlabs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Deterministic file for (voice, model, text): the first 12 bytes of
    /// SHA-256("voiceID|model|text") as 24 hex characters + ".mp3". Text must match exactly
    /// (SpeechQueue trims it first), so "Turn left." and "Turn left" are different files.
    private func cacheURL(for text: String) -> URL {
        let digest = SHA256.hash(data: Data("\(voiceID)|\(model)|\(text)".utf8))
        let name = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return Self.cacheDir.appendingPathComponent("\(name).mp3")
    }

    /// Cached audio for `text`, or nil.
    /// Synchronous file-existence check (a hash + one `stat`; called on main by
    /// `SpeechQueue.speakNow` to decide between instant playback and a fetch).
    func cached(_ text: String) -> URL? {
        let url = cacheURL(for: text)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Synthesis

    /// Returns a local mp3 for `text`, fetching and caching it if needed. Throws on network /
    /// API failure or timeout so the caller can fall back.
    /// Side effect: writes the mp3 into the cache (atomic write) before returning its URL.
    /// Cancellation of the calling task cancels the URLSession request (throws `CancellationError`
    /// / `URLError.cancelled`). Callers: `SpeechQueue.speakNow` (live miss) and `prefetch`.
    func audio(for text: String) async throws -> URL {
        if let hit = cached(text) { return hit }
        let url = cacheURL(for: text)
        let data = try await synthesize(text)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Pre-synthesize a batch (route lines, common phrases), at most 3 requests in flight so a
    /// long route never bursts into rate limits. Failures are ignored.
    /// Duplicates and already-cached lines are skipped up front. Returns when every request has
    /// finished or failed. Caller: `SpeechQueue.prefetch`, on a detached `.utility` task.
    func prefetch(_ lines: [String]) async {
        let missing = Array(Set(lines)).filter { cached($0) == nil }
        await withTaskGroup(of: Void.self) { group in
            var iterator = missing.makeIterator()
            for _ in 0..<min(3, missing.count) {
                if let line = iterator.next() { group.addTask { _ = try? await audio(for: line) } }
            }
            while await group.next() != nil {
                if let line = iterator.next() { group.addTask { _ = try? await audio(for: line) } }
            }
        }
    }

    /// One POST to `/v1/text-to-speech/{voiceID}` requesting 22.05 kHz / 32 kbps mp3 (small
    /// files, fast download, plenty for speech). Throws `VoiceError` for a non-2xx status (with
    /// up to 200 bytes of the body for diagnosis) or an empty body, and `URLError` for
    /// transport failures / timeout. Uses `URLSession.shared`.
    private func synthesize(_ text: String) async throws -> Data {
        // The voice id comes from Secrets.plist: percent-encode it and never force-unwrap (a stray
        // space would otherwise crash route start, which prefetches lines).
        let id = voiceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? voiceID
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(id)?output_format=mp3_22050_32") else {
            throw VoiceError.badResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "text": text,
            "model_id": model,
            // Calm, confident delivery; slight style for warmth.
            "voice_settings": ["stability": 0.5, "similarity_boost": 0.8, "style": 0.35, "use_speaker_boost": true],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VoiceError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw VoiceError.http(http.statusCode, String(decoding: data.prefix(200), as: UTF8.self))
        }
        guard !data.isEmpty else { throw VoiceError.badResponse }
        return data
    }

    /// Failures from `synthesize`. `SpeechQueue` shows `errorDescription` in `voiceError`
    /// (debug only) and falls back to the system voice.
    enum VoiceError: Error, LocalizedError {
        /// Not an HTTP response, or a 2xx with an empty body.
        case badResponse
        /// Non-2xx: status code and the first ≤ 200 bytes of the response body.
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .badResponse: return "ElevenLabs: empty response"
            case .http(let code, let msg): return "ElevenLabs HTTP \(code): \(msg)"
            }
        }
    }
}
