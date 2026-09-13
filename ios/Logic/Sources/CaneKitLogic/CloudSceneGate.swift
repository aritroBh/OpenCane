//
//  CloudSceneGate.swift
//  CaneKitLogic
//
//  The faithfulness gate for a CLOUD "Where am I" sentence, the twin of `SceneVocabulary.isFaithful`
//  on the on-device path. Until this existed a cloud reply (Gemini / Anthropic / OpenAI / custom)
//  went from the provider straight to `speech.say(text, .scene)` with nothing checking it, while
//  the on-device sentence was checked word by word — the walker could not tell which model spoke.
//
//  Why each rule, with the measurement behind it:
//    · counts — Gemini 3.5 Flash-Lite's worst measured task is counting (52.7 %). "Three steps"
//      is a coin flip; "steps" is not. The numeral goes, the hazard stays.
//    · distances — small VLMs judge distance BELOW chance (GuideDog, ACL 2026: 22.2 % against a
//      25 % baseline) while naming objects at 80–87 %. They can say what is there, not how far, so
//      the only distance the walker hears is the LiDAR number the app already measured.
//    · names — on this project's own Street View frames the model produced "S 5th St",
//      "S Grand Ave", "S Grand Blvd" and "S. 36th St." for corners where Vision read no text at
//      all. A blind walker who believes a street name is at the wrong corner.
//    · reassurance — handed a solid white frame (sun glare, or the lens against a jacket) a model
//      answered "The path ahead is clear and unobstructed" 4 times out of 4. The model says the
//      way is clear exactly when it can see nothing, and that is the worst failure this app has.
//      Absence of evidence is not evidence of a clear path; only the sensors may clear a path.
//
//  What survives is what these models are good at: naming things, and saying which side they are
//  on. The rewritten `ScenePrompt.text` asks for exactly that and forbids the rest, so a
//  well-behaved reply passes untouched and the gate is the floor, not the plan.
//
//  Owner: `SceneDescriber` (app, main actor) calls `check` between the cloud reply and speech —
//  `grounded(_:jpeg:lidar:)` for "Where am I" and `groundedAnswer(_:jpeg:lidar:)` for "Ask
//  OpenCane" — after re-running `OnDeviceVision.detect` on the SAME frame the cloud saw, passing
//  the LiDAR line (`AppModel.contextLine`), the text Vision read (confidence ≥ 0.5, filtered by
//  `SceneVocabulary.readableTexts`) and `SceneVocabulary.narrationNouns` of Vision's labels.
//  nil → "Where am I" speaks the on-device description instead; a question says "I can't answer
//  that." first, so a refused answer is never replaced by a description the walker would read as
//  the answer. `Verdict.note` is logged as `gate` in the `describe_result` trip-log record.
//  `reassurance(in:)` is also the shared refusal table for `HazardWatchPolicy.line` (Hazards.swift)
//  and `ConversationResponseParser.sanitizeSpoken` (ConversationPrompt.swift).
//  Pure: Foundation-only, stateless, nonisolated.
//  Tests: CloudSceneGateTests.swift (15; fixtures are the measured hallucinations above), plus
//  `hazardWatchReassuranceIsRejected` (HazardTests) and the parser tests in ConversationLogicTests.
//

import Foundation

/// Refuses, or trims, a cloud model's scene sentence so a blind walker only hears what the
/// sensors can back. Pure: no clock, no I/O, no model calls.
public enum CloudSceneGate {

    /// What the gate decided: the sentence to speak (nil = nothing trustworthy survived) and a
    /// short note for the trip log, so a walk log shows *why* a reply was trimmed or refused.
    /// Built only by `check` (the memberwise init is internal). Pinned by
    /// `plainSidedDescriptionsPassAndTheNoteExplains` (the exact note strings).
    public struct Verdict: Sendable, Equatable {
        /// The sentence to speak, or nil when the caller must speak the on-device description.
        public let sentence: String?
        /// "spoken", "edited: …" or "refused: …" — written to `describe_result` as `gate`.
        public let note: String
    }

    /// The gate in the shape callers usually want: the sentence to speak, or nil.
    /// Today only the tests call it; the app uses `check` so it can log the note.
    /// - Parameters:
    ///   - sentence: the cloud model's raw reply.
    ///   - lidar: the depth fact the app already has ("Obstacle ahead at 1.4 meters."), the only
    ///     source of a legitimate number; empty when the depth sensor saw nothing.
    ///   - ocr: text Vision actually read in that frame — the only source of a legitimate name.
    ///   - detectedNouns: Vision's nouns for that frame (the app passes
    ///     `SceneVocabulary.narrationNouns`); words the camera confirms, so a capitalised
    ///     "Crosswalk" is not mistaken for somebody's name.
    public static func sanitized(_ sentence: String, lidar: String, ocr: [String],
                                 detectedNouns: [String]) -> String? {
        check(sentence, lidar: lidar, ocr: ocr, detectedNouns: detectedNouns).sentence
    }

    /// The same decision with the reason attached, for the trip log. Rules run in this order
    /// because the reasons are worth logging most-serious first: a false all-clear, then an
    /// invented name, then counts (edited, not refused), then an invented number, then length.
    /// Parameters as in `sanitized`. Notes: "spoken", "edited: dropped count(s) …", or
    /// "refused: nothing left to say" / "unsupported reassurance …" / "name not read by the
    /// camera …" / "number not from the depth sensor …".
    public static func check(_ sentence: String, lidar: String, ocr: [String],
                             detectedNouns: [String]) -> Verdict {
        // Whitespace (newlines included) collapsed to single spaces: every rule below splits on " ".
        let text = sentence.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard text.contains(where: \.isLetter) else { return Verdict(sentence: nil, note: "refused: nothing left to say") }
        // Step 49: the one sentence the prompt asks for when the frame is black. It has no noun,
        // number, name or promise, so the rules below would pass it anyway; the explicit check
        // makes the canonical spelling the one spoken (a model may drop the full stop or quote it).
        if isTooDark(text) { return Verdict(sentence: tooDark, note: "spoken") }

        if let promise = reassurance(in: text) {
            return Verdict(sentence: nil, note: "refused: unsupported reassurance \"\(promise)\"")
        }
        if let name = unreadName(in: text, ocr: ocr, detectedNouns: detectedNouns) {
            return Verdict(sentence: nil, note: "refused: name not read by the camera \"\(name)\"")
        }
        var dropped: [String] = []
        let counted = stripCounts(text, dropped: &dropped)
        // Rule b — every number left (digits or number words) must appear in the LiDAR fact. The
        // same predicate gates the on-device sentence (`SceneVocabulary.isFaithful`).
        guard SceneVocabulary.numbersAreGrounded(counted, in: lidar) else {
            let invented = SceneVocabulary.numbers(in: counted)
                .subtracting(SceneVocabulary.numbers(in: lidar)).sorted().joined(separator: ", ")
            return Verdict(sentence: nil, note: "refused: number not from the depth sensor \"\(invented)\"")
        }
        let short = cap(firstSentence(counted))
        guard short.contains(where: \.isLetter) else {
            return Verdict(sentence: nil, note: "refused: nothing left to say")
        }
        guard !dropped.isEmpty else { return Verdict(sentence: short, note: "spoken") }
        let list = dropped.map { "\"\($0)\"" }.joined(separator: ", ")
        return Verdict(sentence: short, note: "edited: dropped count\(dropped.count > 1 ? "s" : "") \(list)")
    }

    // MARK: The too-dark answer (Step 49)

    /// The sentence `ScenePrompt.text` asks the model for when it cannot see. Spoken as the answer
    /// by `SceneDescriber` (with the LiDAR line in front, as for any sentence — the distance is
    /// still measured), and never prefixed with the low-light caveat, which would say the same
    /// thing twice. ⚠ Byte-identical to the prompt's "answer exactly" text. Pinned by
    /// `tooDarkPassesTheGateUnchanged`.
    public static let tooDark = "It is too dark to see."

    /// True when `text` is `tooDark` modulo case, quotes and a missing or doubled full stop.
    static func isTooDark(_ text: String) -> Bool {
        SceneVocabulary.tokens(text) == ["it", "is", "too", "dark", "to", "see"]
    }

    // MARK: Rule d — reassurance the sensors cannot support

    /// Single words that promise safety. A walker who steps off on one of these has been told the
    /// way is clear by a model that may be looking at a white frame. "empty" and "clear" are in
    /// deliberately: "the street is empty" is the same promise in other words. "obstruction" is
    /// NOT: "an obstruction ahead" is a warning, and warnings must get through.
    /// "proceed" is here as well: telling a blind walker to move is guidance, and guidance comes
    /// from the route engine and the depth sensor, never from a model looking at one frame.
    /// Matched against whole `SceneVocabulary.tokens` (lower-cased letter/digit runs), so
    /// "unclear" or "nothingness" do not trip it, but a harmless "nothing" or "none" does — the
    /// cost of a refusal is the on-device description, the cost of a miss is a false all-clear.
    /// Pinned by `reassuranceTheSensorsCannotSupportIsRefused`.
    static let reassuranceWords: Set<String> = [
        "clear", "unobstructed", "unimpeded", "unblocked", "safe", "safely", "nothing", "none",
        "empty", "uncluttered", "proceed",
    ]

    /// Multi-word promises, matched on the lower-cased sentence. Each one is a way of saying "you
    /// may walk" without any of the single words above; the adversarial probe of this gate found
    /// every one of them passing before they were listed ("The way is open ahead.", "You may walk
    /// forward without concern.", "I see no immediate danger ahead.", "The path is wide and open,
    /// no need to slow down.", "The sidewalk continues with plenty of room."). "free of" covers
    /// "free of obstacles" and "free of debris" alike; "open ahead" does not touch "an open door
    /// ahead", which is a real and useful thing to say.
    /// Matched as raw substrings of the lower-cased sentence (no word boundaries), checked before
    /// the single words, in array order — the first hit is the phrase the note names.
    /// Pinned by `promisesOfSafetyInOtherWordsAreRefused`.
    static let reassurancePhrases: [String] = [
        "no obstacle", "no obstacles", "no obstruction", "no obstructions", "no hazard",
        "no hazards", "no traffic", "no cars", "no people", "no one", "no barrier", "no barriers",
        "no steps", "no danger", "no immediate", "no risk", "no threat", "no need to",
        "not blocked", "nothing blocking", "free of", "all good", "plenty of room", "room to walk",
        "room to pass", "without concern", "open ahead", "way is open", "path is open",
        "wide open", "wide and open", "walk forward", "you may walk", "you can walk",
        "you can cross", "you may cross", "cross now", "keep walking", "keep going",
        "continue forward", "step forward", "go ahead", "you can go", "you can continue",
    ]

    /// The promise found, or nil. The returned word is what the trip log names.
    /// Internal, but shared inside the package: `HazardWatchPolicy.line` drops a hazard-watch reply
    /// that contains one, and `ConversationResponseParser.sanitizeSpoken` replaces a conversational
    /// reply with "Caution: unable to confirm <promise>." — one table, so no path can promise a
    /// clear way that another path refuses.
    /// - Parameter text: the reply, any case (phrases are compared lower-cased).
    static func reassurance(in text: String) -> String? {
        let lower = text.lowercased()
        for phrase in reassurancePhrases where lower.contains(phrase) { return phrase }
        for word in SceneVocabulary.tokens(text) where reassuranceWords.contains(word) { return word }
        return nil
    }

    // MARK: Rule c — names the camera never read

    /// Street abbreviations. In a description of what is in front of a walker these appear only in
    /// a street name, so they are checked case-insensitively and before the capital-letter rule —
    /// they name the measured hallucination class ("S 5th St", "S Grand Ave", "S. 36th St.").
    /// Lower-case, compared with a word's punctuation stripped (`bare`); allowed only when the same
    /// token appears in Vision's OCR for the frame. Pinned by `streetNamesTheCameraNeverReadAreRefused`.
    static let streetAbbreviations: Set<String> = ["st", "ave", "av", "blvd", "rd", "dr", "hwy", "pkwy", "ln", "ct"]

    /// Fraction of capitalised words above which a reply is Title Case, not a reply full of names.
    /// Some models answer "Bike Rack Ahead On Your Left."; punishing that would fall back to the
    /// on-device template on every frame. The street-abbreviation pass still applies there.
    /// Ratio over words that contain a letter; strictly above it the capital-letter rule is skipped.
    /// Pinned by `titleCaseRepliesAreNotTreatedAsNames`.
    static let titleCaseRatio = 0.75

    /// The first name in `text` that Vision did not read in this frame, or nil.
    /// A name is a street abbreviation, or a capitalised word that does not start a sentence and is
    /// neither in `ocr` nor among the nouns the camera confirmed. "I" is never a name.
    /// Comparison is on lower-cased `SceneVocabulary.tokens`, so OCR "GRAINGER" licenses "Grainger".
    /// Pinned by `streetNamesTheCameraNeverReadAreRefused`, `namesTheCameraDidReadSurvive`,
    /// `titleCaseRepliesAreNotTreatedAsNames`.
    /// - Parameters:
    ///   - text: the whitespace-collapsed reply.
    ///   - ocr: text Vision read in the frame.
    ///   - detectedNouns: nouns Vision classified in the frame.
    /// - Returns: the offending word without punctuation (what the trip-log note quotes), or nil.
    static func unreadName(in text: String, ocr: [String], detectedNouns: [String]) -> String? {
        let words = text.split(separator: " ").map(String.init)
        let seen = Set(ocr.flatMap { SceneVocabulary.tokens($0) })
        let confirmed = Set(detectedNouns.flatMap { SceneVocabulary.tokens($0) })
        for w in words {
            let core = bare(w)
            if streetAbbreviations.contains(core.lowercased()), !seen.contains(core.lowercased()) { return core }
        }
        // Eligible = words with letters in them; "214" and "5th" are numbers, handled by rule b.
        let eligible = words.map(bare).filter { $0.contains(where: \.isLetter) }
        let capitalised = eligible.filter { $0.first?.isUppercase == true }.count
        guard !eligible.isEmpty,
              Double(capitalised) / Double(eligible.count) <= titleCaseRatio else { return nil }
        for (i, w) in words.enumerated() {
            let core = bare(w)
            guard let first = core.first, first.isUppercase, core.lowercased() != "i" else { continue }
            // A word that opens the reply or follows a full stop is capitalised by grammar, not
            // because it is a name ("… on your left. Trees line the sidewalk.").
            if i == 0 || "!?.:".contains(words[i - 1].last ?? " ") { continue }
            let lower = core.lowercased()
            if seen.contains(lower) || confirmed.contains(lower) { continue }
            return core
        }
        return nil
    }

    // MARK: Rule a — counts of countable hazards

    /// Words a number may legitimately qualify, all of which rule b then checks against the LiDAR
    /// fact. Everything else ("steps", "cars", "people") loses its numeral: the model is at ~53 %
    /// on counting, and a walker needs to know steps are there, not how many.
    /// "paces" and "blocks" are units, not things: "two paces" is a distance estimate, so the
    /// numeral stays and rule b refuses the sentence rather than leaving "in roughly paces"
    /// (found by the adversarial probe of this gate). "o'clock" / "degrees" keep clock-face and
    /// angle directions numeric so rule b refuses them. Compared lower-cased after `bare`.
    /// Pinned by `paceAndBlockEstimatesAreRefusedNotMangled`, `clockFaceDirectionsAreRefused`,
    /// `distancesMustBeTheLidarNumber`.
    static let units: Set<String> = [
        "meter", "meters", "metre", "metres", "m", "foot", "feet", "ft", "inch", "inches",
        "yard", "yards", "centimeter", "centimeters", "centimetre", "centimetres", "cm",
        "pace", "paces", "stride", "strides", "block", "blocks", "lane", "lanes",
        "o'clock", "oclock", "degree", "degrees", "percent", "second", "seconds", "minute", "minutes",
    ]

    /// Words that mean the numeral before them is not counting the next word, so dropping it would
    /// mangle the sentence ("one of the doors is open" → "of the doors is open"). The numeral stays
    /// and rule b judges it instead: ungrounded, so the sentence is refused rather than garbled.
    /// Pinned by `numeralsThatAreNotCountsAreNotSnippedOut`.
    static let notCounted: Set<String> = ["of", "or", "and", "to", "in", "on", "at", "is", "are",
                                          "was", "were", "the", "a", "an", "by", "from", "with",
                                          "for", "that", "this", "side", "sides"]

    /// Drops every numeral that counts a thing rather than measuring a distance, appending each
    /// dropped word to `dropped` for the log. "Three steps ahead." → "steps ahead." (the lower-case
    /// start is left as is; the speech queue does not care). A numeral is a digit string or a
    /// `SceneVocabulary.numberWords` key. Pinned by `countsOfHazardsLoseTheirNumeral`.
    static func stripCounts(_ text: String, dropped: inout [String]) -> String {
        let words = text.split(separator: " ").map(String.init)
        var out: [String] = []
        for (i, w) in words.enumerated() {
            let core = bare(w)
            let isNumber = Double(core) != nil || SceneVocabulary.numberWords[core.lowercased()] != nil
            let next = i + 1 < words.count ? bare(words[i + 1]).lowercased() : ""
            // A numeral is a count only when a word it could be counting follows it; a trailing
            // numeral, or one in front of a unit or a function word, is left for rule b.
            if isNumber, !next.isEmpty, !units.contains(next), !notCounted.contains(next) {
                dropped.append(core)
                continue
            }
            out.append(w)
        }
        return out.joined(separator: " ")
    }

    // MARK: Rule e — one sentence, twenty words

    /// Everything up to and including the first ".", "!" or "?" that is followed by a space or ends
    /// the text. A stop inside a number ("1.4") does not end a sentence; ⚠ an abbreviation followed
    /// by a space ("St. Mary's") does — there is no abbreviation list here (unlike `SpeechResume`).
    /// A street abbreviation the camera did not read never gets this far (rule c refused it); one
    /// it did read can lose the words after its stop. Pinned by
    /// `repliesAreCappedAtOneSentenceAndTwentyWords`.
    static func firstSentence(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        for (i, c) in chars.enumerated() {
            out.append(c)
            if ".!?".contains(c), i + 1 >= chars.count || chars[i + 1] == " " { return out }
        }
        return out
    }

    /// At most `maxWords` words, always ending in a full stop so the speech queue phrases it.
    /// A sentence already ending in "." / "!" / "?" is kept as is; a cut one loses trailing
    /// punctuation before its "."; empty in → empty out (the caller then refuses).
    static func cap(_ text: String, maxWords: Int = 20) -> String {
        let words = text.split(separator: " ").map(String.init)
        guard words.count > maxWords else {
            guard let last = words.last?.last, ".!?".contains(last) else {
                return words.isEmpty ? "" : words.joined(separator: " ") + "."
            }
            return words.joined(separator: " ")
        }
        var kept = words.prefix(maxWords).joined(separator: " ")
        while let last = kept.last, !last.isLetter, !last.isNumber { kept.removeLast() }
        return kept + "."
    }

    /// A word without its surrounding punctuation ("o'clock," → "o'clock", "S." → "S"). Inner
    /// punctuation stays, so "5th" and "o'clock" survive whole; "" for a word of punctuation only.
    static func bare(_ word: String) -> String {
        var w = Substring(word)
        while let f = w.first, !f.isLetter, !f.isNumber { w = w.dropFirst() }
        while let l = w.last, !l.isLetter, !l.isNumber { w = w.dropLast() }
        return String(w)
    }
}
