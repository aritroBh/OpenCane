//
//  FastPathIntentClassifier.swift
//  CaneKitLogic
//
//  Deterministic, zero-latency classifier for common voice commands. Runs in < 1 ms with 0 tokens
//  and 0 network overhead.
//
//  Purpose:
//    · Resolves high-confidence operational queries instantly on-device before invoking a cloud LLM.
//    · Supports settings toggles (silence cane, beacon on/off, drop-offs), telemetry status (battery,
//      AirPods, route distance), campus navigation ("take me to CIF"), route stop, and voice markers ("set a post").
//    · Step 62: "take me from A to B" (`.routeFromTo`, rule 13b) and "I'm outside" (`.indoorOutside`,
//      rule 1b) for the indoor-then-outdoor walk (`IndoorRoute.swift`).
//
//  Key invariants:
//    · Pure Foundation only; no side effects.
//    · Returns `nil` when a query is ambiguous, conversational, or visual ("what's in front of me?"),
//      delegating cleanly to the cloud VLM / LLM layer.
//    · First matching rule wins, in the numbered order below — the order is part of the behaviour
//      (5b before 7 so "head nod" is not a headphones question; 2's "unsilence" before "silence").
//    · Matching is lower-cased substring / exact / prefix on the whole query, not word-based, so
//      it has false hits worth knowing (noted per rule). A miss costs a cloud round-trip; a false
//      hit acts, so rules stay narrow.
//    · `updateSetting` option strings must be `HandsFreeOption` raw values ("beacon", "dropOffs",
//      "hazardWatch", "nodToTalk"): the app looks them up with `HandsFreeOption(rawValue:)`.
//
//  Why: Step 23 — answers to "battery?", "stop" or "set a post here" must be instant, work offline
//  and cost no tokens; only open questions go to the network (and scene questions to the camera).
//  Owner / callers: `ConversationCoordinator.handleQuery` (app, main actor) — `classify` first, then
//  `isSceneQuestion`, then the cloud model; `executeAction` performs the result.
//  Rule 0 (Step 56) is the voice shell's grammar (`VoiceMenu`): whole utterances only, before
//  everything else, never sent to the cloud.
//  Tests: `ConversationLogicTests` (`fastPathSettings`, `fastPathStatusAndStop`,
//  `fastPathMarkersAndTrends`, `fastPathCampusNavigation`, `fastPathDelegatesOpenEnded`,
//  `sceneQuestionDetection`, `ivrRuleRunsBeforeEverythingElse`, `stopPhrasesStillStopBehindRuleZero`,
//  `howFarHaveIWalkedIsTheDistanceWalked`, Step 62: `fromAToBIsARouteFromTo`,
//  `fromHereOrHalfARouteIsNotARouteFromTo`, `imOutsideIsTheIndoorHandover`), `VoiceMenuTests` and
//  `NodToTalkFastPathTests` (rule 5b).
//

import Foundation

/// Deterministic classifier that extracts instant actions from common user queries.
public enum FastPathIntentClassifier {

    /// Classifies a cleaned user query into an immediate `ConversationAction`, or `nil` if cloud reasoning is required.
    /// - Parameter query: the recognised or typed text, any case; leading / trailing whitespace and
    ///   the punctuation `. ? ! , " ' ; :` at either end are ignored (not inside the text).
    /// - Returns: the action to perform, or nil (empty query, or no rule matched).
    public static func classify(query: String) -> ConversationAction? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        let cleaned = lower.trimmingCharacters(in: CharacterSet(charactersIn: ".?!,\"';:"))

        // 0. Voice shell (Step 56): the eight menu words or their digits, the three extra verbs
        //    (next / standard / detailed) and yes / no — whole utterance only, through `VoiceMenu`,
        //    so "the route is long" is not a command and "won" is not "one". It runs before the
        //    stop rule, which is safe because no stop phrase is a menu word, verb or confirmation
        //    (`stopIsNotAMenuWord`, `stopPhrasesStillStopBehindRuleZero`).
        if let item = VoiceMenu.match(cleaned) {
            return action(for: item)
        }
        if let verb = VoiceMenu.verb(cleaned) {
            switch verb {
            case .next: return .nextWaypoint
            case .standard: return .setCueLevel(.standard)
            case .detailed: return .setCueLevel(.detailed)
            }
        }
        if let yes = VoiceMenu.confirmation(cleaned) {
            return .confirm(yes)
        }

        // 1. Navigation Escape / Stop — exact phrases only, so "stop the beacon" or "don't stop"
        //    never end a route.
        if cleaned == "stop" || cleaned == "stop route" || cleaned == "stop navigating"
            || cleaned == "stop navigation" || cleaned == "cancel route" || cleaned == "end route" {
            return .stopRoute
        }

        // 1b. Indoor handover (Step 62): "I'm outside" — whole utterance only (a curly apostrophe
        //     from the recogniser counts), so "is it cold outside" is not a handover.
        if outsideForms.contains(cleaned.replacingOccurrences(of: "\u{2019}", with: "'")) {
            return .indoorOutside
        }

        // 2. Settings: Silence / Unsilence Cane Haptics
        if cleaned.contains("unsilence") || cleaned.contains("cane haptics on")
            || cleaned.contains("turn on haptics") || cleaned.contains("resume haptics") {
            return .silenceCane(silenced: false)
        }
        if cleaned.contains("silence cane") || cleaned.contains("quiet cane")
            || cleaned.contains("silence haptics") || cleaned.contains("turn off haptics")
            || cleaned.contains("cane silent") {
            return .silenceCane(silenced: true)
        }

        // 3. Settings: Audio Beacon
        if cleaned == "turn off beacon" || cleaned == "stop beacon" || cleaned == "disable beacon"
            || cleaned == "beacon off" || cleaned == "mute beacon" {
            return .updateSetting(option: "beacon", enabled: false)
        }
        if cleaned == "turn on beacon" || cleaned == "start beacon" || cleaned == "enable beacon"
            || cleaned == "beacon on" {
            return .updateSetting(option: "beacon", enabled: true)
        }

        // 3 matches exact phrases only ("please turn off the beacon" goes to the cloud).
        // 4. Settings: Ground Drop-offs — needs an on/off verb; "detect" counts as on. A drop-off
        //    phrase with no verb falls through to the later rules / the cloud.
        if cleaned.contains("dropoff") || cleaned.contains("drop off") || cleaned.contains("drop-off") {
            if cleaned.contains("turn off") || cleaned.contains("disable") || cleaned.contains("stop") {
                return .updateSetting(option: "dropOffs", enabled: false)
            }
            if cleaned.contains("turn on") || cleaned.contains("enable") || cleaned.contains("start")
                || cleaned.contains("detect") {
                return .updateSetting(option: "dropOffs", enabled: true)
            }
        }

        // 5. Settings: Hazard Watch
        if cleaned.contains("hazard watch") {
            if cleaned.contains("turn off") || cleaned.contains("disable") || cleaned.contains("stop") {
                return .updateSetting(option: "hazardWatch", enabled: false)
            }
            if cleaned.contains("turn on") || cleaned.contains("enable") || cleaned.contains("start") {
                return .updateSetting(option: "hazardWatch", enabled: true)
            }
        }

        // 5b. Settings: Nod to talk (`HandsFreeOption.nodToTalk`). Checked before the AirPods
        //     status rule below, whose "head tracking" trigger would otherwise swallow "head nod".
        //     Pinned by `NodToTalkFastPathTests`.
        if cleaned.contains("nod to talk") || cleaned.contains("head nod") || cleaned.contains("nodding") {
            if cleaned.contains("turn off") || cleaned.contains("disable") || cleaned.contains("stop") {
                return .updateSetting(option: "nodToTalk", enabled: false)
            }
            if cleaned.contains("turn on") || cleaned.contains("enable") || cleaned.contains("start") {
                return .updateSetting(option: "nodToTalk", enabled: true)
            }
        }

        // 6. Status: Battery. ⚠ Substring "charge" also hits unrelated questions ("who is in charge").
        if cleaned.contains("battery") || cleaned.contains("charge") || cleaned.contains("power level") {
            return .answerStatus(aspect: .battery)
        }

        // 7. Status: Headphones / AirPods ("head tracking" is answered with the audio line).
        if cleaned.contains("airpod") || cleaned.contains("headphone") || cleaned.contains("head tracking") {
            return .answerStatus(aspect: .headphones)
        }

        // 12. History & Trends: Distance Walked — checked before rule 8 (Step 56), whose "how far"
        //     substring used to swallow "how far have I walked" (`howFarHaveIWalkedIsTheDistanceWalked`).
        if cleaned.contains("how far have i walked") || cleaned.contains("distance walked")
            || cleaned.contains("how long have we been walking") {
            return .answerHistory(metric: .distanceWalked, windowSeconds: nil)
        }

        // 8. Status: Route Progress / Distance to Next Point. "how far have I walked" never reaches
        //    here: rule 12 runs first.
        if cleaned.contains("how far") || cleaned.contains("distance to next") || cleaned.contains("where am i going")
            || cleaned.contains("next instruction") || cleaned.contains("current route") {
            return .answerStatus(aspect: .route)
        }

        // 9. Status: Overall System Health ("how is OpenCane doing", "status")
        //    The bare "status" / "status check" / "check status" are rule 0 (`.speakStatus`) now.
        if cleaned.contains("how are you doing")
            || cleaned.contains("how is opencane doing") || cleaned.contains("how is canekit doing")
            || cleaned == "is everything working" {
            return .answerStatus(aspect: .all)
        }

        // 10. Voice Markers / Posts ("set a post here", "mark this spot"). The name is the text
        //     after "called " / "named ", else after the first "as " (⚠ a substring, so "has " also
        //     matches), `.capitalized` from the lower-cased query; "Marker" when none is given.
        //     The app appends no number to "Marker" on this path (the cloud tool uses "Marker N").
        if cleaned.contains("set a post") || cleaned.contains("drop a post") || cleaned.contains("mark this spot")
            || cleaned.contains("drop a pin") || cleaned.contains("drop a marker") || cleaned.contains("set a marker") {
            var markerName = "Marker"
            if let range = cleaned.range(of: "called ") ?? cleaned.range(of: "named ") {
                let suffix = String(cleaned[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !suffix.isEmpty {
                    markerName = suffix.capitalized
                }
            } else if let range = cleaned.range(of: "as ") {
                let suffix = String(cleaned[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !suffix.isEmpty {
                    markerName = suffix.capitalized
                }
            }
            return .recordMarker(name: markerName)
        }

        // 11. History & Trends: Steps
        if cleaned.contains("how many steps") || cleaned.contains("step count") || cleaned.contains("steps walked")
            || cleaned.contains("steps so far") {
            return .answerHistory(metric: .steps, windowSeconds: nil)
        }

        // 13. History & Trends: Hazards Encountered
        if cleaned.contains("what hazards") || cleaned.contains("hazards encountered")
            || cleaned.contains("any hazards on this walk") {
            return .answerHistory(metric: .hazardsEncountered, windowSeconds: nil)
        }

        // 13b. From A to B (Step 62) — before rule 14, whose prefixes would otherwise swallow
        //      "navigate to CIF from ISR". See `routeFromTo(_:)`.
        if let fromTo = routeFromTo(trimmed) {
            return fromTo
        }

        // 14. Campus Navigation via Gazetteer ("set location to X" is how walkers say it on
        // the phone — a recogniser hears "set", not "take", half the time).
        // A gazetteer hit returns the place's spoken `name` (not its id), and `AppModel.navigate(to:)`
        // re-matches it (every name is an alias since Step 62, `everyCampusPlaceNameRoundTripsThroughMatch`).
        // Any other target after a prefix starts a route to `target.capitalized` through MapKit
        // (⚠ "go to settings" becomes a place search).
        for prefix in destinationPrefixes {
            if cleaned.hasPrefix(prefix) {
                let target = String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if let action = destinationAction(target) {
                    return action
                }
            }
        }

        return nil
    }

    /// Rule 1b's whole utterances (lower case, edge punctuation trimmed, curly apostrophe folded).
    /// Kept narrow: a false hit hands the walker to GPS guidance while still inside.
    static let outsideForms: Set<String> = [
        "i'm outside", "im outside", "i am outside", "we're outside", "we are outside",
        "outside now", "i'm outside now", "i am outside now", "we're outside now",
    ]

    /// Rule 14's destination prefixes (lower case, trailing space). Rule 13b splits "<prefix> B from
    /// A" after every one of them (Muse M3). Pinned by `everyDestinationPrefixTakesAFromOrigin`.
    public static let destinationPrefixes = ["take me to ", "route to ", "navigate to ", "go to ", "walk to ",
                                      "set destination to ", "set location to ", "change destination to ",
                                      "set my destination to "]

    /// Rule 13b's origins that mean "where I am", compared after `CampusPlaces.normalize`: a route
    /// from here is a plain rule-14 route, never an indoor script.
    static let hereOrigins: Set<String> = [
        "here", "right here", "my location", "my current location", "current location",
        "this location", "where i am",
    ]

    /// Rule 13b (Step 62): "take me from A to B", "go from A to B", "navigate from A to B",
    /// "from A to B" (split at the first " to ") and "<any `destinationPrefixes`> B from A" —
    /// "take me to / navigate to / go to / walk to / set destination to … B from A" (split at the
    /// last " from "; Muse M3, it was "take me to" only). Both ends keep the speaker's case, edge
    /// whitespace / punctuation trimmed; either end empty → nil (the later rules run). A "here"
    /// origin (`hereOrigins`) → `destinationAction(to)`. ⚠ A destination that itself contains
    /// " from " ("across from the Union") splits there too.
    /// Pinned by `fromAToBIsARouteFromTo`, `fromHereOrHalfARouteIsNotARouteFromTo`,
    /// `everyDestinationPrefixTakesAFromOrigin`.
    /// - Parameter query: the whitespace-trimmed query, original case.
    /// - Returns: `.routeFromTo`, `.startRoute` for a "here" origin, or nil.
    static func routeFromTo(_ query: String) -> ConversationAction? {
        let edge = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".?!,\"';:"))
        let text = query.trimmingCharacters(in: edge)
        func clean(_ part: Substring) -> String { String(part).trimmingCharacters(in: edge) }
        var from = "", to = ""
        if let prefix = destinationPrefixes.lazy
                .compactMap({ text.range(of: $0, options: [.anchored, .caseInsensitive]) }).first,
           let split = text.range(of: " from ", options: [.caseInsensitive, .backwards],
                                  range: prefix.upperBound..<text.endIndex) {
            to = clean(text[prefix.upperBound..<split.lowerBound])
            from = clean(text[split.upperBound...])
        } else if let prefix = ["take me from ", "go from ", "navigate from ", "from "].lazy
                    .compactMap({ text.range(of: $0, options: [.anchored, .caseInsensitive]) }).first,
                  let split = text.range(of: " to ", options: .caseInsensitive,
                                         range: prefix.upperBound..<text.endIndex) {
            from = clean(text[prefix.upperBound..<split.lowerBound])
            to = clean(text[split.upperBound...])
        } else {
            return nil
        }
        guard !from.isEmpty, !to.isEmpty else { return nil }
        if hereOrigins.contains(CampusPlaces.normalize(from)) { return destinationAction(to) }
        return .routeFromTo(from: from, to: to)
    }

    /// Rule 14's destination: a gazetteer hit → `.startRoute` with the place's spoken `name`;
    /// any other non-empty target → `.startRoute(target.capitalized)` (MapKit); empty → nil.
    /// Callers: rule 14, and rule 13b for a "from here" origin.
    static func destinationAction(_ target: String) -> ConversationAction? {
        if let place = CampusPlaces.match(target) { return .startRoute(destination: place.name) }
        return target.isEmpty ? nil : .startRoute(destination: target.capitalized)
    }

    /// Rule 0's mapping from a menu item to the action the coordinator performs. "where am I" and
    /// "describe" are the same camera path; "quiet" is the cue level.
    /// - Parameter item: the matched `VoiceMenu.Item`.
    /// - Returns: the voice shell action.
    public static func action(for item: VoiceMenu.Item) -> ConversationAction {
        switch item {
        case .route: return .startDefaultRoute
        case .whereAmI, .describe: return .describeScene
        case .status: return .speakStatus
        case .repeatLast: return .repeatInstruction
        case .quiet: return .setCueLevel(.quiet)
        case .help: return .help
        case .emergency: return .emergency
        }
    }

    /// Whether a query the fast path left over is about what the camera can see, so that with no
    /// cloud model (`VLMClient.cloudPrimary == nil`) it can still be answered by `askAboutScene`
    /// instead of the "I need a network model" line. Caller: `ConversationCoordinator.handleQuery`.
    /// ⚠ It runs BEFORE the cloud client is consulted, so a scene question always takes the
    /// camera path (grounded by `CloudSceneGate`), even when a cloud conversation model exists.
    /// Pinned by `sceneQuestionDetection`.
    /// ponytail: plain substring match; "see" also hits "seen"/"seems". Upgrade path is
    /// word-boundary matching if a real transcript is misrouted.
    public static func isSceneQuestion(_ query: String) -> Bool {
        let lower = query.lowercased()
        return ["in front", "ahead", "around me", "see", "look", "scene", "describe", "is there",
                "sign", "read", "what is this", "what's this"].contains { lower.contains($0) }
    }
}
