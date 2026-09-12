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
//  Why it exists: a query the deterministic `FastPathIntentClassifier` cannot answer (and that is not
//  a scene question) goes to the cloud model. The reply is spoken to a walker mid-route, so it has
//  to be short, may trigger an app action, and must never promise that the way is clear.
//
//  Owner / callers: `ConversationCoordinator.handleQuery` (app, main actor) builds the prompt with
//  `buildUserPrompt`, sends it with a camera JPEG through `VLMClient.cloudPrimary.describe(jpeg:prompt:)`
//  (every provider takes ONE prompt string, so the system instruction is inlined, not a system
//  role), parses the reply with `ConversationResponseParser.parse`, runs `ToolInvocation`s through
//  `executeTool`, and speaks `spokenResponse` at `.scene` priority (lowest band).
//
//  Key invariants:
//    · Pure Foundation only; no networking or keys here.
//    · Enforces strict anti-slop rules (< 25 words, no pleasantries, never say safe/clear).
//    · The reassurance filter is `CloudSceneGate.reassurance(in:)` — the same table the scene gate
//      and the hazard watch use, so no path can promise a clear way another path refuses.
//    · ⚠ Tool names are `ConversationTool` raw values; the declarations below must match them.
//  Tests: `ConversationLogicTests.swift` (`promptConstruction`, `responseParserJSON`,
//  `responseParserReassuranceSanitization`, `responseParserPlainTextFallback`).
//

import Foundation

// MARK: - Prompt Construction

/// Builds the system and user prompt strings for the conversational agent.
public enum ConversationPrompt {

    /// System instruction establishing persona, voice constraints, and safety bans.
    /// Inlined at the top of every `buildUserPrompt` result. The 25-word rule is also enforced in
    /// code (`ConversationResponseParser.sanitizeSpoken`), because a model's compliance is a hope.
    /// Pinned (the "CRITICAL RULES" header) by `promptConstruction`.
    public static let systemInstruction: String = """
    You are OpenCane, an intelligent navigation assistant clamped to a white cane for a blind pedestrian.
    Your replies are SPOKEN via headphones while the user is actively walking.

    CRITICAL RULES:
    1. Maximum 1-2 short sentences (under 25 words total). Brevity is vital for situational awareness.
    2. Never invent distances or counts. Distances must come ONLY from context or tools.
    3. Never say the path is "clear", "empty", or "safe".
    4. For a scene answer, mention at most two useful or actionable visible items and omit background detail.
    5. Speak directly. No conversational filler, pleasantries, or preamble.
    6. When executing a tool, declare it in the "tool" and "args" fields.
    """

    /// Declarations of available tools for LLM reasoning.
    ///
    /// ⚠ Known mismatches with the app, left as they are (documentation only):
    ///   · `ToolInvocation.arguments` decodes as `[String: String]`, so a model that follows
    ///     `"enabled": "boolean"` / `"silenced": "boolean"` literally and sends a JSON `true` makes
    ///     the whole reply fail to decode: no tool runs and the raw reply text is spoken through
    ///     `sanitizeSpoken` instead. Only string "true" / "false" works.
    ///   · `set_setting`'s `option` must be a `HandsFreeOption` raw value ("beacon", "dropOffs", …),
    ///     which the model is never told; any other string is ignored by `executeTool`.
    ///   · `query_status` lists no "haptics" and `query_history` says "distance|hazards", not the
    ///     `HistoryMetric` raw values — harmless today because `executeTool` does not act on either
    ///     tool (the model's spoken reply is the whole answer).
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
    ///
    /// Layout: `systemInstruction`, `[TOOLS]`, `[LIVE TELEMETRY]` (a sorted-key JSON object),
    /// `[RECENT DIALOGUE]` (the last 3 turns of `history`, "None" when empty), `[USER QUERY]`, then
    /// the required reply schema `{"tool", "args", "spoken_response"}`.
    /// Telemetry keys written, each only when known: `destination`, `next_waypoint`,
    /// `meters_to_next`, `battery` ("88%", omitted for −1), `headphones` (the output name, or
    /// "none"), `steps`, `distance_walked_m` (omitted for 0), `recent_hazard` (the last hazard's
    /// description only), `saved_markers` (comma-joined names). Nothing else in the context is sent.
    /// - Parameters:
    ///   - query: the walker's words, quoted verbatim (not escaped).
    ///   - context: `ConversationCoordinator.buildContext()`.
    ///   - history: memory BEFORE this turn — the coordinator appends the current turn after the reply.
    /// - Returns: one prompt string for `VLMClient.describe(jpeg:prompt:)`. Pinned by `promptConstruction`.
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

        // Sorted keys: the same context always yields byte-identical prompt text. An encode
        // failure (never expected for [String: String]) degrades to "{}", never a throw.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let ctxJSON = (try? encoder.encode(ctxDict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        // Only the last 3 turns: the window holds 6, but every extra turn is prompt tokens and
        // latency on a walker's question.
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
    /// Tool invocation requested by the model, if any. nil for `"tool": null`, an unknown tool
    /// name, or a reply that was not decodable JSON.
    public let toolCall: ToolInvocation?
    /// Sanitized spoken response for speech synthesis. Never empty ("I didn't catch that." when
    /// nothing speakable came back).
    public let spokenResponse: String

    /// Memberwise; built by `ConversationResponseParser.parse`.
    public init(toolCall: ToolInvocation?, spokenResponse: String) {
        self.toolCall = toolCall
        self.spokenResponse = spokenResponse
    }
}

/// Decodes model wire format and applies safety sanitization.
public enum ConversationResponseParser {

    /// The reply schema requested by `buildUserPrompt`. Every field is optional so a partial
    /// reply still decodes; `spokenResponse` accepts camel-case from models that "correct" the
    /// snake-case key. ⚠ `args` is `[String: String]`: any non-string value fails the whole decode.
    private struct WireFormat: Decodable {
        /// A `ConversationTool` raw value, or null / absent for no tool.
        var tool: String?
        /// Tool arguments as strings.
        var args: [String: String]?
        /// The requested key for the line to speak.
        var spoken_response: String?
        /// Tolerated camel-case spelling of the same field.
        var spokenResponse: String?
    }

    /// Parses raw model completion text into structured tool calls and a clean spoken string.
    ///
    /// 1. Trim; strip one leading "```json" or "```" and one trailing "```" (exact, case-sensitive —
    ///    "```JSON" leaves "JSON" in front and the decode fails).
    /// 2. Decode `WireFormat`. On success: speak `sanitizeSpoken(spoken_response ?? spokenResponse
    ///    ?? "")`, and build a `ToolInvocation` when `tool` is a known name (its `resultSummary` is
    ///    the sanitized line).
    /// 3. Otherwise treat the ORIGINAL `rawText` (fences included) as plain speech, sanitized, with
    ///    no tool. Pinned by `responseParserJSON`, `responseParserPlainTextFallback`.
    /// - Parameter rawText: the provider's completion text.
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
    ///
    /// Rules, in order: collapse whitespace; no letters → "I didn't catch that."; any
    /// `CloudSceneGate.reassurance(in:)` hit → the WHOLE reply becomes "Caution: unable to confirm
    /// <promise>." (e.g. "… confirm clear."; a harmless "nothing" or "safely" trips it too, and a
    /// tool call in the same reply still runs); else the first 25 words, with "." added unless it
    /// already ends in ". ! ?". Pinned by `responseParserReassuranceSanitization`.
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
