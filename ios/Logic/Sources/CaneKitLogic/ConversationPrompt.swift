//
//  ConversationPrompt.swift
//  CaneKitLogic
//
//  Prompt generation and structured response decoding for conversational voice interaction.
//  Works with OpenAI-compatible endpoints (Muse Spark 1.3 / GPT-4o-mini), Gemini, and Anthropic.
//
//  Purpose:
//    · `ConversationPrompt` — builds compact, context-infused prompts for the assistant.
//    · `ConversationResponseParser` — decodes the model's structured tool calls and spoken answers,
//      stripping markdown code fences and applying safety filters against hallucinated clear-path claims.
//
//  Key invariants:
//    · Pure Foundation only; no networking or keys here.
//    · Enforces strict anti-slop rules (< 25 words, no pleasantries, never say safe/clear).
//    · Tested in `ConversationPromptTests`.
//

import Foundation

// MARK: - Prompt Construction

/// Builds the system and user prompt strings for the conversational agent.
public enum ConversationPrompt {

    /// System instruction establishing persona, voice constraints, and safety bans.
    public static let systemInstruction: String = """
    You are OpenCane, an intelligent navigation assistant clamped to a white cane for a blind pedestrian.
    Your replies are SPOKEN via headphones while the user is actively walking.

    CRITICAL RULES:
    1. Maximum 1-2 short sentences (under 25 words total). Brevity is vital for situational awareness.
    2. Never invent distances or counts. Distances must come ONLY from context or tools.
    3. Never say the path is "clear", "empty", or "safe".
    4. Speak directly. No conversational filler, pleasantries, or preamble.
    5. When executing a tool, declare it in the "tool" and "args" fields.
    """

    /// Declarations of available tools for LLM reasoning.
    public static let toolDeclarationsJSON: String = """
    [
      {"name": "navigate_to", "description": "Start route to destination", "parameters": {"destination": "string"}},
      {"name": "stop_navigation", "description": "Stop current walking route"},
      {"name": "drop_marker", "description": "Save current spot as named post/marker", "parameters": {"name": "string"}},
      {"name": "query_scene", "description": "Ask visual question about camera frame", "parameters": {"question": "string"}},
      {"name": "query_status", "description": "Query telemetry", "parameters": {"aspect": "battery|headphones|gps|route|all"}},
      {"name": "query_history", "description": "Query walking trends/hazards", "parameters": {"metric": "steps|distance|hazards"}},
      {"name": "set_setting", "description": "Toggle feature switch", "parameters": {"option": "string", "enabled": "boolean"}},
      {"name": "set_cane_silenced", "description": "Silence or unsilence cane haptics", "parameters": {"silenced": "boolean"}}
    ]
    """

    /// Formats the user query, context telemetry, and dialogue history into a single compact prompt.
    public static func buildUserPrompt(query: String, context: ConversationContext, history: ConversationHistory) -> String {
        var ctxDict: [String: String] = [:]
        if let d = context.currentDestination { ctxDict["destination"] = d }
        if let next = context.nextWaypointName { ctxDict["next_waypoint"] = next }
        if let m = context.distanceToNextMeters { ctxDict["meters_to_next"] = "\(m)" }
        if context.batteryPercent >= 0 { ctxDict["battery"] = "\(context.batteryPercent)%" }
        ctxDict["headphones"] = context.headphonesConnected ? context.headphoneName : "none"
        if let steps = context.steps { ctxDict["steps"] = "\(steps)" }
        if context.distanceWalkedM > 0 { ctxDict["distance_walked_m"] = "\(Int(context.distanceWalkedM.rounded()))" }
        if !context.recentHazards.isEmpty {
            ctxDict["recent_hazard"] = context.recentHazards.last?.description
        }
        if !context.savedMarkers.isEmpty {
            ctxDict["saved_markers"] = context.savedMarkers.map(\.name).joined(separator: ", ")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let ctxJSON = (try? encoder.encode(ctxDict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        var turnsText = ""
        for t in history.turns.suffix(3) {
            turnsText += "User: \(t.userQuery)\n"
            if let r = t.agentResponse { turnsText += "OpenCane: \(r)\n" }
        }

        return """
        \(systemInstruction)

        [TOOLS]
        \(toolDeclarationsJSON)

        [LIVE TELEMETRY]
        \(ctxJSON)

        [RECENT DIALOGUE]
        \(turnsText.isEmpty ? "None" : turnsText)

        [USER QUERY]
        "\(query)"

        Respond with a JSON object matching this exact schema:
        {
          "tool": "tool_name or null",
          "args": {"key": "val"},
          "spoken_response": "1-2 sentence spoken reply to walker"
        }
        """
    }
}

// MARK: - Response Parsing

/// The parsed result of an LLM conversational turn.
public struct ParsedConversationResponse: Sendable, Equatable {
    /// Tool invocation requested by the model, if any.
    public let toolCall: ToolInvocation?
    /// Sanitized spoken response for speech synthesis.
    public let spokenResponse: String

    public init(toolCall: ToolInvocation?, spokenResponse: String) {
        self.toolCall = toolCall
        self.spokenResponse = spokenResponse
    }
}

/// Decodes model wire format and applies safety sanitization.
public enum ConversationResponseParser {

    private struct WireFormat: Decodable {
        var tool: String?
        var args: [String: String]?
        var spoken_response: String?
        var spokenResponse: String?
    }

    /// Parses raw model completion text into structured tool calls and a clean spoken string.
    public static func parse(rawText: String) -> ParsedConversationResponse {
        var cleaned = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code fences if emitted
        if cleaned.hasPrefix("```json") {
            cleaned = String(cleaned.dropFirst(7))
        } else if cleaned.hasPrefix("```") {
            cleaned = String(cleaned.dropFirst(3))
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // If JSON parsing succeeds, decode tool and spoken response
        if let data = cleaned.data(using: .utf8),
           let wire = try? JSONDecoder().decode(WireFormat.self, from: data) {
            let rawSpoken = wire.spoken_response ?? wire.spokenResponse ?? ""
            let safeSpoken = sanitizeSpoken(rawSpoken)

            var invocation: ToolInvocation? = nil
            if let toolName = wire.tool, let tool = ConversationTool(rawValue: toolName) {
                invocation = ToolInvocation(tool: tool, arguments: wire.args ?? [:], resultSummary: safeSpoken)
            }
            return ParsedConversationResponse(toolCall: invocation, spokenResponse: safeSpoken)
        }

        // Graceful fallback for unstructured plain text output
        let fallbackSpoken = sanitizeSpoken(rawText)
        return ParsedConversationResponse(toolCall: nil, spokenResponse: fallbackSpoken)
    }

    /// Sanitizes spoken responses to prevent unsafe promises ("path is clear") and wordiness.
    public static func sanitizeSpoken(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.contains(where: \.isLetter) else { return "I didn't catch that." }

        // Block false all-clear reassurance
        if let promise = CloudSceneGate.reassurance(in: collapsed) {
            return "Caution: unable to confirm \(promise)."
        }

        // Keep to at most 25 words
        let words = collapsed.split(separator: " ").prefix(25)
        var result = words.joined(separator: " ")
        if !result.hasSuffix(".") && !result.hasSuffix("!") && !result.hasSuffix("?") {
            result += "."
        }
        return result
    }
}
