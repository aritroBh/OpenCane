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
//    · Pinned by `FastPathIntentClassifierTests`.
//

import Foundation

/// Deterministic classifier that extracts instant actions from common user queries.
public enum FastPathIntentClassifier {

    /// Classifies a cleaned user query into an immediate `ConversationAction`, or `nil` if cloud reasoning is required.
    public static func classify(query: String) -> ConversationAction? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        let cleaned = lower.trimmingCharacters(in: CharacterSet(charactersIn: ".?!,\"';:"))

        // 1. Navigation Escape / Stop
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

        // 4. Settings: Ground Drop-offs
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

        // 6. Status: Battery
        if cleaned.contains("battery") || cleaned.contains("charge") || cleaned.contains("power level") {
            return .answerStatus(aspect: .battery)
        }

        // 7. Status: Headphones / AirPods
        if cleaned.contains("airpod") || cleaned.contains("headphone") || cleaned.contains("head tracking") {
            return .answerStatus(aspect: .headphones)
        }

        // 8. Status: Route Progress / Distance to Next Point
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

        // 10. Voice Markers / Posts ("set a post here", "mark this spot")
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

        // 14. Campus Navigation via Gazetteer
        for prefix in ["take me to ", "route to ", "navigate to ", "go to ", "walk to "] {
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
}
