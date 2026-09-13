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
//    · Step 67: rule 14b — a travel verb anywhere in the sentence ("I just wanna get from here to
//      Granger library", "how do I get to CIF", "can you take me to the Union please") routes on the
//      phone. Spoken destinations never go to the cloud: on `canekit-2026-09-13T15-48-34Z.jsonl` that
//      sentence missed every rule, the cloud turn hit its budget and the walker heard "No answer.".
//    · Review round Steps 67–68 (Codex, Muse, Antigravity): rule 1 drops polite fillers ("please
//      stop"); rule 1c sends any whole-word "emergency" / "911" to the emergency confirmation before
//      every route rule ("take me to emergency" was a MapKit route); ambiguous travel phrases ("go
//      to", "get to", "walk to", "going to") route only to a campus place — a free-text MapKit
//      search needs an explicit navigation verb ("I need to get to class" was a route to "Class").
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
//  `fromHereOrHalfARouteIsNotARouteFromTo`, `imOutsideIsTheIndoorHandover`, Step 67:
//  `spokenDestinationsRouteOnThePhone`, `aTravelVerbAnywhereKeepsARealOrigin`,
//  `noTravelIntentIsNotARoute`, review round: `politeStopPhrasesStillStop`,
//  `ambiguousTravelPhrasesRouteOnlyToCampusPlaces`, `emergencyWordsReachTheConfirmationNeverARoute`),
//  `CampusPlacesTests.compoundGraingerMishearingsMatch`, `VoiceMenuTests`, `NodToTalkFastPathTests` (rule 5b) and
//  `StressTests.fastPathFuzz` (decoration invariance, purity).
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

        // 1. Navigation Escape / Stop — exact phrases only, after dropping polite fillers at either
        //    end (`stopKey`; review round Steps 67–68, Muse #5: "please stop" went to the cloud and
        //    guidance ran on for up to 8 s), so "stop the beacon" or "don't stop" never end a route.
        if stopPhrases.contains(stopKey(trimmed)) {
            return .stopRoute
        }

        // 1b. Indoor handover (Step 62): "I'm outside" — whole utterance only (a curly apostrophe
        //     from the recogniser counts), so "is it cold outside" is not a handover.
        if outsideForms.contains(cleaned.replacingOccurrences(of: "\u{2019}", with: "'")) {
            return .indoorOutside
        }

        // 1c. Emergency anywhere in the sentence (review round Steps 67–68, Antigravity #1, Muse #10):
        //     before rules 13b / 14 / 14b, so "take me to emergency" is the confirmation-gated call to
        //     the emergency contact, never a MapKit route, and "there's an emergency" does not wait on
        //     the cloud. See `isEmergencyRequest(_:)`. A false hit only asks "Say yes to call …".
        if isEmergencyRequest(trimmed) {
            return .emergency
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
        // (⚠ "take me to settings" becomes a place search). Trailing fillers ("please", "now") are
        // trimmed by `destinationAction` (Step 67). The ambiguous prefixes "go to " / "walk to "
        // (`gazetteerOnlyPrefixes`) route only to a campus place (review round Steps 67–68: "go to
        // class", "go to bed").
        for prefix in destinationPrefixes {
            if cleaned.hasPrefix(prefix) {
                let target = String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                let action = gazetteerOnlyPrefixes.contains(prefix) ? campusAction(target) : destinationAction(target)
                if let action {
                    return action
                }
            }
        }

        // 14b. Travel intent anywhere (Step 67): "I wanna go to X", "how do I get to X", "directions
        //      to X", "can you take me from A to B please". See `travelIntent(_:)`. Last, so every
        //      narrower rule above keeps its phrase.
        if let travel = travelIntent(trimmed) {
            return travel
        }

        return nil
    }

    /// Rule 14b's EXPLICIT navigation verb phrases — the only ones whose destination may become a
    /// free-text MapKit search — as lower-case word sequences with apostrophes removed. Checked before
    /// `gazetteerOnlyVerbPhrases` at each word, so "get me" wins over "get".
    /// Deliberately absent: "went" (past: "I went to Grainger yesterday"), "route" alone (rule 0 /
    /// rule 14 own it), and since the review round Steps 67–68 the ordinary-English "go", "get",
    /// "walk", "travel" (now gazetteer-only: "I need to get to class", "I have to go to work").
    /// ⚠ A false hit acts (a MapKit search starts; a miss says it could not find the place), so the
    /// list stays verbs that only mean navigation. Pinned by `spokenDestinationsRouteOnThePhone`,
    /// `noTravelIntentIsNotARoute`, `ambiguousTravelPhrasesRouteOnlyToCampusPlaces`.
    static let travelVerbPhrases: [[String]] = [
        ["show", "me", "the", "way"],
        ["take", "me"], ["bring", "me"], ["get", "me"], ["navigate", "me"], ["walk", "me"],
        ["guide", "me"], ["lead", "me"], ["route", "me"],
        ["directions"], ["navigate"],
    ]

    /// Rule 1's route-stop phrases, compared with `stopKey(_:)` (lower case, apostrophes removed,
    /// polite fillers dropped). Pinned by `stopPhrasesStillStopBehindRuleZero`, `politeStopPhrasesStillStop`.
    static let stopPhrases: Set<String> = [
        "stop", "stop route", "stop navigating", "stop navigation", "cancel route", "end route",
    ]

    /// Words said before a stop that are not part of it ("please stop", "okay stop"). Rule 1 only.
    static let leadingStopFillers: Set<String> = ["please", "okay", "ok", "um", "uh"]

    /// Rule 1's comparison form of a query: its word keys with `leadingStopFillers` dropped from the
    /// front and `trailingFillers` from the end, joined by single spaces ("Stop, please." → "stop").
    /// Review round Steps 67–68 (Muse #5).
    /// - Parameter query: the whitespace-trimmed query, any case.
    /// - Returns: the key, possibly empty.
    static func stopKey(_ query: String) -> String {
        var w = words(query)
        while let first = w.first, leadingStopFillers.contains(first.key) { w.removeFirst() }
        return trimTrailingFillers(w).map(\.key).joined(separator: " ")
    }

    /// Rule 1c's negations: a sentence with one of these is not a request ("not an emergency",
    /// "cancel emergency", the app's own "Emergency canceled.", "it isn't an emergency").
    static let emergencyNegations: Set<String> = ["not", "isnt", "cancel", "canceled", "cancelled", "never", "false"]

    /// Words that make "emergency" a thing, not a request, when they follow it ("emergency exit",
    /// "the emergency stairs"): a landmark or a destination, never the call.
    static let emergencyObjectWords: Set<String> = ["exit", "exits", "door", "doors", "stairs", "stairway", "stairwell"]

    /// Rule 1c (review round Steps 67–68, Antigravity #1, Muse #10): the query asks for emergency
    /// help — the whole word "emergency" / "emergencies" (not followed by `emergencyObjectWords`),
    /// "911" (also "9-1-1") or "nine one one" anywhere, and no `emergencyNegations` word nor a "no"
    /// right before "emergency". The action is `.emergency`: the confirmation prompt that calls the
    /// walker's emergency contact after a "yes" (`EmergencyConfirm`), never 911 itself.
    /// Pinned by `emergencyWordsReachTheConfirmationNeverARoute`.
    /// - Parameter query: the whitespace-trimmed query, any case.
    /// - Returns: true for an emergency request.
    static func isEmergencyRequest(_ query: String) -> Bool {
        let keys = words(query).map(\.key)
        let nineOneOne = keys.contains { key in
            key.filter(\.isNumber) == "911" && key.allSatisfy { $0.isNumber || $0 == "-" }
        } || keys.indices.contains { i in
            i + 2 < keys.count && keys[i] == "nine" && keys[i + 1] == "one" && keys[i + 2] == "one"
        }
        let emergencyAt = keys.indices.filter { keys[$0] == "emergency" || keys[$0] == "emergencies" }
        let emergency = emergencyAt.contains { i in
            !(i + 1 < keys.count && emergencyObjectWords.contains(keys[i + 1]))
        }
        guard nineOneOne || emergency else { return false }
        if keys.contains(where: { emergencyNegations.contains($0) }) { return false }
        if emergencyAt.contains(where: { $0 > 0 && keys[$0 - 1] == "no" }) { return false }
        return true
    }

    /// Words said after a destination that are not part of it, as lower-case word sequences
    /// (apostrophes removed). Trimmed from the end, repeatedly: "the Union please now" → "the Union".
    /// "from here" needs no entry: it is split off as an origin (`hereOrigins`).
    static let trailingFillers: [[String]] = [
        ["right", "now"], ["thank", "you"], ["for", "me"], ["please"], ["now"], ["thanks"],
    ]

    /// One spoken word: `text` as said with edge punctuation removed (for the destination the route
    /// is built from) and `key`, lower-case with apostrophes removed (for matching).
    struct Word {
        /// The word as said, edge punctuation trimmed ("Grainger," → "Grainger").
        let text: String
        /// Comparison form ("Let's" → "lets").
        let key: String
    }

    /// Splits a query into `Word`s at whitespace, dropping words that are only punctuation.
    /// - Parameter text: any query.
    /// - Returns: the words in order.
    static func words(_ text: String) -> [Word] {
        let edge = CharacterSet.punctuationCharacters.union(.symbols)
        return text.split(whereSeparator: { $0.isWhitespace }).compactMap { raw in
            let t = String(raw).trimmingCharacters(in: edge)
            guard !t.isEmpty else { return nil }
            let key = t.lowercased().replacingOccurrences(of: "'", with: "")
                .replacingOccurrences(of: "\u{2019}", with: "")
            return Word(text: t, key: key)
        }
    }

    /// `words` with every trailing filler (`trailingFillers`) removed from the end.
    /// - Parameter words: a destination or origin.
    /// - Returns: the words without their trailing fillers (possibly empty).
    static func trimTrailingFillers(_ words: [Word]) -> [Word] {
        var out = words
        var changed = true
        while changed {
            changed = false
            for filler in trailingFillers where out.count >= filler.count {
                if out.suffix(filler.count).map(\.key) == filler {
                    out.removeLast(filler.count)
                    changed = true
                }
            }
        }
        return out
    }

    /// Rule 14b verbs that count only when the destination is a campus place ("I'm going to CIF",
    /// "heading to Grainger", "how do I get to Grainger"): as a MapKit search they would catch "I'm
    /// going to sit down", "turn my head to the left" (Muse review, Step 67), "I need to get to
    /// class", "I have to go to work", "I want to go to bed" (review round Steps 67–68). Pinned by
    /// `ambiguousTravelPhrasesRouteOnlyToCampusPlaces`, `travelIntentReviewCases`.
    static let gazetteerOnlyVerbPhrases: [[String]] = [
        ["going"], ["heading"], ["headed"], ["head"], ["go"], ["get"], ["walk"], ["travel"],
    ]

    /// Rule 14 / 13b prefixes that are ordinary English at the start of a sentence ("go to bed",
    /// "walk to the door"): they route only to a campus place (review round Steps 67–68).
    static let gazetteerOnlyPrefixes: Set<String> = ["go to ", "walk to "]

    /// A campus place route for `target` (trailing fillers trimmed), or nil — never a MapKit search.
    /// Callers: rule 14 and rule 13b for `gazetteerOnlyPrefixes`.
    /// - Parameter target: the words after the prefix.
    /// - Returns: `.startRoute` with the place's spoken name, or nil.
    static func campusAction(_ target: String) -> ConversationAction? {
        let place = trimTrailingFillers(words(target)).map(\.text).joined(separator: " ")
        return CampusPlaces.match(place).map { .startRoute(destination: $0.name) }
    }

    /// Words that mark a rule-14b destination as not a place, so a gazetteer miss is not searched on
    /// MapKit: "where do I go to pay my bill", "I need to get to work on my homework", "how do I get
    /// to sleep" (Muse review, Step 67). A campus place never contains one.
    /// Review round Steps 67–68: "you" ("how do I get to see you"), "emergency" / "emergencies" /
    /// "911" (never a destination — rule 1c owns them; "take me to the emergency exit" goes to the cloud).
    static let nonPlaceWords: Set<String> = [
        "my", "your", "it", "that", "this", "me", "him", "her", "them", "us", "you",
        "sleep", "know", "next", "question", "do", "be", "pay", "work", "bed", "eat", "drink",
        "emergency", "emergencies", "911",
    ]

    /// Longest rule-14b destination (words) that may become a MapKit search on a gazetteer miss.
    static let maxMapKitDestinationWords = 4

    /// Rule 14b (Step 67): a travel verb phrase (`travelVerbPhrases`, or `gazetteerOnlyVerbPhrases`
    /// for a campus place only — "go", "get", "walk", "travel", "going", "heading" since the review
    /// round Steps 67–68) anywhere, followed by "to <destination>" or "from <origin> to <destination>".
    ///   · "to B from A" splits at the last "from" (as rule 13b does).
    ///   · An origin in `hereOrigins` ("here", "my location") is no origin.
    ///   · A real origin → `.routeFromTo(from: A, to: B)`, both ends as said (first such verb wins).
    ///   · Every verb is tried: a gazetteer hit from any verb beats a MapKit search from an earlier
    ///     one ("get directions to go to Grainger" is Grainger, not a search for "Go To Grainger").
    ///   · A MapKit search needs ≤ `maxMapKitDestinationWords` words and none of `nonPlaceWords`.
    ///   · Trailing fillers are trimmed; an end left empty, or a destination ending in a dangling
    ///     "from" / "to" (a cut-off sentence), skips that verb.
    ///   · A verb right after "used to" is skipped ("I used to go to Grainger" is not a request).
    /// Pinned by `spokenDestinationsRouteOnThePhone`, `aTravelVerbAnywhereKeepsARealOrigin`,
    /// `noTravelIntentIsNotARoute`, `travelIntentReviewCases`, `StressTests.fastPathFuzz`.
    /// - Parameter query: the whitespace-trimmed query, original case.
    /// - Returns: `.startRoute`, `.routeFromTo`, or nil.
    static func travelIntent(_ query: String) -> ConversationAction? {
        let w = words(query)
        let keys = w.map(\.key)
        func joined(_ part: [Word]) -> String { part.map(\.text).joined(separator: " ") }
        var mapKitFallback: ConversationAction?
        for i in w.indices {
            let gazetteerOnly: Bool
            let verb: [String]
            func matches(_ phrase: [String]) -> Bool {
                i + phrase.count <= keys.count && Array(keys[i..<(i + phrase.count)]) == phrase
            }
            if let v = travelVerbPhrases.first(where: matches) {
                verb = v; gazetteerOnly = false
            } else if let v = gazetteerOnlyVerbPhrases.first(where: matches) {
                verb = v; gazetteerOnly = true
            } else {
                continue
            }
            if i >= 2, keys[i - 2] == "used", keys[i - 1] == "to" { continue }
            let next = i + verb.count
            guard next < w.count else { continue }
            var origin: [Word] = []
            var destination: [Word]
            if keys[next] == "from" {
                guard let to = keys[(next + 1)...].firstIndex(of: "to") else { continue }
                origin = Array(w[(next + 1)..<to])
                destination = Array(w[(to + 1)...])
                guard !trimTrailingFillers(origin).isEmpty else { continue }
            } else if keys[next] == "to" {
                destination = Array(w[(next + 1)...])
                if let from = destination.lastIndex(where: { $0.key == "from" }),
                   from > 0, from + 1 < destination.count {
                    origin = Array(destination[(from + 1)...])
                    destination = Array(destination[..<from])
                }
            } else {
                continue
            }
            origin = trimTrailingFillers(origin)
            destination = trimTrailingFillers(destination)
            guard let first = destination.first, first.key != "from", first.key != "to",
                  let last = destination.last, last.key != "from", last.key != "to" else { continue }
            let to = joined(destination)
            let hereOrigin = origin.isEmpty || hereOrigins.contains(CampusPlaces.normalize(joined(origin)))
            if !hereOrigin {
                guard destination.count <= maxMapKitDestinationWords,
                      origin.count <= maxMapKitDestinationWords,
                      !destination.contains(where: { nonPlaceWords.contains($0.key) }),
                      !origin.contains(where: { nonPlaceWords.contains($0.key) }),
                      let oFirst = origin.first, oFirst.key != "from", oFirst.key != "to",
                      let oLast = origin.last, oLast.key != "from", oLast.key != "to"
                else { continue }
                if gazetteerOnly && CampusPlaces.match(to) == nil { continue }
                return .routeFromTo(from: joined(origin), to: to)
            }
            if let place = CampusPlaces.match(to) { return .startRoute(destination: place.name) }
            if !gazetteerOnly, mapKitFallback == nil {
                mapKitFallback = destinationAction(to)
            }
        }
        return mapKitFallback
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
    /// `everyDestinationPrefixTakesAFromOrigin`. Review round Steps 67–68: after a
    /// `gazetteerOnlyPrefixes` prefix ("go to B from A") B must be a campus place, else nil.
    /// - Parameter query: the whitespace-trimmed query, original case.
    /// - Returns: `.routeFromTo`, `.startRoute` for a "here" origin, or nil.
    static func routeFromTo(_ query: String) -> ConversationAction? {
        let edge = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".?!,\"';:"))
        let text = query.trimmingCharacters(in: edge)
        func clean(_ part: Substring) -> String { String(part).trimmingCharacters(in: edge) }
        var from = "", to = ""
        var campusOnly = false
        if let match = destinationPrefixes.lazy
                .compactMap({ p in text.range(of: p, options: [.anchored, .caseInsensitive]).map { (p, $0) } }).first,
           let split = text.range(of: " from ", options: [.caseInsensitive, .backwards],
                                  range: match.1.upperBound..<text.endIndex) {
            to = clean(text[match.1.upperBound..<split.lowerBound])
            from = clean(text[split.upperBound...])
            campusOnly = gazetteerOnlyPrefixes.contains(match.0)
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
        if campusOnly {
            guard let campus = campusAction(to) else { return nil }
            if hereOrigins.contains(CampusPlaces.normalize(from)) { return campus }
            return .routeFromTo(from: from, to: to)
        }
        if hereOrigins.contains(CampusPlaces.normalize(from)) { return destinationAction(to) }
        return .routeFromTo(from: from, to: to)
    }

    /// Rule 14's destination: trailing fillers trimmed ("the Union please" → "the Union", Step 67),
    /// then a gazetteer hit → `.startRoute` with the place's spoken `name`; any other non-empty
    /// target → `.startRoute(target.capitalized)` (MapKit) provided it looks like a place (<= maxMapKitDestinationWords,
    /// no nonPlaceWords, no dangling from/to); empty (or only fillers) → nil.
    /// Callers: rule 14, rule 13b for a "from here" origin, rule 14b.
    static func destinationAction(_ target: String) -> ConversationAction? {
        let targetWords = trimTrailingFillers(words(target))
        let place = targetWords.map(\.text).joined(separator: " ")
        if let hit = CampusPlaces.match(place) { return .startRoute(destination: hit.name) }
        guard !targetWords.isEmpty,
              targetWords.count <= maxMapKitDestinationWords,
              !targetWords.contains(where: { nonPlaceWords.contains($0.key) }),
              let first = targetWords.first, first.key != "from", first.key != "to",
              let last = targetWords.last, last.key != "from", last.key != "to"
        else { return nil }
        return .startRoute(destination: place.capitalized)
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
