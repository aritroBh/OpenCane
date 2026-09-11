//
//  SceneDescriber.swift
//  CaneKit
//
//  POSTs a JPEG to Gemini 2.5 Flash (generateContent REST) and returns a short
//  spoken-style description. API key comes from Info.plist "GEMINI_API_KEY"
//  (or the GEMINI_API_KEY environment variable in the Xcode scheme, for dev).
//

import Foundation
import Observation

@Observable
final class SceneDescriber {

    enum DescribeError: LocalizedError {
        case missingAPIKey
        case badResponse(String)
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:        return "GEMINI_API_KEY is not set in Info.plist"
            case .badResponse(let s):   return "Unexpected Gemini response: \(s)"
            case .http(let code, let s): return "Gemini HTTP \(code): \(s)"
            }
        }
    }

    var modelName = "gemini-2.5-flash"
    var prompt = "You are guiding a blind pedestrian. In under 25 words, name the most important hazards and landmarks ahead, nearest first, with clock-face directions."
    var timeout: TimeInterval = 20

    private(set) var lastDescription = ""
    private(set) var lastLatencyMs: Int = 0

    static var apiKey: String? {
        if let k = Bundle.main.object(forInfoDictionaryKey: "GEMINI_API_KEY") as? String,
           !k.isEmpty, !k.hasPrefix("$(") {          // "$(GEMINI_API_KEY)" = unresolved build setting
            return k
        }
        if let k = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !k.isEmpty {
            return k
        }
        return nil
    }

    /// Sends the JPEG and returns the model's text. Throws on network / API / parse errors.
    func describe(jpeg: Data) async throws -> String {
        guard let key = Self.apiKey else { throw DescribeError.missingAPIKey }

        // Query-string form also works: "...:generateContent?key=<KEY>". Header keeps the key out of logs.
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent") else {
            throw DescribeError.badResponse("bad URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")

        let body = GenerateRequest(
            contents: [
                .init(parts: [
                    .init(text: prompt),
                    .init(inlineData: .init(mimeType: "image/jpeg", data: jpeg.base64EncodedString()))
                ])
            ],
            generationConfig: .init(
                maxOutputTokens: 120,
                temperature: 0.2,
                // 2.5 Flash "thinks" by default and burns output tokens doing it; turn it off for latency.
                thinkingConfig: .init(thinkingBudget: 0)
            )
        )
        request.httpBody = try JSONEncoder().encode(body)

        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let latency = Int(Date().timeIntervalSince(started) * 1000)

        guard let http = response as? HTTPURLResponse else {
            throw DescribeError.badResponse("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw DescribeError.http(http.statusCode, message)
        }

        let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
        let text = (decoded.candidates?.first?.content?.parts ?? [])
            .compactMap(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            let reason = decoded.promptFeedback?.blockReason
                ?? decoded.candidates?.first?.finishReason
                ?? "empty text"
            throw DescribeError.badResponse(reason)
        }

        await MainActor.run {
            lastDescription = text
            lastLatencyMs = latency
        }
        return text
    }
}

// MARK: - Wire format (camelCase JSON, as the Gemini REST API expects)

private struct GenerateRequest: Encodable {
    struct Content: Encodable {
        var role: String = "user"
        var parts: [Part]
    }
    struct Part: Encodable {
        var text: String? = nil
        var inlineData: InlineData? = nil
    }
    struct InlineData: Encodable {
        var mimeType: String
        var data: String
    }
    struct GenerationConfig: Encodable {
        var maxOutputTokens: Int
        var temperature: Double
        var thinkingConfig: ThinkingConfig?
    }
    struct ThinkingConfig: Encodable {
        var thinkingBudget: Int
    }
    var contents: [Content]
    var generationConfig: GenerationConfig
}

private struct GenerateResponse: Decodable {
    struct Candidate: Decodable {
        var content: Content?
        var finishReason: String?
    }
    struct Content: Decodable {
        var parts: [Part]?
    }
    struct Part: Decodable {
        var text: String?
    }
    struct PromptFeedback: Decodable {
        var blockReason: String?
    }
    var candidates: [Candidate]?
    var promptFeedback: PromptFeedback?
}

private struct ErrorEnvelope: Decodable {
    struct Inner: Decodable {
        var message: String?
        var status: String?
    }
    var error: Inner
}
