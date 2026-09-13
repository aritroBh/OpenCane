//
//  ConversationLogicTests.swift
//  CaneKitLogicTests
//
//  Unit tests for the conversational assistant, memory history, fast-path intent classifier,
//  and response parser. Pure Foundation logic using Swift Testing.
//
//  Sources pinned: `ConversationModels.swift` (`WalkMarker`, `ConversationTurn`,
//  `ConversationHistory` ring buffer), `FastPathIntentClassifier.swift` (`classify`,
//  `isSceneQuestion`) and `ConversationPrompt.swift` (`ConversationPrompt.buildUserPrompt`,
//  `ConversationResponseParser.parse`). The classifier's "Nod to talk" rule is pinned separately in
//  `NodToTalkFastPathTests.swift`. (There is no separate `ConversationPromptTests` or
//  `FastPathIntentClassifierTests` file: those tests live here.)
//  Caller of everything pinned here: `ConversationCoordinator` (app); the dropped markers are
//  persisted by `PostStore` (app) as `[WalkMarker]` JSON.
//
//  Breaks these catch: the posts file (`Documents/posts/posts.json`) no longer decoding after a
//  `WalkMarker` change; the history growing past `maxTurns` (prompt cost) or losing the tool /
//  latency update on the newest turn; a settings / stop / status / marker / campus phrase falling
//  through to the cloud model (latency and tokens) or, the reverse, an open-ended or visual question
//  being swallowed by the fast path; the prompt losing its telemetry or its "CRITICAL RULES" block;
//  a model reply that says the path is "clear" or "safe" reaching speech unchanged; and a
//  plain-text (non-JSON) reply being dropped instead of spoken.
//

import CaneKitLogic
import Foundation
import Testing

/// One suite for the whole conversational pipeline, in pipeline order: models → history →
/// fast path → prompt → response parser. Stateless: every test builds its own values.
@Suite("Conversational Agent Logic")
struct ConversationLogicTests {

    @Test("WalkMarker stores coordinate, name, and timestamp")
    func walkMarkerCreation() {
        let coord = Coordinate(latitude: 40.1138, longitude: -88.2249)
        let marker = WalkMarker(name: "Townsend Entrance", coordinate: coord, timestamp: 1700000000)

        #expect(marker.name == "Townsend Entrance")
        #expect(marker.coordinate.latitude == 40.1138)
        #expect(marker.coordinate.longitude == -88.2249)
        #expect(marker.timestamp == 1700000000)
    }

    /// Pins the on-disk shape of Documents/posts/posts.json (PostStore writes `[WalkMarker]` with
    /// a plain JSONEncoder): a fixed UUID and a (0, 0) "GPS weak" post must both survive the trip.
    @Test("[WalkMarker] survives a JSON round-trip with its UUID")
    func walkMarkerJSONRoundTrip() throws {
        let id = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
        let posts = [
            WalkMarker(id: id, name: "Townsend Door", coordinate: Coordinate(latitude: 40.1138, longitude: -88.2249), timestamp: 1700000000),
            WalkMarker(name: "Marker 2", coordinate: Coordinate(latitude: 0, longitude: 0), timestamp: 1700000060)
        ]

        let data = try JSONEncoder().encode(posts)
        let decoded = try JSONDecoder().decode([WalkMarker].self, from: data)

        #expect(decoded == posts)
        #expect(decoded[0].id == id)
    }

    @Test("ConversationHistory respects maxTurns ring buffer limit")
    func historyRingBuffer() {
        var history = ConversationHistory(maxTurns: 3)
        #expect(history.turns.isEmpty)

        for i in 1...5 {
            history.append(turn: ConversationTurn(
                timestamp: Double(i),
                userQuery: "Query \(i)",
                agentResponse: "Response \(i)"
            ))
        }

        #expect(history.turns.count == 3)
        #expect(history.turns[0].userQuery == "Query 3")
        #expect(history.turns[1].userQuery == "Query 4")
        #expect(history.turns[2].userQuery == "Query 5")

        history.updateLastResponse("Updated 5", tools: [
            ToolInvocation(tool: .queryStatus, arguments: [:], resultSummary: "ok")
        ], latencyMs: 150)

        #expect(history.turns[2].agentResponse == "Updated 5")
        #expect(history.turns[2].toolsInvoked.count == 1)
        #expect(history.turns[2].latencyMs == 150)

        history.clear()
        #expect(history.turns.isEmpty)
    }

    @Test("FastPath classifies settings toggles instantly")
    func fastPathSettings() {
        #expect(FastPathIntentClassifier.classify(query: "silence cane") == .silenceCane(silenced: true))
        #expect(FastPathIntentClassifier.classify(query: "quiet cane please") == .silenceCane(silenced: true))
        #expect(FastPathIntentClassifier.classify(query: "unsilence cane") == .silenceCane(silenced: false))
        #expect(FastPathIntentClassifier.classify(query: "cane haptics on") == .silenceCane(silenced: false))

        #expect(FastPathIntentClassifier.classify(query: "turn off beacon") == .updateSetting(option: "beacon", enabled: false))
        #expect(FastPathIntentClassifier.classify(query: "beacon on") == .updateSetting(option: "beacon", enabled: true))

        #expect(FastPathIntentClassifier.classify(query: "detect dropoffs") == .updateSetting(option: "dropOffs", enabled: true))
        #expect(FastPathIntentClassifier.classify(query: "turn off drop offs") == .updateSetting(option: "dropOffs", enabled: false))
    }

    @Test("FastPath classifies status, stops, and telemetry")
    func fastPathStatusAndStop() {
        #expect(FastPathIntentClassifier.classify(query: "stop") == .stopRoute)
        #expect(FastPathIntentClassifier.classify(query: "stop navigating") == .stopRoute)
        #expect(FastPathIntentClassifier.classify(query: "stop route") == .stopRoute)

        #expect(FastPathIntentClassifier.classify(query: "battery level") == .answerStatus(aspect: .battery))
        #expect(FastPathIntentClassifier.classify(query: "are my airpods connected") == .answerStatus(aspect: .headphones))
        #expect(FastPathIntentClassifier.classify(query: "how far to next point") == .answerStatus(aspect: .route))
        #expect(FastPathIntentClassifier.classify(query: "how is OpenCane doing") == .answerStatus(aspect: .all))
    }

    @Test("FastPath parses voice markers and trends")
    func fastPathMarkersAndTrends() {
        let marker1 = FastPathIntentClassifier.classify(query: "set a post here")
        #expect(marker1 == .recordMarker(name: "Marker"))

        let marker2 = FastPathIntentClassifier.classify(query: "set a post called Townsend Door")
        #expect(marker2 == .recordMarker(name: "Townsend Door"))

        #expect(FastPathIntentClassifier.classify(query: "how many steps have I walked") == .answerHistory(metric: .steps, windowSeconds: nil))
        #expect(FastPathIntentClassifier.classify(query: "distance walked so far") == .answerHistory(metric: .distanceWalked, windowSeconds: nil))
        #expect(FastPathIntentClassifier.classify(query: "any hazards on this walk") == .answerHistory(metric: .hazardsEncountered, windowSeconds: nil))
    }

    @Test("FastPath resolves campus destinations via gazetteer")
    func fastPathCampusNavigation() {
        #expect(FastPathIntentClassifier.classify(query: "take me to CIF") == .startRoute(destination: "the CIF east entrance"))
        #expect(FastPathIntentClassifier.classify(query: "route to Grainger") == .startRoute(destination: "Grainger Engineering Library"))
        #expect(FastPathIntentClassifier.classify(query: "navigate to Townsend Hall") == .startRoute(destination: "the Townsend Hall doors"))
        #expect(FastPathIntentClassifier.classify(query: "set location to Grainger") == .startRoute(destination: "Grainger Engineering Library"))
        #expect(FastPathIntentClassifier.classify(query: "set destination to Sift") == .startRoute(destination: "the Siebel Center"))
        #expect(FastPathIntentClassifier.classify(query: "take me to Granger Library") == .startRoute(destination: "Grainger Engineering Library"))
    }

    /// Rule 0 (Step 56): the eight menu words, their digits, the three extra verbs and yes / no are
    /// matched as whole utterances through `VoiceMenu` before any other rule, and map to the voice
    /// shell's actions. "route" alone is the CIF demo route; "take me to …" still reaches any place.
    @Test func ivrRuleRunsBeforeEverythingElse() {
        #expect(FastPathIntentClassifier.classify(query: "route") == .startDefaultRoute)
        #expect(FastPathIntentClassifier.classify(query: "1") == .startDefaultRoute)
        #expect(FastPathIntentClassifier.classify(query: "one") == .startDefaultRoute)
        #expect(FastPathIntentClassifier.classify(query: "where am i") == .describeScene)
        #expect(FastPathIntentClassifier.classify(query: "Where am I?") == .describeScene)
        #expect(FastPathIntentClassifier.classify(query: "2") == .describeScene)
        #expect(FastPathIntentClassifier.classify(query: "describe") == .describeScene)
        #expect(FastPathIntentClassifier.classify(query: "status") == .speakStatus)
        #expect(FastPathIntentClassifier.classify(query: "4") == .speakStatus)
        #expect(FastPathIntentClassifier.classify(query: "check status") == .speakStatus)
        #expect(FastPathIntentClassifier.classify(query: "repeat") == .repeatInstruction)
        #expect(FastPathIntentClassifier.classify(query: "say again") == .repeatInstruction)
        #expect(FastPathIntentClassifier.classify(query: "quiet") == .setCueLevel(.quiet))
        #expect(FastPathIntentClassifier.classify(query: "6") == .setCueLevel(.quiet))
        #expect(FastPathIntentClassifier.classify(query: "standard") == .setCueLevel(.standard))
        #expect(FastPathIntentClassifier.classify(query: "detailed cues") == .setCueLevel(.detailed))
        #expect(FastPathIntentClassifier.classify(query: "next") == .nextWaypoint)
        #expect(FastPathIntentClassifier.classify(query: "help") == .help)
        #expect(FastPathIntentClassifier.classify(query: "7") == .help)
        #expect(FastPathIntentClassifier.classify(query: "emergency") == .emergency)
        #expect(FastPathIntentClassifier.classify(query: "eight") == .emergency)
        #expect(FastPathIntentClassifier.classify(query: "yes") == .confirm(true))
        #expect(FastPathIntentClassifier.classify(query: "No.") == .confirm(false))
        #expect(FastPathIntentClassifier.classify(query: "cancel") != .confirm(false))   // not a refusal
        // Place routes are unchanged by rule 0.
        #expect(FastPathIntentClassifier.classify(query: "take me to CIF") == .startRoute(destination: "the CIF east entrance"))
        #expect(FastPathIntentClassifier.classify(query: "route to CIF") == .startRoute(destination: "the CIF east entrance"))
        // Homophones and sentences that merely contain a menu word are not rule 0.
        #expect(FastPathIntentClassifier.classify(query: "won") == nil)
        #expect(FastPathIntentClassifier.classify(query: "what is the weather") == nil)
    }

    /// Rule 0 sits in front of the stop rule, so every stop phrase must still stop — none of them is
    /// a menu word, verb or confirmation (`VoiceMenuTests.stopIsNotAMenuWord`).
    @Test func stopPhrasesStillStopBehindRuleZero() {
        for phrase in ["stop", "Stop.", "stop route", "stop navigating", "stop navigation", "cancel route", "end route"] {
            #expect(FastPathIntentClassifier.classify(query: phrase) == .stopRoute, "\(phrase)")
        }
    }

    /// Rule 12 is checked before rule 8 (Step 56): "how far have I walked" is the distance walked,
    /// not the distance to the next point; "how far to next point" is still the route clause.
    @Test func howFarHaveIWalkedIsTheDistanceWalked() {
        #expect(FastPathIntentClassifier.classify(query: "how far have I walked") == .answerHistory(metric: .distanceWalked, windowSeconds: nil))
        #expect(FastPathIntentClassifier.classify(query: "how far to next point") == .answerStatus(aspect: .route))
    }

    /// Step 62: "from A to B" in its five spoken forms is an indoor-then-outdoor route request with
    /// both ends as said (case kept, punctuation and spaces trimmed); the coordinator matches them.
    @Test func fromAToBIsARouteFromTo() {
        #expect(FastPathIntentClassifier.classify(query: "Take me from ISR to CIF.") == .routeFromTo(from: "ISR", to: "CIF"))
        #expect(FastPathIntentClassifier.classify(query: "from the lab to Grainger") == .routeFromTo(from: "the lab", to: "Grainger"))
        #expect(FastPathIntentClassifier.classify(query: "go from Townsend Hall to the Illini Union")
                == .routeFromTo(from: "Townsend Hall", to: "the Illini Union"))
        #expect(FastPathIntentClassifier.classify(query: "navigate from ISR lab to CIF") == .routeFromTo(from: "ISR lab", to: "CIF"))
        #expect(FastPathIntentClassifier.classify(query: "take me to CIF from ISR") == .routeFromTo(from: "ISR", to: "CIF"))
        #expect(FastPathIntentClassifier.classify(query: "take me to the office from the lab")
                == .routeFromTo(from: "the lab", to: "the office"))
    }

    /// "from here" is no origin: the plain rule-14 route. Half a request is not one, and a
    /// "take me to" with no "from" is unchanged.
    @Test func fromHereOrHalfARouteIsNotARouteFromTo() {
        #expect(FastPathIntentClassifier.classify(query: "take me to CIF from here") == .startRoute(destination: "the CIF east entrance"))
        #expect(FastPathIntentClassifier.classify(query: "from here to Grainger") == .startRoute(destination: "Grainger Engineering Library"))
        #expect(FastPathIntentClassifier.classify(query: "from my location to Grainger") == .startRoute(destination: "Grainger Engineering Library"))
        #expect(FastPathIntentClassifier.classify(query: "from ISR") == nil)
        #expect(FastPathIntentClassifier.classify(query: "from ISR to") == nil)
        #expect(FastPathIntentClassifier.classify(query: "take me from ISR") == nil)
        #expect(FastPathIntentClassifier.classify(query: "take me to CIF") == .startRoute(destination: "the CIF east entrance"))
        #expect(FastPathIntentClassifier.classify(query: "route") == .startDefaultRoute)
    }

    /// Muse M3: "B from A" works after every rule-14 prefix, not only "take me to" ("navigate to CIF
    /// from ISR" used to become a MapKit search for "Cif From Isr"); "from here" stays a plain route.
    @Test func everyDestinationPrefixTakesAFromOrigin() {
        for prefix in ["take me to", "route to", "navigate to", "go to", "walk to", "set destination to",
                       "set location to", "change destination to", "set my destination to"] {
            #expect(FastPathIntentClassifier.classify(query: "\(prefix) CIF from ISR")
                    == .routeFromTo(from: "ISR", to: "CIF"), "\(prefix)")
            #expect(FastPathIntentClassifier.classify(query: "\(prefix) CIF from here")
                    == .startRoute(destination: "the CIF east entrance"), "\(prefix)")
        }
        #expect(FastPathIntentClassifier.destinationPrefixes.count == 9)
    }

    /// Step 62: "I'm outside" (whole utterance, straight or curly apostrophe) is the walker's indoor
    /// handover; a sentence that merely contains "outside" is not.
    @Test func imOutsideIsTheIndoorHandover() {
        for phrase in ["I'm outside", "I’m outside.", "im outside", "I am outside", "we're outside",
                       "we are outside", "outside now", "I'm outside now"] {
            #expect(FastPathIntentClassifier.classify(query: phrase) == .indoorOutside, "\(phrase)")
        }
        #expect(FastPathIntentClassifier.classify(query: "outside") == nil)
        #expect(FastPathIntentClassifier.classify(query: "is it cold outside") == nil)
        #expect(FastPathIntentClassifier.classify(query: "stop") == .stopRoute)
    }

    @Test("FastPath leaves open-ended and visual queries for LLM")
    func fastPathDelegatesOpenEnded() {
        #expect(FastPathIntentClassifier.classify(query: "what is in front of me") == nil)
        #expect(FastPathIntentClassifier.classify(query: "is there a bench on my left") == nil)
        #expect(FastPathIntentClassifier.classify(query: "read that sign") == nil)
        #expect(FastPathIntentClassifier.classify(query: "tell me about this building") == nil)
    }

    /// With no cloud key the coordinator can only answer what the camera sees; this decides which
    /// of the queries the fast path left over go to `askAboutScene` and which get the "I need a
    /// network model" line. ⚠ Pins `ConversationCoordinator.handleQuery`'s no-cloud branch.
    @Test("Scene questions are told apart from ones that need a network model")
    func sceneQuestionDetection() {
        #expect(FastPathIntentClassifier.isSceneQuestion("what is in front of me"))
        #expect(FastPathIntentClassifier.isSceneQuestion("Is there a bench on my left?"))
        #expect(FastPathIntentClassifier.isSceneQuestion("read that sign"))
        #expect(FastPathIntentClassifier.isSceneQuestion("describe the scene"))
        #expect(FastPathIntentClassifier.isSceneQuestion("what do you see ahead"))
        #expect(FastPathIntentClassifier.isSceneQuestion("what's around me"))

        #expect(!FastPathIntentClassifier.isSceneQuestion("what time is it"))
        #expect(!FastPathIntentClassifier.isSceneQuestion("tell me a joke"))
        #expect(!FastPathIntentClassifier.isSceneQuestion("how long until the bus comes"))
        #expect(!FastPathIntentClassifier.isSceneQuestion(""))
    }

    @Test("ConversationPrompt formats telemetry and enforces safety rules")
    func promptConstruction() {
        let ctx = ConversationContext(
            currentDestination: "Campus Instructional Facility",
            nextWaypointName: "Turn right onto Springfield",
            distanceToNextMeters: 45,
            isNavigating: true,
            batteryPercent: 88,
            headphonesConnected: true,
            headphoneName: "AirPods Pro",
            distanceWalkedM: 320,
            steps: 450
        )

        var history = ConversationHistory()
        history.append(turn: ConversationTurn(timestamp: 100, userQuery: "Where are we?", agentResponse: "Walking to CIF."))

        let prompt = ConversationPrompt.buildUserPrompt(query: "How many steps?", context: ctx, history: history)

        #expect(prompt.contains("Campus Instructional Facility"))
        #expect(prompt.contains("Turn right onto Springfield"))
        #expect(prompt.contains("450"))
        #expect(prompt.contains("AirPods Pro"))
        #expect(prompt.contains("User: Where are we?"))
        #expect(prompt.contains("CRITICAL RULES"))
    }

    @Test("ConversationResponseParser decodes structured JSON tools and spoken response")
    func responseParserJSON() {
        let raw = """
        ```json
        {
          "tool": "navigate_to",
          "args": {"destination": "Grainger Library"},
          "spoken_response": "Starting walking route to Grainger Library."
        }
        ```
        """

        let parsed = ConversationResponseParser.parse(rawText: raw)
        #expect(parsed.toolCall != nil)
        #expect(parsed.toolCall?.tool == .navigateTo)
        #expect(parsed.toolCall?.arguments["destination"] == "Grainger Library")
        #expect(parsed.spokenResponse == "Starting walking route to Grainger Library.")
    }

    @Test("ConversationResponseParser sanitizes false safety reassurance")
    func responseParserReassuranceSanitization() {
        let raw = """
        {
          "tool": null,
          "spoken_response": "The path is clear and safe to walk."
        }
        """

        let parsed = ConversationResponseParser.parse(rawText: raw)
        #expect(parsed.toolCall == nil)
        // Reassurance words ("clear", "safe") must be sanitized
        #expect(parsed.spokenResponse.contains("Caution: unable to confirm"))
    }

    @Test("ConversationResponseParser handles unstructured plain text gracefully")
    func responseParserPlainTextFallback() {
        let raw = "You have walked 450 steps so far."
        let parsed = ConversationResponseParser.parse(rawText: raw)
        #expect(parsed.toolCall == nil)
        #expect(parsed.spokenResponse == "You have walked 450 steps so far.")
    }
}
