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

import CryptoKit
import Foundation

nonisolated struct ElevenLabsVoice: Sendable {

    let apiKey: String
    let voiceID: String
    let model: String
    /// Hard cap on a live synth call; beyond this the queue speaks with AVSpeech instead.
    var timeout: TimeInterval = 2.5

    /// nil when no key is configured.
    static func fromSecrets() -> ElevenLabsVoice? {
        guard let key = Secrets.string("ELEVENLABS_API_KEY") else { return nil }
        return ElevenLabsVoice(apiKey: key,
                               voiceID: Secrets.string("ELEVENLABS_VOICE_ID") ?? "21m00Tcm4TlvDq8ikWAM",
                               model: Secrets.string("ELEVENLABS_MODEL") ?? "eleven_flash_v2_5")
    }

    // MARK: Cache

    private static var cacheDir: URL {
        let dir = URL.cachesDirectory.appendingPathComponent("elevenlabs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cacheURL(for text: String) -> URL {
        let digest = SHA256.hash(data: Data("\(voiceID)|\(model)|\(text)".utf8))
        let name = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return Self.cacheDir.appendingPathComponent("\(name).mp3")
    }

    /// Cached audio for `text`, or nil.
    func cached(_ text: String) -> URL? {
        let url = cacheURL(for: text)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Synthesis

    /// Returns a local mp3 for `text`, fetching and caching it if needed. Throws on network /
    /// API failure or timeout so the caller can fall back.
    func audio(for text: String) async throws -> URL {
        if let hit = cached(text) { return hit }
        let url = cacheURL(for: text)
        let data = try await synthesize(text)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Pre-synthesize a batch (route lines, common phrases), at most 3 requests in flight so a
    /// long route never bursts into rate limits. Failures are ignored.
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

    private func synthesize(_ text: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)?output_format=mp3_22050_32")!)
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

    enum VoiceError: Error, LocalizedError {
        case badResponse
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .badResponse: return "ElevenLabs: empty response"
            case .http(let code, let msg): return "ElevenLabs HTTP \(code): \(msg)"
            }
        }
    }
}
