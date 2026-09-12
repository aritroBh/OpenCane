//
//  Secrets.swift
//  CaneKit
//
//  Reads CaneKit/Resources/Secrets.plist (git-ignored; scripts/gen.sh copies the example in).
//  Empty strings count as missing so the example file "works" with every feature degraded
//  gracefully instead of crashing.
//
//  Hard rule 4 (AGENTS.md): keys live only in the git-ignored Resources/Secrets.plist
//  (template: ios/Secrets.example.plist). Nothing here may crash, log or speak a key; a missing
//  file or key yields nil and each feature falls back (system voice for speech, the on-device
//  describer for "Where am I").
//
//  Threading / isolation: `nonisolated` caseless enum; the table is a lazily initialised,
//  immutable `static let` (thread-safe one-time init), so `string(_:)` is callable from any
//  context — main (`SpeechQueue`, `SceneDescriber` init) or not.
//
//  Keys read by the app: ELEVENLABS_API_KEY / _VOICE_ID / _MODEL (ElevenLabsVoice),
//  VLM_PROVIDER, CUSTOM_BASE_URL / _API_KEY / _MODEL, OPENAI_API_KEY / _MODEL,
//  ANTHROPIC_API_KEY / _MODEL, GEMINI_API_KEY / _MODEL (VLMClientFactory).
//

import Foundation

/// Read-only access to Secrets.plist string values. Namespace only.
nonisolated enum Secrets {
    /// Only string values are kept, so the table is Sendable.
    /// Loaded once from the app bundle on first access; `[:]` when the plist is missing or
    /// malformed (never throws).
    private static let table: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return obj.compactMapValues { $0 as? String }
    }()

    /// Non-empty string for `key`, or nil.
    /// Leading/trailing whitespace and newlines are trimmed (a pasted key with a trailing newline
    /// still works); whitespace-only counts as missing.
    static func string(_ key: String) -> String? {
        guard let s = table[key] else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// An ElevenLabs key is configured (the natural voice is possible). Currently has no
    /// callers — the UI checks `SpeechQueue.naturalVoice == nil`, and
    /// `ElevenLabsVoice.fromSecrets()` performs the same check itself.
    static var hasElevenLabs: Bool { string("ELEVENLABS_API_KEY") != nil }
}
