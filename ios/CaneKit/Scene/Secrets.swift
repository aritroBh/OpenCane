//
//  Secrets.swift
//  CaneKit
//
//  Reads CaneKit/Resources/Secrets.plist (git-ignored; scripts/gen.sh copies the example in).
//  Empty strings count as missing so the example file "works" with every feature degraded
//  gracefully instead of crashing.
//

import Foundation

nonisolated enum Secrets {
    /// Only string values are kept, so the table is Sendable.
    private static let table: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return obj.compactMapValues { $0 as? String }
    }()

    /// Non-empty string for `key`, or nil.
    static func string(_ key: String) -> String? {
        guard let s = table[key] else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static var hasElevenLabs: Bool { string("ELEVENLABS_API_KEY") != nil }
}
