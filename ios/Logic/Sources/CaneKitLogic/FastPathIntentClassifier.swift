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
//  Tests: `ConversationLogicTests` (`fastPathSettings`, `fastPathStatusAndStop`,
//  `fastPathMarkersAndTrends`, `fastPathCampusNavigation`, `fastPathDelegatesOpenEnded`,
//  `sceneQuestionDetection`) and `NodToTalkFastPathTests` (rule 5b).
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

        // 1. Navigation Escape / Stop — exact phrases only, so "stop the beacon" or "don't stop"
        //    never end a route.
        if cleaned == "stop" || cleaned == "stop route" || cleaned == "stop navigating"
            || cleaned == "stop navigation" || cleaned == "cancel route" || cleaned == "end route" {
            return .stopRoute
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

        // 8. Status: Route Progress / Distance to Next Point. ⚠ "how far" also swallows
        //    "how far have I walked", so rule 12's copy of that phrase is unreachable today (the
        //    walker hears the distance to the next point, not the distance walked).
        if cleaned.contains("how far") || cleaned.contains("distance to next") || cleaned.contains("where am i going")
            || cleaned.contains("next instruction") || cleaned.contains("current route") {
            return .answerStatus(aspect: .route)
        }

        // 9. Status: Overall System Health ("how is OpenCane doing", "status")
        if cleaned == "status" || cleaned == "status check" || cleaned.contains("how are you doing")
            || cleaned.contains("how is opencane doing") || cleaned.contains("how is canekit doing")
            || cleaned == "is everything working" || cleaned == "check status" {
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

        // 12. History & Trends: Distance Walked
        if cleaned.contains("how far have i walked") || cleaned.contains("distance walked")
            || cleaned.contains("how long have we been walking") {
            return .answerHistory(metric: .distanceWalked, windowSeconds: nil)
        }

        // 13. History & Trends: Hazards Encountered
        if cleaned.contains("what hazards") || cleaned.contains("hazards encountered")
            || cleaned.contains("any hazards on this walk") {
            return .answerHistory(metric: .hazardsEncountered, windowSeconds: nil)
        }

        // 14. Campus Navigation via Gazetteer ("set location to X" is how walkers say it on
        // the phone — a recogniser hears "set", not "take", half the time).
        // A gazetteer hit returns the place's spoken `name` (not its id), and `AppModel.navigate(to:)`
        // re-matches it — ⚠ "the Townsend Hall doors" is not an ISR alias, so ISR falls through to
        // MapKit there (see `CampusPlace.name`). Any other target after a prefix starts a route to
        // `target.capitalized` through MapKit (⚠ "go to settings" becomes a place search).
        for prefix in ["take me to ", "route to ", "navigate to ", "go to ", "walk to ",
                       "set destination to ", "set location to ", "change destination to ",
                       "set my destination to "] {
            if cleaned.hasPrefix(prefix) {
                let target = String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = CampusPlaces.normalize(target)
                for place in CampusPlaces.all {
                    for alias in place.aliases {
                        if CampusPlaces.normalize(alias) == normalized {
                            return .startRoute(destination: place.name)
                        }
                    }
                }
                // If it starts with an explicit navigation command, route to the target destination
                if !target.isEmpty {
                    return .startRoute(destination: target.capitalized)
                }
            }
        }

        return nil
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
