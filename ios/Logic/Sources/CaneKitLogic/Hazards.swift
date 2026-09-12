//
//  Hazards.swift
//  CaneKitLogic
//
//  Hazards the maps do not know about, from the phone's own sensors. Pure decisions only; the app
//  feeds samples in and turns the outputs into speech, haptics and a hazard log.
//
//    GroundHazardDetector   LiDAR ground profile → drop-off / pothole / curb-up / low obstacle,
//                           1.5–3.5 m ahead in the walking corridor, confirmed over several frames
//    SignPolicy             on-device text recognition → "Sign: sidewalk closed." (once per sign)
//    HazardWatchPolicy      periodic vision-model check → a short spoken hazard, or nothing
//    HazardRecord / HazardGeoJSON   every confirmed hazard with GPS → a shareable GeoJSON map
//
//  Why: a long cane finds drop-offs only at arm's length and never reads a "SIDEWALK CLOSED"
//  sign; the LiDAR sees the ground profile out to ~5 m and the camera sees signs and cones.
//  Tests: HazardTests.swift.
//

import Foundation

// MARK: - Ground profile from LiDAR

/// One LiDAR return, already transformed by the app into the walker's frame (gravity-aligned):
/// metres ahead along the horizontal walking direction, metres to the right, and height relative
/// to the camera (negative = below the phone).
public struct GroundSample: Sendable, Equatable {
    public var forward: Float
    public var lateral: Float
    public var height: Float
    public init(forward: Float, lateral: Float, height: Float) {
        self.forward = forward
        self.lateral = lateral
        self.height = height
    }
}

public enum GroundHazardKind: String, Sendable, Codable, Equatable, CaseIterable {
    /// Ground falls away by more than a step (curb down, a short step down, a trench). The lower
    /// surface must be visible within the scan: a long flight of stairs down or a ledge deeper than
    /// ~0.6 m hides its lower ground (occlusion) and is NOT detected (Claude review workflow).
    case dropOff
    /// A hole whose far side comes back up (pothole, missing paver, open drain).
    case pothole
    /// Ground rises by a step and stays up (curb up, stair up, raised slab).
    case stepUp
    /// Something 10–50 cm tall that the ground comes back down behind (planter lip, low barrier,
    /// parking block). Waist-high things are the lane grid's job, not this detector's.
    case lowObstacle

    public var spoken: String {
        switch self {
        case .dropOff: return "Drop-off ahead"
        case .pothole: return "Hole ahead"
        case .stepUp: return "Step up ahead"
        case .lowObstacle: return "Low obstacle ahead"
        }
    }

    /// The bare noun for the distance-first line ("Two meters ahead, drop-off."). `spoken`
    /// above stays the legacy object-first shape for the direction-only fallback; this is the
    /// word that follows the distance in `GroundHazard.spokenLine`.
    public var shortNoun: String {
        switch self {
        case .dropOff: return "drop-off"
        case .pothole: return "hole"
        case .stepUp: return "step up"
        case .lowObstacle: return "low obstacle"
        }
    }
}

public struct GroundHazard: Sendable, Equatable {
    public var kind: GroundHazardKind
    /// Metres ahead to the start of the hazard (the conservative, nearer edge).
    public var distance: Float
    /// Height change (m): negative for drops/holes, positive for steps/obstacles.
    public var delta: Float
    /// Where the hazard is along the walk: `distance` + metres already walked when it was seen.
    /// Stays put while the walker approaches, so GroundHazardPolicy can tell "the same curb,
    /// closer" from "a new curb". Equals `distance` when nobody tracks the walk (tests).
    public var anchor: Float
    public init(kind: GroundHazardKind, distance: Float, delta: Float, anchor: Float? = nil) {
        self.kind = kind
        self.distance = distance
        self.delta = delta
        self.anchor = anchor ?? distance
    }

    /// "Two meters ahead, drop-off." Distance first, hazard second: same reason as
    /// `SpokenPhrases.obstacleLine` — the walker brakes on the number, then learns what for.
    /// A non-finite distance (unreachable from the detector, which only reports bin starts)
    /// falls back to the direction-only kind line rather than speaking an empty number.
    public var spokenLine: String {
        let phrase = SpokenDistance.phrase(distance)
        guard !phrase.isEmpty else { return "\(kind.spoken)." }
        return "\(SpokenDistance.leadingCapitalized(phrase)) ahead, \(kind.shortNoun)."
    }
}

/// Finds ground hazards in one frame's samples, then confirms them over several frames.
///
/// Per frame: take the samples inside the walking corridor (|lateral| ≤ `corridorHalfWidth`),
/// estimate the local ground from the near field (`nearMin…nearMax` ahead: median height), then
/// bin the rest by distance (`binSize`) and take each bin's median height. A hazard starts where
/// a bin departs from the ground reference by more than a threshold **and** jumps relative to the
/// previous two bins (a curb face that lands mid-bin splits its jump across two bins; a smooth
/// ramp — ≤ 10 % — changes ≤ 6 cm over two bins and never jumps, so slopes do not trigger).
/// The reported distance is the nearer edge of the transition, never the far one.
/// Across frames: the same kind within ±`distanceTolerance` must appear in `confirmFrames` of the
/// last `windowFrames` trusted frames. Untrusted frames (cane mid-sweep) are ignored entirely.
public struct GroundHazardDetector: Sendable {

    public struct Config: Sendable, Equatable {
        public var corridorHalfWidth: Float = 0.45
        public var nearMin: Float = 0.8
        public var nearMax: Float = 1.5
        public var scanMax: Float = 3.5
        public var binSize: Float = 0.3
        public var minSamplesPerBin = 6
        public var minNearSamples = 12
        /// Where the ground must be relative to the camera for a cane-mounted phone (m). A desk
        /// 30 cm below a hand-held phone is not the ground (real-phone false "Hole ahead").
        public var groundHeightRange: ClosedRange<Float> = -1.3 ... -0.5
        /// Drop / hole: bin this far below the ground reference (m).
        public var dropThreshold: Float = 0.12
        /// Step / low obstacle: bin this far above the ground reference (m).
        public var riseThreshold: Float = 0.10
        /// Anything taller than this above ground is the lane grid's business, not ours (m).
        public var maxRise: Float = 0.5
        /// Minimum jump between consecutive bins for a real edge (m).
        public var edgeJump: Float = 0.07
        public var windowFrames = 5
        public var confirmFrames = 3
        public var distanceTolerance: Float = 0.6
        /// Evaluations older than this (s) never pair with a fresh one.
        public var maxAge: TimeInterval = 2
        public init() {}
    }

    public var config: Config
    /// One entry per trusted evaluation: the hazard (or nil), its world-anchored position
    /// (distance ahead + metres already walked), and when.
    private var history: [(hazard: GroundHazard?, at: Float, time: TimeInterval)] = []

    public init(config: Config = Config()) { self.config = config }

    /// Per-frame classification without memory (exposed for tests and the live view).
    public func classify(_ samples: [GroundSample]) -> GroundHazard? {
        let c = config
        let corridor = samples.filter { abs($0.lateral) <= c.corridorHalfWidth && $0.height.isFinite }
        let near = corridor.filter { $0.forward >= c.nearMin && $0.forward <= c.nearMax }.map(\.height)
        guard near.count >= c.minNearSamples else { return nil }
        let ground = Self.median(near)
        guard c.groundHeightRange.contains(ground) else { return nil }

        // Bins beyond the near field.
        var bins: [(start: Float, height: Float)] = []
        var start = c.nearMax
        while start < c.scanMax {
            let hs = corridor.filter { $0.forward >= start && $0.forward < start + c.binSize }.map(\.height)
            if hs.count >= c.minSamplesPerBin { bins.append((start, Self.median(hs))) }
            start += c.binSize
        }
        guard !bins.isEmpty else { return nil }

        for (i, bin) in bins.enumerated() {
            let delta = bin.height - ground
            let p1 = i >= 1 ? bins[i - 1].height : ground
            let p2 = i >= 2 ? bins[i - 2].height : ground
            let later = bins[(i + 1)...].map { $0.height - ground }
            // Nearer edge: when the step from the adjacent bin alone is small, the face fell inside
            // that bin (review round 5: bin.start overstated the distance by up to ~0.4 m).
            func edge(adjacentJump: Float) -> Float {
                i >= 1 && abs(adjacentJump) < c.edgeJump ? bins[i - 1].start : bin.start
            }
            // Missing bins before this one (shiny patch, puddle, occlusion): a ramp keeps sloping
            // across the gap, so the edge must beat the slope a 10 % ramp covers over it
            // (Antigravity final review: sparse returns made a ramp read as a drop-off).
            // Slack for the missing span between a reference bin j (-1 = the near field) and this
            // one, beyond the bins that would normally sit between them.
            func slack(_ j: Int) -> Float {
                let refEnd = j >= 0 ? bins[j].start + c.binSize : c.nearMax
                return 0.10 * max(0, bin.start - refEnd - Float(i - j - 1) * c.binSize)
            }
            let s1 = slack(i - 1), s2 = slack(i - 2)
            let prevEnd = i >= 1 ? bins[i - 1].start + c.binSize : c.nearMax
            let dropEdge = bin.height - p1 <= -(c.edgeJump + s1) || bin.height - p2 <= -(c.edgeJump + s2)
            let riseEdge = bin.height - p1 >= c.edgeJump + s1 || bin.height - p2 >= c.edgeJump + s2
            if delta <= -c.dropThreshold, dropEdge {
                // Comes back up within the scan → a hole; stays down → a drop-off.
                let recovers = later.contains { $0 > -c.dropThreshold / 2 }
                // A deep drop hides the ground just past its edge (occlusion shadow): the first
                // visible lower bin can be a metre beyond the edge. When bins are missing before
                // this one, report the end of the last visible ground (Claude review workflow).
                let lastGroundEnd = prevEnd
                let shadow = bin.start > lastGroundEnd + 0.01
                return GroundHazard(kind: recovers ? .pothole : .dropOff,
                                    distance: shadow ? lastGroundEnd : edge(adjacentJump: bin.height - p1),
                                    delta: delta)
            }
            // A tall surface filling part of a bin (wall, pole) must not read as a step: the
            // bin's upper returns must also stay under maxRise, not just its median.
            if delta >= c.riseThreshold, delta <= c.maxRise, riseEdge,
               Self.upperQuartile(corridor, from: bin.start, to: bin.start + c.binSize) - ground <= c.maxRise {
                // Last bin: nothing beyond it yet, so step-up vs low obstacle is a guess — wait for
                // a closer frame instead of saying one kind now and the other next second.
                guard !later.isEmpty else { return nil }
                let staysUp = later.allSatisfy { $0 >= c.riseThreshold / 2 }
                return GroundHazard(kind: staysUp ? .stepUp : .lowObstacle,
                                    distance: edge(adjacentJump: bin.height - p1), delta: delta)
            }
        }
        return nil
    }

    /// Feed one trusted frame. Returns a hazard only once it is confirmed across frames.
    ///
    /// - Parameters:
    ///   - travelled: metres walked so far along the walking direction (cumulative). Agreement is
    ///     judged on `distance + travelled`, i.e. where the hazard is in the world — a curb you
    ///     walk toward at 1.2 m/s moves 0.5 m closer between evaluations and must still agree
    ///     with itself (the review simulation: a relative comparison never confirmed under a
    ///     real cane sweep).
    ///   - time: seconds (any monotonic clock); entries older than `maxAge` are dropped.
    ///   - trusted: untrusted frames (mid-sweep) are ignored and do not use up history.
    public mutating func update(_ samples: [GroundSample], trusted: Bool,
                                travelled: Float = 0, time: TimeInterval = 0) -> GroundHazard? {
        guard trusted else { return nil }
        let h = classify(samples)
        history.append((h, (h?.distance ?? 0) + travelled, time))
        history.removeAll { time - $0.time > config.maxAge }
        if history.count > config.windowFrames { history.removeFirst(history.count - config.windowFrames) }
        guard let latestEntry = history.last, var latest = latestEntry.hazard else { return nil }
        // Drop-off and hole are one family (a drop first seen at the scan edge becomes a hole once
        // its far side shows); step up and low obstacle are another. Frames agree within a family,
        // so a kind change never throws away a confirmation (Muse + Antigravity, 05c8b63).
        let agreeing = history.filter {
            guard let k = $0.hazard?.kind else { return false }
            return Self.family(k) == Self.family(latest.kind) && abs($0.at - latestEntry.at) <= config.distanceTolerance
        }
        guard agreeing.count >= config.confirmFrames else { return nil }
        latest.anchor = latestEntry.at
        return latest
    }

    /// 0 = the ground falls away (drop-off, hole), 1 = something rises (step up, low obstacle).
    static func family(_ k: GroundHazardKind) -> Int {
        switch k {
        case .dropOff, .pothole: return 0
        case .stepUp, .lowObstacle: return 1
        }
    }

    /// 75th-percentile height of corridor samples in [from, to).
    static func upperQuartile(_ samples: [GroundSample], from: Float, to: Float) -> Float {
        let hs = samples.filter { $0.forward >= from && $0.forward < to }.map(\.height).sorted()
        guard !hs.isEmpty else { return -.infinity }
        return hs[min(hs.count - 1, hs.count * 3 / 4)]
    }

    public mutating func reset() { history.removeAll() }

    static func median(_ xs: [Float]) -> Float {
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

/// When a confirmed ground hazard is worth saying: a new kind, the same kind somewhere else
/// (anchors more than `samePlace` m apart), the same hazard noticeably closer (≥ `closerBy` m),
/// or the same hazard again after `repeatInterval`. Standing at a curb therefore gets one
/// warning, not a `.safety` line and four heavy taps every few seconds (review round 5).
public struct GroundHazardPolicy: Sendable, Equatable {
    /// Same hazard, not getting closer (walker standing at it): repeat this rarely (s).
    public var repeatInterval: TimeInterval = 30
    public var closerBy: Float = 1.0
    /// Two sightings of one kind whose anchors are this close (m) are the same hazard.
    public var samePlace: Float = 1.0
    private var last: (kind: GroundHazardKind, distance: Float, anchor: Float, time: TimeInterval)?

    public init() {}

    public static func == (a: GroundHazardPolicy, b: GroundHazardPolicy) -> Bool {
        a.repeatInterval == b.repeatInterval && a.closerBy == b.closerBy && a.samePlace == b.samePlace
    }

    public mutating func shouldAnnounce(_ h: GroundHazard, now: TimeInterval) -> Bool {
        if let l = last, l.kind == h.kind, abs(l.anchor - h.anchor) <= samePlace,
           l.distance - h.distance < closerBy, now - l.time < repeatInterval {
            return false
        }
        last = (h.kind, h.distance, h.anchor, now)
        return true
    }

    public mutating func reset() { last = nil }
}

// MARK: - Signs (on-device text recognition)

/// Turns recognized text into at most one short spoken sign line, and never repeats a sign
/// within `repeatInterval`. Only safety- and wayfinding-relevant phrases are spoken; a blind
/// walker does not need every storefront read out.
public struct SignPolicy: Sendable, Equatable {
    /// Longest phrases first so "SIDEWALK CLOSED" wins over "CLOSED" and "PUSH BUTTON" over "PUSH".
    /// No "STOP": a STOP sign faces drivers, and with small-text reading (1/128 of the frame) its
    /// 25 cm letters read from across an intersection, so it would be spoken at every stop-controlled
    /// corner of the route (Street View mock). "PUSH BUTTON" is the crossing sign a walker can use.
    public static let phrases: [String] = [
        "SIDEWALK CLOSED", "ROAD CLOSED", "USE OTHER SIDEWALK", "NO PEDESTRIANS", "DO NOT ENTER",
        "WET FLOOR", "KEEP OUT", "WORK ZONE", "CONSTRUCTION", "DETOUR", "DANGER", "CAUTION",
        "PUSH BUTTON", "CLOSED", "EXIT", "ENTRANCE", "PULL", "PUSH",
    ].sorted { $0.count > $1.count }

    public var repeatInterval: TimeInterval = 60
    public var minConfidence: Float = 0.5
    /// One-word phrases (EXIT, PUSH, PULL, CLOSED, DETOUR …) need the text line at least this tall
    /// (fraction of the image height), i.e. close. Multi-word safety phrases ("SIDEWALK CLOSED")
    /// are read down to whatever the scan allows (1/128). Small far text is where storefront
    /// "EXIT" / "PUSH" chatter comes from (Muse + Antigravity, Step 12 review).
    public var shortPhraseMinHeight: Float = 1.0 / 80
    /// Phrases that may be spoken; nil = all (today). A matched phrase outside the set is skipped
    /// **without** being stamped, so allowing it later reads it at once. Set by the app from
    /// `CueRules.allowedSignPhrases` (Quiet / Indoors: safety signs only). Pinned by
    /// `SignPhraseFilterTests`.
    public var allowedPhrases: Set<String>?
    private var lastSaid: [String: TimeInterval] = [:]

    public init() {}

    /// One recognized text line: its string, confidence (0…1) and line-box height as a fraction
    /// of the image height. The default height 0 means unknown, treated as **far** (Muse: unknown
    /// size must never bypass the close-text rule).
    public struct SeenText: Sendable, Equatable {
        /// Where the line sits in the image (normalized, Vision's bottom-left origin).
        public struct Box: Sendable, Equatable {
            public var minX: Float
            public var maxX: Float
            public var minY: Float
            public init(minX: Float, maxX: Float, minY: Float) {
                self.minX = minX
                self.maxX = maxX
                self.minY = minY
            }
        }
        public var text: String
        public var confidence: Float
        public var height: Float
        /// nil = position unknown: such lines are never joined with other far lines.
        public var box: Box?
        public init(text: String, confidence: Float, height: Float = 0, box: Box? = nil) {
            self.text = text
            self.confidence = confidence
            self.height = height
            self.box = box
        }
    }

    /// True when `upper` sits directly above `lower` on the same sign: their x ranges overlap,
    /// their heights are within 1.5x of each other, and the gap between them is under one line
    /// height. A stacked "SIDEWALK" / "CLOSED" qualifies; a distant "ROAD" and a shop's "CLOSED"
    /// do not.
    static func stacked(_ upper: SeenText, over lower: SeenText) -> Bool {
        guard let a = upper.box, let b = lower.box, upper.height > 0, lower.height > 0 else { return false }
        let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let ratio = max(upper.height, lower.height) / min(upper.height, lower.height)
        let gap = a.minY - (b.minY + lower.height)
        return overlap > 0 && ratio <= 1.5 && gap >= -0.5 * lower.height && gap < max(upper.height, lower.height)
    }

    /// True when a text line may be mentioned at all (to the walker or to the language model): it
    /// is close (`shortPhraseMinHeight` or taller) or it is several words. A far lone word ("EXIT"
    /// on a storefront across the street) is never passed on (Antigravity, review of 3efc0b1).
    public func mayMention(_ s: SeenText) -> Bool {
        s.height >= shortPhraseMinHeight || Self.normalize(s.text).contains(" ")
    }

    /// Fixtures and tests only: every string is treated as **close** (full height). App code must use
    /// `line(for seen:)` with real heights (`VisionDetections.seenTexts`).
    /// - Parameter texts: recognized strings with confidence (0…1).
    /// - Returns: "Sign: sidewalk closed." or nil.
    public mutating func line(for texts: [(text: String, confidence: Float)], now: TimeInterval) -> String? {
        line(for: texts.map { SeenText(text: $0.text, confidence: $0.confidence, height: 1) }, now: now)
    }

    /// - Parameter seen: recognized lines with size; see `shortPhraseMinHeight`.
    /// - Returns: "Sign: sidewalk closed." or nil.
    public mutating func line(for seen: [SeenText], now: TimeInterval) -> String? {
        let usable = seen.filter { $0.confidence >= minConfidence }
        // Vision returns one observation per printed line, and real signs stack their words
        // ("SIDEWALK" over "CLOSED"): also match all lines joined in reading order.
        // Joining lines: with a position (real Vision text) only lines stacked on one sign are
        // joined, at any size, so "SIDEWALK" (close) over "CLOSED" (just far) still reads, while a
        // stencilled "ROAD" and a shop's "CLOSED" never make "ROAD CLOSED" (Muse + Antigravity
        // final reviews). Without a position (test fixtures) close lines are joined as before.
        let minClose = shortPhraseMinHeight
        let isClose = { (t: SeenText) in t.height >= minClose }
        let unboxedClose = usable.filter { $0.box == nil && isClose($0) }.map { Self.normalize($0.text) }
        let boxed = usable.filter { $0.box != nil }.sorted { ($0.box?.minY ?? 0) > ($1.box?.minY ?? 0) }
        var chains: [[SeenText]] = []
        for (i, upper) in boxed.enumerated() {
            var chain = [upper]
            for lower in boxed[(i + 1)...] where Self.stacked(chain[chain.count - 1], over: lower) { chain.append(lower) }
            if chain.count > 1 { chains.append(chain) }
        }
        func joined(_ c: [SeenText]) -> String { " " + c.map { Self.normalize($0.text) }.joined(separator: " ") + " " }
        let close = usable.filter(isClose).map { " \(Self.normalize($0.text)) " }
            + [" " + unboxedClose.joined(separator: " ") + " "]
            + chains.filter { $0.allSatisfy(isClose) }.map(joined)
        let anySize = usable.map { " \(Self.normalize($0.text)) " }
            + [" " + unboxedClose.joined(separator: " ") + " "]
            + chains.map(joined)
        var matched: [String] = []
        for phrase in Self.phrases {
            let haystacks = phrase.contains(" ") ? anySize : close
            guard haystacks.contains(where: { $0.contains(" \(phrase) ") }) else { continue }
            // "CLOSED" inside an already-matched "SIDEWALK CLOSED" is the same sign.
            if matched.contains(where: { $0.contains(phrase) }) { continue }
            // Not allowed by the cue level / place: skip, unstamped, and NOT counted as matched, so it
            // can never swallow an allowed phrase inside it (`sameFrameAllowedPhraseSurvives`).
            if let allowed = allowedPhrases, !allowed.contains(phrase) { continue }
            matched.append(phrase)
            // Said recently: skip it but keep looking — a DETOUR next to a ROAD CLOSED still counts.
            if let t = lastSaid[phrase], now - t < repeatInterval { continue }
            // Stamp every phrase inside this one too, so a partial read of the same sign a few
            // seconds later ("CLOSED" after "SIDEWALK CLOSED") is not a second announcement.
            for p in Self.phrases where " \(phrase) ".contains(" \(p) ") { lastSaid[p] = now }
            return "Sign: \(phrase.lowercased())."
        }
        return nil
    }

    /// Upper-case, letters and spaces only, single-spaced ("Sidewalk-closed!" → "SIDEWALK CLOSED").
    static func normalize(_ s: String) -> String {
        let mapped = s.uppercased().map { $0.isLetter ? $0 : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }
}

// MARK: - Hazard watch (vision model)

/// The periodic vision-model check: when to ask, what to ask, and what to say.
public enum HazardPrompt {
    /// Asks for path hazards only, in a fixed short format, with an explicit "NONE". The reply
    /// is requested distance-first ("3 meters ahead, cones"): the app's own warning lines lead
    /// with the number, and a free-text VLM reply should match so the walker hears one order.
    /// `HazardWatchPolicy.line` does not reorder — it wraps the first sentence as written — so
    /// the ordering contract lives here, in the prompt.
    public static let text = """
    You are the eyes of a blind pedestrian walking forward. Look only at the walking path in the \
    next 5 meters. If there is a hazard a cane might miss or that is not on a map (construction, \
    cones, barrier, open trench, pothole, scooter or bike on the sidewalk, low branch, pole, \
    parked car on the path, stairs), reply with ONE short phrase under 8 words naming the \
    distance FIRST in meters, then the hazard and where (for example: "3 meters ahead, cones"). \
    Otherwise reply exactly NONE.
    """
}

public struct HazardWatchPolicy: Sendable, Equatable {
    /// Seconds between checks while walking.
    public var interval: TimeInterval = 8
    /// Only check while actually moving (m/s); standing at a curb needs listening, not talking.
    public var minSpeed: Double = 0.5
    /// A reply that shares this fraction of its words with a recent one is a repeat.
    public var similarity: Double = 0.6
    public var repeatWindow: TimeInterval = 30
    private var lastAsk: TimeInterval = -.infinity
    private var recent: [(words: Set<String>, distance: Double?, time: TimeInterval)] = []

    /// Path-hazard words the cloud watch is allowed to turn into an advisory caution. A VLM can
    /// still be wrong about a listed word, but an arbitrary object is not a hazard signal at all.
    private static let allowedHazardWords: Set<String> = Set([
        "cone", "barrier", "barricade", "trench", "pothole", "hole", "curb", "construction",
        "branch", "bike", "bicycle", "scooter", "pole", "stairs", "step", "fence", "snow",
        "ice", "debris", "obstacle", "bench", "trash", "car", "vehicle", "motorcycle", "low",
    ].map { SceneVocabulary.stem($0) })

    public init() {}

    public static func == (a: HazardWatchPolicy, b: HazardWatchPolicy) -> Bool {
        a.interval == b.interval && a.minSpeed == b.minSpeed
    }

    /// Give back the slot `shouldAsk` just took, when no request could be sent (no fresh frame):
    /// the next tick may try again instead of waiting a full interval (Muse final review).
    public mutating func refund(now: TimeInterval) { lastAsk = now - interval + 2 }   // retry in 2 s, not every tick (Muse)

    /// True when a new check should be sent now.
    public mutating func shouldAsk(now: TimeInterval, speed: Double) -> Bool {
        guard speed > minSpeed, now - lastAsk >= interval else { return false }
        lastAsk = now
        return true
    }

    /// Parses the model's reply into a spoken line ("Caution: cones ahead, 3 meters."), or nil for
    /// NONE / empty / a near-duplicate of something said in the last `repeatWindow` seconds.
    public mutating func line(forReply reply: String, now: TimeInterval) -> String? {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'*`"))
        if text.isEmpty || text.uppercased().hasPrefix("NONE") { return nil }
        // A hazard-watch reply is advisory and cannot clear a path. Reuse the same refusal table
        // as the scene gate so "The path is clear" never becomes the misleading line
        // "Caution: The path is clear." (pinned by `hazardWatchReassuranceIsRejected`).
        if CloudSceneGate.reassurance(in: text) != nil { return nil }
        // First sentence: stop at . ! ? or a newline — but not at a decimal point ("2.5 meters").
        if let r = text.range(of: #"[.!?](\s|$)|\n"#, options: .regularExpression) { text = String(text[..<r.lowerBound]) }
        guard SceneVocabulary.tokens(text).contains(where: {
            Self.allowedHazardWords.contains(SceneVocabulary.stem($0))
        }) else { return nil }
        let words = text.split(separator: " ").prefix(12)
        guard !words.isEmpty else { return nil }
        text = words.joined(separator: " ")
        // Numbers do not vote on "same hazard?", but a same hazard reported ≥ 1 m closer is an
        // update worth saying ("cones ahead, 2 meters" after "…, 5 meters"; Muse final review).
        let tokens = words.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        let set = Set(tokens.filter { Double($0) == nil })
        let distance = tokens.compactMap(Double.init).first
        recent.removeAll { now - $0.time > repeatWindow }
        let repeated = recent.contains { r in
            guard Self.jaccard(r.words, set) >= similarity else { return false }
            if let d = distance, let old = r.distance, d <= old - 1 { return false }   // closer: update
            return true
        }
        if repeated { return nil }
        recent.append((set, distance, now))
        return "Caution: \(text)."
    }

    /// Removes a spoken distance ("…, 3 meters", "about 2.5 m", "10 feet") from a reply whose
    /// frame is too old for the number to still be true; the hazard and its side stay.
    public static func withoutDistance(_ reply: String) -> String {
        let pattern = #"[,;]?\s*(about|around|roughly|approximately|~)?\s*\d+(\.\d+)?\s*(meters?|metres?|m|feet|foot|ft)\b"#
        return reply.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let u = a.union(b).count
        return u == 0 ? 0 : Double(a.intersection(b).count) / Double(u)
    }
}

// MARK: - Hazard map (GeoJSON)

/// One confirmed hazard, geotagged — the "every cane is a sidewalk sensor" record.
public struct HazardRecord: Sendable, Equatable, Codable {
    /// "dropOff" / "pothole" / "stepUp" / "lowObstacle" / "sign" / "vision".
    public var kind: String
    /// What was spoken ("Drop-off ahead, two meters.").
    public var text: String
    public var latitude: Double
    public var longitude: Double
    /// Horizontal accuracy of the fix (m).
    public var accuracy: Double
    /// Seconds since 1970.
    public var time: TimeInterval
    /// Snapshot file name next to the GeoJSON, if one was saved.
    public var photo: String?

    public init(kind: String, text: String, latitude: Double, longitude: Double, accuracy: Double,
                time: TimeInterval, photo: String? = nil) {
        self.kind = kind
        self.text = text
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.time = time
        self.photo = photo
    }
}

public enum HazardGeoJSON {
    /// A FeatureCollection of Points (lon, lat order, per RFC 7946) that opens in geojson.io,
    /// QGIS, Google My Maps or Apple's Files preview. A record with no fix (accuracy < 0) gets a
    /// null geometry (valid RFC 7946 §3.2) instead of a bogus point at 0, 0.
    public static func encode(_ records: [HazardRecord]) throws -> Data {
        let iso = ISO8601DateFormatter()
        let features: [[String: Any]] = records.map { r in
            var props: [String: Any] = [
                "kind": r.kind, "text": r.text, "accuracy_m": r.accuracy,
                "time": iso.string(from: Date(timeIntervalSince1970: r.time)),
            ]
            if let p = r.photo { props["photo"] = p }
            let geometry: Any = r.accuracy < 0
                ? NSNull()
                : ["type": "Point", "coordinates": [r.longitude, r.latitude]] as [String: Any]
            return ["type": "Feature", "geometry": geometry, "properties": props]
        }
        let doc: [String: Any] = ["type": "FeatureCollection", "features": features]
        return try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
    }
}
