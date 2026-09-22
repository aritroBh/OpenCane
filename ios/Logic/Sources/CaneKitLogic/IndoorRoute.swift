//
//  IndoorRoute.swift
//  CaneKitLogic
//
//  The indoor leg of a walk (Step 62): a short spoken step script that takes a blind walker from a
//  room to the building's exit door, and the handover to the outdoor GPS route once they are out.
//  GPS is useless inside, and ARKit breadcrumbs were out of scope, so the indoor leg is a list of
//  human-recorded steps ("Turn right. Walk about 14 steps.") advanced by the pedometer.
//
//  Purpose:
//    · `IndoorScript` / `IndoorStep` / `IndoorTurn` / `IndoorExit` — the file schema
//      (ios/CaneKit/Resources/indoor_*.json bundled, Documents/indoor/<id>.json recorded) and its
//      validation.
//    · `IndoorProgress` + `IndoorEvent` — pedometer steps / "next" → which line to speak.
//    · `IndoorHandover` — when the walker is outside with a GPS fix good enough to start the
//      outdoor route (or has said "I'm outside").
//    · `IndoorRecorder` — a sighted teammate walks the route once; pedometer, yaw and spoken
//      landmarks become an `IndoorScript`.
//
//  Rules (the numbers are pinned in IndoorRouteTests.swift):
//    · A step with `steps = n` advances at ceil(0.85·n) walked in it — early, because stride varies
//      and the next step's line names its turn; its landmark is said once at ≥ 0.7·n. Step
//      boundaries are the nominal counts, so early advances never drift. "next" advances regardless
//      and re-bases the count. Never backwards; nothing after the exit.
//    · A pedometer jump reads at most 2 lines (first skipped step's line + the latest).
//    · A draft (`walked == false`) says `IndoorProgress.notWalkedLine` once before step 0.
//    · Handover: armed by the exit (or "I'm outside"), then 3 consecutive fixes ≤ 15 m accuracy
//      within `radiusM`; a worse fix neither counts nor resets, a good fix outside resets.
//      "I'm outside" hands over at once with a fix ≤ 30 m accuracy within `radiusM` in the last
//      20 s, else on the first fix ≤ 20 m accuracy within `radiusM`. GPS-only (review round: a locked
//      phone pauses the pedometer): 3 consecutive fixes ≤ 10 m within 15 m of the exit hand over
//      without the exit; a looser or farther fix resets that run.
//    · Recording's exit fallback (no good fix in the window) is a fix ≤ 30 m, and a last-known fix
//      at most 20 s old; else no fix.
//    · While "Add landmark" waits, a command (stop, I'm outside, emergency, yes / no) is not a
//      landmark (`IndoorRecorder.isLandmarkText`).
//    · Recorder: a new step at a turn of |Δyaw| ≥ 60° held ≥ 1.5 s from the step's heading;
//      ≥ 150° is "around"; positive yaw is left.
//    · Script lines are human-authored route facts, spoken at `.nav` like an outdoor waypoint's
//      `say` — never through the scene / obstacle path, and never logged as `speech` (the app logs
//      `indoor {…}`; e2e.py asserts on `speech`).
//
//  Owner / callers: `IndoorGuide` (app, ios/CaneKit/Navigation, Step 62) loads scripts, drives
//  `IndoorProgress` from CMPedometer and `IndoorHandover` from LocationService; the Settings
//  "Record indoor route" card drives `IndoorRecorder`; `ConversationCoordinator` matches
//  `fromAliases` for `.routeFromTo`. Pure Foundation, nonisolated values, no clock (callers pass
//  `now` / `t`).
//  Tests: IndoorRouteTests.swift.
//

import Foundation

// MARK: - Script schema

/// Which way the walker turns at the start of an indoor step. Raw values are the JSON strings.
/// Produced by `IndoorRecorder` (sign and size of the yaw change); informational in `IndoorProgress`
/// (the step's `say` already names the turn).
public enum IndoorTurn: String, Codable, Sendable, Equatable {
    /// Straight on (always the first step of a recorded script).
    case none
    /// Counter-clockwise, positive yaw.
    case left
    /// Clockwise, negative yaw.
    case right
    /// A turn of `IndoorRecorder.aroundThresholdDeg` or more either way.
    case around
}

/// One step of an indoor script: what to say on entering it, how far it goes, which way it turns
/// and what the walker passes. Pinned by `indoorScriptDecodesWithDefaults`.
public struct IndoorStep: Codable, Sendable, Equatable {
    /// Spoken on entering this step ("Turn right. Walk about 14 steps."), ≤ 140 characters.
    public var say: String
    /// Pedometer steps in this step before the next one; nil = advance only by "next" (a door, a
    /// lift). JSON optional.
    public var steps: Int?
    /// The turn at the start of the step. JSON optional, default `.none`.
    public var turn: IndoorTurn
    /// Spoken once at ~70% of `steps` ("The personal lab is on your left."). JSON optional.
    public var landmark: String?

    /// Creates a step; used by `IndoorRecorder.script` and the tests.
    /// - Parameters:
    ///   - say: the line spoken on entering the step.
    ///   - steps: pedometer steps in it, or nil for "next" only.
    ///   - turn: the turn at its start (default `.none`).
    ///   - landmark: the landmark line, or nil.
    public init(say: String, steps: Int?, turn: IndoorTurn = .none, landmark: String? = nil) {
        self.say = say
        self.steps = steps
        self.turn = turn
        self.landmark = landmark
    }

    /// The JSON keys (the property names; hand-written drafts and recorded files use them).
    enum CodingKeys: String, CodingKey { case say, steps, turn, landmark }

    /// Decodes a step; `steps`, `turn` (→ `.none`) and `landmark` may be absent.
    /// - Throws: `DecodingError` when `say` is missing or a field is mistyped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        say = try c.decode(String.self, forKey: .say)
        steps = try c.decodeIfPresent(Int.self, forKey: .steps)
        turn = try c.decodeIfPresent(IndoorTurn.self, forKey: .turn) ?? .none
        landmark = try c.decodeIfPresent(String.self, forKey: .landmark)
    }
}

/// Where the indoor leg ends: the exit door's outdoor side, the line said there and the handover
/// radius `IndoorHandover` checks fixes against.
public struct IndoorExit: Codable, Sendable, Equatable {
    /// Spoken when the last step completes ("You are at the ISR front doors. Go outside and wait a
    /// moment for GPS."), ≤ 140 characters.
    public var say: String
    /// Latitude of the outdoor side of the door, degrees.
    public var lat: Double
    /// Longitude of the outdoor side of the door, degrees.
    public var lon: Double
    /// Handover radius, metres, 10–60 (`IndoorScript.radiusRangeM`). JSON optional, default 25.
    public var radiusM: Double

    /// Creates an exit.
    /// - Parameters:
    ///   - say: the exit line.
    ///   - lat: latitude, degrees.
    ///   - lon: longitude, degrees.
    ///   - radiusM: handover radius, metres (default `IndoorScript.defaultRadiusM`).
    public init(say: String, lat: Double, lon: Double, radiusM: Double = IndoorScript.defaultRadiusM) {
        self.say = say
        self.lat = lat
        self.lon = lon
        self.radiusM = radiusM
    }

    /// The JSON keys (property names).
    enum CodingKeys: String, CodingKey { case say, lat, lon, radiusM }

    /// Decodes an exit; `radiusM` may be absent (→ 25).
    /// - Throws: `DecodingError` when `say`, `lat` or `lon` is missing or mistyped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        say = try c.decode(String.self, forKey: .say)
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
        radiusM = try c.decodeIfPresent(Double.self, forKey: .radiusM) ?? IndoorScript.defaultRadiusM
    }

    /// `lat` / `lon` as a `Coordinate` for `GeoMath`.
    public var coordinate: Coordinate { Coordinate(latitude: lat, longitude: lon) }
}

/// One indoor route: a room (or building) to its exit door, then an outdoor start place.
/// Pinned by `indoorScriptDecodesWithDefaults`, `indoorScriptValidationCatchesBadScripts`.
public struct IndoorScript: Codable, Sendable, Equatable {
    /// Metres per step when the script has no measured `strideM`.
    public static let defaultStrideM = 0.7
    /// Handover radius when a file gives none, metres.
    public static let defaultRadiusM = 25.0
    /// Allowed handover radii, metres: under 10 m a good fix can still miss it; over 60 m the
    /// walker could still be inside a neighbouring building.
    public static let radiusRangeM: ClosedRange<Double> = 10...60
    /// Longest spoken line (step `say`, landmark, exit `say`), characters — one breath.
    public static let maxSayCharacters = 140

    /// Stable id, also the recorded file name ("isr_lab_to_front_doors", "recorded_<date>"); a
    /// recorded script replaces a bundled one with the same id.
    public var id: String
    /// Spoken / shown name ("ISR lab to the front doors").
    public var name: String
    /// Spoken origins that pick this script for "take me from <origin> to …" (["ISR", "the lab"]).
    public var fromAliases: [String]
    /// `CampusPlaces` id where the outdoor leg starts ("isr").
    public var outdoorPlaceID: String
    /// false for a floor-plan draft nobody has walked: `IndoorProgress` says `notWalkedLine` first.
    public var walked: Bool
    /// ISO date the script was recorded, nil for a draft.
    public var recordedAt: String?
    /// Metres per step measured while recording; nil → `defaultStrideM`.
    public var strideM: Double?
    /// The steps in walking order; the last one ends at the exit door.
    public var steps: [IndoorStep]
    /// The exit door and handover radius.
    public var exit: IndoorExit

    /// Memberwise initialiser (`IndoorRecorder.script`, tests).
    public init(id: String, name: String, fromAliases: [String], outdoorPlaceID: String, walked: Bool,
                recordedAt: String?, strideM: Double?, steps: [IndoorStep], exit: IndoorExit) {
        self.id = id
        self.name = name
        self.fromAliases = fromAliases
        self.outdoorPlaceID = outdoorPlaceID
        self.walked = walked
        self.recordedAt = recordedAt
        self.strideM = strideM
        self.steps = steps
        self.exit = exit
    }

    /// Metres per step: `strideM` when it is a positive finite number, else `defaultStrideM`.
    public var stride: Double {
        if let s = strideM, s.isFinite, s > 0 { return s }
        return Self.defaultStrideM
    }

    /// Decodes a script file with a plain `JSONDecoder`. Caller: `IndoorGuide` (bundled and
    /// Documents/indoor/*.json).
    /// - Parameter data: the file's bytes.
    /// - Throws: `DecodingError` for a malformed file.
    public static func load(from data: Data) throws -> IndoorScript {
        try JSONDecoder().decode(IndoorScript.self, from: data)
    }

    /// Every problem that should keep this script from being walked, as short English sentences
    /// (empty = valid): no or blank aliases, no steps, a non-positive step count, a blank or
    /// over-long line, a radius outside `radiusRangeM`. `IndoorGuide` skips (and logs) an invalid
    /// file; the recorder checks before saving. Pinned by `indoorScriptValidationCatchesBadScripts`.
    public func validate() -> [String] {
        var problems: [String] = []
        let max = Self.maxSayCharacters
        if fromAliases.isEmpty || fromAliases.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            problems.append("fromAliases must list at least one spoken origin, none blank.")
        }
        if steps.isEmpty { problems.append("steps is empty.") }
        for (i, step) in steps.enumerated() {
            if let n = step.steps, n <= 0 { problems.append("step \(i + 1): steps must be positive, is \(n).") }
            if step.say.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problems.append("step \(i + 1): say is blank.")
            }
            if step.say.count > max { problems.append("step \(i + 1): say is \(step.say.count) characters, max \(max).") }
            if let lm = step.landmark, lm.count > max {
                problems.append("step \(i + 1): landmark is \(lm.count) characters, max \(max).")
            }
        }
        if exit.say.count > max { problems.append("exit say is \(exit.say.count) characters, max \(max).") }
        if !Self.radiusRangeM.contains(exit.radiusM) {
            problems.append("exit radius \(exit.radiusM) m is outside 10–60 m.")
        }
        return problems
    }
}

// MARK: - Progress

/// What `IndoorProgress` tells the app to do, in order.
public enum IndoorEvent: Sendable, Equatable {
    /// Speak this line at `.nav` (a step's `say`, its landmark, the exit `say`, the draft caveat).
    case say(String)
    /// The script moved to this step index (log `indoor {action: advanced, index}`).
    case advanced(Int)
    /// The last step completed: arm `IndoorHandover.reachedExit()`.
    case reachedExit
}

/// The step machine: cumulative pedometer steps and "next" → lines and advances. Pure; the app's
/// `IndoorGuide` owns one per indoor leg. Pinned by the `indoor…` tests in IndoorRouteTests.swift.
public struct IndoorProgress: Sendable, Equatable {
    /// Fraction of a step's count after which it advances (ceil). Early on purpose: a walker's
    /// stride is rarely the recorder's, and the next line names the turn.
    public static let advanceFraction = 0.85
    /// Fraction of a step's count at which its landmark is said.
    public static let landmarkFraction = 0.7
    /// Most lines one update may speak after a pedometer jump.
    public static let maxJumpLines = 2
    /// Said once before step 0 of a draft (`walked == false`). Step 65 (calm feedback) shortened it
    /// from 92 characters ("This indoor route has not been walked yet. Use your cane and ask for
    /// help if it seems wrong.") to the two facts the walker acts on.
    public static let notWalkedLine = "Draft route. Use your cane."

    /// The script being walked.
    public let script: IndoorScript
    /// Current step index (stays on the last step at the exit).
    public private(set) var index = 0
    /// The last step completed; every later update / next is ignored.
    public private(set) var atExit = false
    /// `start()` has run (explicitly or from the first update / next).
    public private(set) var started = false
    /// Pedometer count at which the current step began: the sum of the earlier steps' nominal
    /// counts, or the count when "next" was said.
    private var stepStart = 0
    /// Highest cumulative pedometer count seen (a lower one is ignored).
    private var latestSteps = 0
    /// The current step's landmark has been said (or dropped in a collapsed jump).
    private var landmarkSaid = false

    /// A machine at step 0, not yet started.
    /// - Parameter script: the script to walk.
    public init(script: IndoorScript) {
        self.script = script
    }

    /// The line "repeat" says: the current step's `say`, or the exit line at the exit.
    public var currentSay: String {
        if atExit || script.steps.isEmpty { return script.exit.say }
        return script.steps[index].say
    }

    /// Steps walked in the current step (negative right after an early advance).
    public var walkedInStep: Int { latestSteps - stepStart }

    /// The opening lines: the draft caveat (when not walked), then step 0's `say`. Once; later calls
    /// return []. An empty script goes straight to the exit.
    /// - Returns: the events to perform.
    public mutating func start() -> [IndoorEvent] {
        guard !started else { return [] }
        started = true
        var events: [IndoorEvent] = []
        if !script.walked { events.append(.say(Self.notWalkedLine)) }
        if script.steps.isEmpty {
            atExit = true
            events += [.say(script.exit.say), .reachedExit]
        } else {
            events.append(.say(script.steps[0].say))
        }
        return events
    }

    /// Feed the pedometer. Advances every step whose count is reached, says the current step's
    /// landmark at 70%, and collapses a jump to at most `maxJumpLines` lines. Starts first if needed.
    /// - Parameter stepsWalked: cumulative steps since the indoor leg began (CMPedometer
    ///   `numberOfSteps`); a lower value than before is ignored.
    /// - Returns: the events to perform, in order.
    public mutating func update(stepsWalked: Int) -> [IndoorEvent] {
        let events = start()
        guard !atExit else { return events }
        latestSteps = Swift.max(latestSteps, stepsWalked)
        var body: [(event: IndoorEvent, landmark: Bool)] = []
        while !atExit, let n = script.steps[index].steps, n > 0,
              latestSteps - stepStart >= Self.advanceCount(n) {
            // The passed step's landmark (≥ 70% is implied by ≥ 85%).
            if !landmarkSaid, let lm = script.steps[index].landmark { body.append((.say(lm), true)) }
            stepStart += n
            body += advance().map { ($0, false) }
        }
        if !atExit, !landmarkSaid, let n = script.steps[index].steps, n > 0,
           let lm = script.steps[index].landmark,
           Double(latestSteps - stepStart) + 1e-9 >= Self.landmarkFraction * Double(n) {
            landmarkSaid = true
            body.append((.say(lm), true))
        }
        return events + Self.collapsed(body)
    }

    /// "next" / watch Next / crown: advance one step whatever the count, and count the new step
    /// from the latest pedometer value. At the last step it is the exit. Starts first if needed.
    /// - Returns: the events to perform (empty at the exit).
    public mutating func next() -> [IndoorEvent] {
        var events = start()
        guard !atExit else { return events }
        stepStart = latestSteps
        events += advance()
        return events
    }

    /// Pedometer steps in a step of `n` after which it advances: ceil(0.85·n), with a 1e-9 guard
    /// so float noise (0.85·20 = 16.999…) never adds a step.
    static func advanceCount(_ n: Int) -> Int {
        Int((advanceFraction * Double(n) - 1e-9).rounded(.up))
    }

    /// Move to the next step (`.advanced` + its `say`), or to the exit (exit `say` + `.reachedExit`).
    private mutating func advance() -> [IndoorEvent] {
        guard index + 1 < script.steps.count else {
            atExit = true
            return [.say(script.exit.say), .reachedExit]
        }
        index += 1
        landmarkSaid = false
        return [.advanced(index), .say(script.steps[index].say)]
    }

    /// At most `maxJumpLines` lines from one update: with more, keep the first and the last step /
    /// exit line (landmarks dropped); with only one step line, keep it and the landmark after it.
    /// Non-say events are always kept, in order.
    private static func collapsed(_ body: [(event: IndoorEvent, landmark: Bool)]) -> [IndoorEvent] {
        let sayAt = body.indices.filter { if case .say = body[$0].event { return true } else { return false } }
        guard sayAt.count > maxJumpLines else { return body.map(\.event) }
        let stepSayAt = sayAt.filter { !body[$0].landmark }
        let keep: Set<Int>
        if let first = stepSayAt.first, let last = stepSayAt.last, first != last {
            keep = [first, last]
        } else if let only = stepSayAt.first {
            keep = [only, sayAt.last == only ? sayAt[sayAt.count - 2] : sayAt.last!]
        } else {
            keep = Set(sayAt.suffix(maxJumpLines))
        }
        return body.indices.compactMap { i in
            if case .say = body[i].event, !keep.contains(i) { return nil }
            return body[i].event
        }
    }
}

// MARK: - Handover

/// When the indoor leg hands over to the outdoor route. Pure; `IndoorGuide` feeds it every
/// LocationService fix and calls `reachedExit()` on `.reachedExit`, `forced(now:)` on "I'm outside".
/// `fix` / `forced` return true exactly once, at the handover. Pinned by the `handover…` tests.
public struct IndoorHandover: Sendable, Equatable {
    /// A fix counts toward the run when its horizontal accuracy is this good or better, metres.
    public static let goodAccuracyM = 15.0
    /// Consecutive good fixes within the radius needed after the exit.
    public static let consecutiveFixes = 3
    /// "I'm outside" hands over at once if a recent fix is at least this accurate, metres, lies
    /// within the exit's `radiusM` (Muse M4: it was 60 m, wider than any exit radius)…
    public static let forcedRecentAccuracyM = 30.0
    /// …and is at most this old, seconds.
    public static let forcedRecentWindowS = 20.0
    /// After "I'm outside" with no such fix: the first fix this accurate within the radius hands over.
    public static let waitingAccuracyM = 20.0
    /// GPS-only handover (review round, item 2): with the phone locked CMPedometer pauses, so the
    /// script may never reach `.reachedExit`. A fix counts toward the GPS-only run when its accuracy
    /// is this good or better, metres — tighter than `goodAccuracyM` because nothing else says the
    /// walker is at the door (indoors a fix is typically 30–65 m)…
    public static let gpsOnlyAccuracyM = 10.0
    /// …and it lies at most this far from the exit, metres (tighter than the default 25 m radius)…
    public static let gpsOnlyRadiusM = 15.0
    /// …for this many consecutive fixes; any other fix resets the run.
    public static let gpsOnlyFixes = 3

    /// The exit whose coordinate and radius are checked.
    public let exit: IndoorExit
    /// The script's last step completed (`reachedExit()`).
    public private(set) var exitReached = false
    /// The walker said "I'm outside" (`forced(now:)`).
    public private(set) var forcedByWalker = false
    /// "I'm outside" came with no usable recent fix; the next qualifying fix hands over.
    public private(set) var waitingForGPS = false
    /// The handover happened (once).
    public private(set) var handedOver = false
    /// Consecutive good fixes within the radius since the gate was armed.
    private var goodRun = 0
    /// Consecutive tight fixes near the exit while the gate is not armed (GPS-only handover).
    private var gpsOnlyRun = 0
    /// Valid fixes of the last `forcedRecentWindowS` seconds, for `forced(now:)`.
    private var recent: [RecentFix] = []

    /// A remembered fix: when, how accurate, how far from the exit.
    private struct RecentFix: Sendable, Equatable {
        var t: Double
        var accuracyM: Double
        var distanceM: Double
    }

    /// A gate for one exit, not armed.
    /// - Parameter exit: the script's exit.
    public init(exit: IndoorExit) {
        self.exit = exit
    }

    /// The script reached its exit: fixes from now on count toward the run. Fixes before this
    /// never do (a good fix near the door from inside is not "outside").
    public mutating func reachedExit() {
        exitReached = true
    }

    /// Feed one GPS fix. Armed (exit reached or "I'm outside"): `consecutiveFixes` fixes ≤
    /// `goodAccuracyM` within `radiusM`. Not armed: the GPS-only run — `gpsOnlyFixes` consecutive
    /// fixes ≤ `gpsOnlyAccuracyM` within `gpsOnlyRadiusM` (the locked-phone path; pinned by
    /// `handoverGpsOnlyFiresOnThreeTightFixesWithoutTheExit`,
    /// `handoverGpsOnlyNeedsConsecutiveTightFixesNearTheExit`). Every valid fix is remembered for
    /// `forcedRecentWindowS` for `forced(now:)`. Caller: `IndoorGuide.ingest`.
    /// - Parameters:
    ///   - lat: latitude, degrees.
    ///   - lon: longitude, degrees.
    ///   - accuracyM: horizontal accuracy, metres; non-finite or negative = invalid, ignored.
    ///   - now: the caller's monotonic clock, seconds.
    /// - Returns: true when this fix completes the handover (once).
    public mutating func fix(lat: Double, lon: Double, accuracyM: Double, now: Double) -> Bool {
        guard !handedOver, lat.isFinite, lon.isFinite, accuracyM.isFinite, accuracyM >= 0, now.isFinite else {
            return false
        }
        let d = GeoMath.distanceMeters(Coordinate(latitude: lat, longitude: lon), exit.coordinate)
        recent.append(RecentFix(t: now, accuracyM: accuracyM, distanceM: d))
        recent.removeAll { now - $0.t > Self.forcedRecentWindowS }
        if waitingForGPS, accuracyM <= Self.waitingAccuracyM, d <= exit.radiusM { return handOver() }
        guard exitReached || forcedByWalker else {
            gpsOnlyRun = accuracyM <= Self.gpsOnlyAccuracyM && d <= Self.gpsOnlyRadiusM ? gpsOnlyRun + 1 : 0
            return gpsOnlyRun >= Self.gpsOnlyFixes ? handOver() : false
        }
        guard accuracyM <= Self.goodAccuracyM else { return false }
        goodRun = d <= exit.radiusM ? goodRun + 1 : 0
        return goodRun >= Self.consecutiveFixes ? handOver() : false
    }

    /// The walker said "I'm outside". Hands over now when a fix ≤ 30 m accuracy within the exit's
    /// `radiusM` arrived in the last 20 s; otherwise waits for GPS (the next fix ≤ 20 m within the
    /// radius). Why a fix from before the exit (or before the words) may count here, unlike the
    /// armed gate: the walker's own statement is the evidence that they are outside, and the fix
    /// only has to confirm they are at *this* door — the 20 s window, 30 m accuracy and the exit
    /// radius bound how stale or far that confirmation can be (review round item 8, Muse M4).
    /// Pinned by `handoverForcedIsImmediateWithARecentUsableFix`, `handoverForcedWithoutAFixWaitsForGPS`,
    /// `handoverForcedNeedsTheRecentFixInsideTheRadius`. Caller: `IndoorGuide.walkerIsOutside`.
    /// - Parameter now: the caller's monotonic clock, seconds (same clock as `fix`).
    /// - Returns: true when this completes the handover (false once already handed over).
    public mutating func forced(now: Double) -> Bool {
        guard !handedOver else { return false }
        forcedByWalker = true
        let usable = recent.contains { f in
            let age = now - f.t
            return age >= 0 && age <= Self.forcedRecentWindowS
                && f.accuracyM <= Self.forcedRecentAccuracyM && f.distanceM <= exit.radiusM
        }
        if usable { return handOver() }
        waitingForGPS = true
        return false
    }

    /// Latch the handover.
    private mutating func handOver() -> Bool {
        handedOver = true
        waitingForGPS = false
        return true
    }
}

// MARK: - Recorder

/// Recording mode: a sighted teammate walks the route once and this turns pedometer counts, device
/// yaw and spoken landmarks into an `IndoorScript`. Pure; the Settings "Record indoor route" card
/// feeds CMPedometer and CMDeviceMotion (xArbitraryZVertical) samples in arrival order.
/// Pinned by the `recorder…` tests.
public struct IndoorRecorder: Sendable, Equatable {
    /// A turn is at least this far from the step's heading, degrees…
    public static let turnThresholdDeg = 60.0
    /// …held at least this long, seconds (a glance or a cane sweep is shorter).
    public static let turnHoldS = 1.5
    /// A turn this large or more is "around", degrees.
    public static let aroundThresholdDeg = 150.0
    /// Exit line when the recording UI gives none.
    public static let defaultExitSay = "You are at the exit door. Go outside and wait a moment for GPS."

    /// One recorded input.
    public enum Event: Sendable, Equatable {
        /// CMPedometer cumulative steps since recording began, at `t` seconds.
        case stepCount(Int, t: Double)
        /// Device yaw, unwrapped degrees, positive = left / counter-clockwise, at `t` seconds.
        case yaw(Double, t: Double)
        /// A spoken landmark (push-to-talk transcript), at `t` seconds.
        case landmark(String, t: Double)
        /// "Finish at the exit": the exit coordinate. Later events are ignored.
        case finish(lat: Double, lon: Double, t: Double)
    }

    /// A step being recorded: its turn angle from the previous heading, steps, landmarks.
    struct Leg: Sendable, Equatable {
        var turnDeg: Double
        var steps: Int
        var landmarks: [String]
    }

    /// Steps so far; the first leg exists from the start.
    private var legs = [Leg(turnDeg: 0, steps: 0, landmarks: [])]
    /// Heading the current step is measured from.
    private var legHeading: Double?
    /// Heading of the step before the current one (to measure a turn that is still going on).
    private var previousHeading: Double?
    /// When |Δyaw| first reached the threshold in the current candidate turn.
    private var holdStart: Double?
    /// Direction of the candidate turn (true = left).
    private var holdLeft = false
    /// Last cumulative pedometer count.
    private var lastCount = 0
    /// The exit coordinate once finished.
    public private(set) var exit: Coordinate?

    /// An empty recording.
    public init() {}

    /// "Finish at the exit" has been recorded.
    public var isFinished: Bool { exit != nil }

    /// Pedometer steps per recorded step so far (for the recording card's live count and tests).
    public var stepCountsSoFar: [Int] { legs.map(\.steps) }

    /// Feed one event in arrival order.
    /// - Parameter event: the input; ignored after `finish`.
    public mutating func handle(_ event: Event) {
        guard exit == nil else { return }
        switch event {
        case .stepCount(let count, _):
            guard count > lastCount else { return }
            legs[legs.count - 1].steps += count - lastCount
            lastCount = count
        case .yaw(let deg, let t):
            yaw(deg, t: t)
        case .landmark(let text, _):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { legs[legs.count - 1].landmarks.append(trimmed) }
        case .finish(let lat, let lon, _):
            if lat.isFinite, lon.isFinite { exit = Coordinate(latitude: lat, longitude: lon) }
        }
    }

    /// The recorded script, or nil before `finish` or with no step walked. Steps with no pedometer
    /// steps are dropped (their landmarks move to the step before). The first step never has a turn.
    /// - Parameters:
    ///   - id: script id ("recorded_<date>").
    ///   - name: spoken name.
    ///   - fromAliases: spoken origins.
    ///   - outdoorPlaceID: `CampusPlaces` id of the outdoor start.
    ///   - recordedAt: ISO date.
    ///   - exitSay: the exit line (default `defaultExitSay`).
    ///   - radiusM: handover radius (default 25).
    ///   - distanceM: measured walking distance (GPS / ARKit), metres; gives `strideM`, else nil.
    public func script(id: String, name: String, fromAliases: [String], outdoorPlaceID: String,
                       recordedAt: String?, exitSay: String = defaultExitSay,
                       radiusM: Double = IndoorScript.defaultRadiusM, distanceM: Double? = nil) -> IndoorScript? {
        guard let exit else { return nil }
        var out: [IndoorStep] = []
        var pending: [String] = []
        for leg in legs {
            guard leg.steps > 0 else {
                if out.isEmpty {
                    pending += leg.landmarks
                } else if !leg.landmarks.isEmpty {
                    out[out.count - 1].landmark = Self.joined((out[out.count - 1].landmark.map { [$0] } ?? []) + leg.landmarks)
                }
                continue
            }
            let turn = out.isEmpty ? IndoorTurn.none : Self.turn(for: leg.turnDeg)
            out.append(IndoorStep(say: Self.say(turn: turn, steps: leg.steps), steps: leg.steps, turn: turn,
                                  landmark: Self.joined(pending + leg.landmarks)))
            pending = []
        }
        guard !out.isEmpty else { return nil }
        let total = out.reduce(0) { $0 + ($1.steps ?? 0) }
        let stride = distanceM.flatMap { $0.isFinite && $0 > 0 ? $0 / Double(total) : nil }
        return IndoorScript(id: id, name: name, fromAliases: fromAliases, outdoorPlaceID: outdoorPlaceID,
                            walked: true, recordedAt: recordedAt, strideM: stride, steps: out,
                            exit: IndoorExit(say: exitSay, lat: exit.latitude, lon: exit.longitude, radiusM: radiusM))
    }

    /// The generated line: "Walk straight about N steps." / "Turn left. Walk about N steps." /
    /// "Turn around. Walk about N steps." ("1 step" singular).
    /// - Parameters:
    ///   - turn: the step's turn.
    ///   - steps: its pedometer steps.
    public static func say(turn: IndoorTurn, steps: Int) -> String {
        let count = steps == 1 ? "1 step" : "\(steps) steps"
        switch turn {
        case .none: return "Walk straight about \(count)."
        case .left: return "Turn left. Walk about \(count)."
        case .right: return "Turn right. Walk about \(count)."
        case .around: return "Turn around. Walk about \(count)."
        }
    }

    /// A turn angle as a turn: under 60° none, 150° or more around, else left (positive) / right.
    /// - Parameter deg: signed degrees, positive = left.
    public static func turn(for deg: Double) -> IndoorTurn {
        if abs(deg) >= aroundThresholdDeg { return .around }
        if abs(deg) < turnThresholdDeg { return .none }
        return deg > 0 ? .left : .right
    }

    /// Landmarks joined into one line, each ending in punctuation; nil when there are none.
    private static func joined(_ landmarks: [String]) -> String? {
        let lines = landmarks.map { l -> String in
            let t = l.trimmingCharacters(in: .whitespacesAndNewlines)
            return [".", "!", "?"].contains(where: t.hasSuffix) ? t : t + "."
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// Turn detection. Before the first step is walked the starting heading follows the walker. While
    /// a new turn step has no steps yet, a turn that keeps going the same way grows (a slow U-turn
    /// confirmed at 120° still ends "around"). Otherwise |Δ| ≥ 60° held ≥ 1.5 s starts a new step.
    private mutating func yaw(_ deg: Double, t: Double) {
        guard deg.isFinite, t.isFinite else { return }
        let last = legs.count - 1
        if legs[last].steps == 0 {
            if last == 0 {
                legHeading = deg
                holdStart = nil
                return
            }
            if let prev = previousHeading {
                let net = deg - prev
                if net * legs[last].turnDeg > 0, abs(net) > abs(legs[last].turnDeg) {
                    legs[last].turnDeg = net
                    legHeading = deg
                }
            }
        }
        guard let heading = legHeading else {
            legHeading = deg
            return
        }
        let delta = deg - heading
        guard abs(delta) >= Self.turnThresholdDeg else {
            holdStart = nil
            return
        }
        guard let start = holdStart, holdLeft == (delta > 0) else {
            holdStart = t
            holdLeft = delta > 0
            return
        }
        guard t - start >= Self.turnHoldS else { return }
        holdStart = nil
        beginStep(heading: deg, from: heading)
    }

    /// A confirmed turn: a new step — or, when the current turn step has no steps or landmarks yet,
    /// the same turn re-measured from the heading before it (dropped if it came back under 60°).
    private mutating func beginStep(heading deg: Double, from heading: Double) {
        let last = legs.count - 1
        if last > 0, legs[last].steps == 0, legs[last].landmarks.isEmpty, let prev = previousHeading {
            let net = deg - prev
            if abs(net) < Self.turnThresholdDeg {
                legs.removeLast()
                previousHeading = nil
            } else {
                legs[last].turnDeg = net
            }
            legHeading = deg
            return
        }
        previousHeading = heading
        legHeading = deg
        legs.append(Leg(turnDeg: deg - heading, steps: 0, landmarks: []))
    }
}

// MARK: - App support (Step 62 app half)

/// Which outdoor route follows the indoor leg. `IndoorScriptCatalog.outdoorLeg(destination:)`.
public enum IndoorOutdoorLeg: Sendable, Equatable {
    /// The bundled route_isr_cif.json (`AppModel.startDemoRoute()`): the only recorded route file.
    case demoRoute
    /// A MapKit walking route from the handover fix (`AppModel.navigate(to:)`), trimmed text.
    case navigate(String)
}

/// Choosing among indoor scripts: merging recorded files over bundled ones, picking one by a spoken
/// origin, choosing the outdoor leg, and naming a recorded file. Pure; callers `IndoorGuide` and
/// `AppModel+Indoor`. Pinned by the `catalog…` tests.
public enum IndoorScriptCatalog {
    /// Id a new recording gets when the teammate types none: the ISR draft's, so the walked
    /// recording replaces the floor-plan draft (`indoor_isr.json`).
    public static let defaultRecordingID = "isr_townsend_to_front_doors"

    /// Bundled scripts with every recorded script of the same id replaced in place (recorded wins);
    /// recorded scripts with new ids follow in their given order.
    /// - Parameters:
    ///   - bundled: scripts from the app bundle.
    ///   - recorded: scripts from Documents/indoor/*.json.
    /// - Returns: the catalog the app walks.
    public static func merged(bundled: [IndoorScript], recorded: [IndoorScript]) -> [IndoorScript] {
        var out = bundled
        for script in recorded {
            if let i = out.firstIndex(where: { $0.id == script.id }) {
                out[i] = script
            } else {
                out.append(script)
            }
        }
        return out
    }

    /// The script whose `fromAliases` contains `origin`, compared with `CampusPlaces.normalize`
    /// (case, punctuation and "the" ignored; whole alias only). A walked script beats a draft; among
    /// equals the first in catalog order. An origin that normalizes to "" matches nothing.
    /// - Parameters:
    ///   - origin: the "from" end of "take me from A to B".
    ///   - scripts: the catalog.
    public static func script(forOrigin origin: String, in scripts: [IndoorScript]) -> IndoorScript? {
        let key = CampusPlaces.normalize(origin)
        guard !key.isEmpty else { return nil }
        let matches = scripts.filter { $0.fromAliases.contains { CampusPlaces.normalize($0) == key } }
        return matches.first(where: \.walked) ?? matches.first
    }

    /// The outdoor leg after the handover: CIF (any alias of the `cif` campus place) or no
    /// destination → the recorded demo route; anything else → a MapKit route to the trimmed text.
    /// - Parameter destination: the "to" end, or nil (Settings "Start indoor route").
    public static func outdoorLeg(destination: String?) -> IndoorOutdoorLeg {
        let text = (destination ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, CampusPlaces.match(text)?.id != "cif" else { return .demoRoute }
        return .navigate(text)
    }

    /// A file-safe script id: lower-cased; every character other than a–z, 0–9, `_` and `-` becomes
    /// `_`; blank → `defaultRecordingID`. Caller: `IndoorGuide.saveRecording`.
    /// - Parameter raw: what the teammate typed.
    public static func sanitizedID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return defaultRecordingID }
        return String(trimmed.map { ch -> Character in
            ("a"..."z").contains(ch) || ("0"..."9").contains(ch) || ch == "_" || ch == "-" ? ch : "_"
        })
    }
}

/// "Finish at the exit" while recording: the exit coordinate from the GPS fixes of a short window —
/// the mean of the good ones, else the last fix ≤ `fallbackAccuracyM`. Pure; `IndoorGuide.finishAtExit`
/// feeds it. Pinned by `exitAveragerAveragesGoodFixesElseTheLastFix`, `exitAveragerFallbackNeedsAUsableFix`.
public struct IndoorExitAverager: Sendable, Equatable {
    /// Longest the teammate stands at the door, seconds.
    public static let windowS = 8.0
    /// A fix is averaged when its horizontal accuracy is this good or better, metres (the handover's
    /// `IndoorHandover.goodAccuracyM`, so the exit is as good as the fixes that will be checked against it).
    public static let goodAccuracyM = IndoorHandover.goodAccuracyM
    /// Good fixes after which the window closes early.
    public static let enoughGoodFixes = 5
    /// A fallback exit (no good fix) must still be this accurate, metres — the same bound "I'm
    /// outside" trusts (`IndoorHandover.forcedRecentAccuracyM`). A 65 m indoor fix saved as the exit
    /// would make every later handover fire in the wrong place (review round, item 6).
    public static let fallbackAccuracyM = IndoorHandover.forcedRecentAccuracyM
    /// The last-known fix (`LocationService.fix`) used when the window had none is at most this old,
    /// seconds (the "I'm outside" window, `IndoorHandover.forcedRecentWindowS`).
    public static let fallbackMaxAgeS = IndoorHandover.forcedRecentWindowS

    /// When "Finish at the exit" was pressed (caller's monotonic clock, seconds).
    public let startedAt: Double
    /// Sums of the good fixes' latitude / longitude.
    private var latSum = 0.0
    private var lonSum = 0.0
    /// Good fixes inside the window.
    public private(set) var goodFixCount = 0
    /// The last fix inside the window with accuracy ≤ `fallbackAccuracyM`.
    private var last: Coordinate?

    /// A window starting at `startedAt`.
    public init(startedAt: Double) {
        self.startedAt = startedAt
    }

    /// Feed one fix; ignored when non-finite, with a negative accuracy, or outside the window. A fix
    /// worse than `fallbackAccuracyM` is neither averaged nor kept as the fallback.
    /// - Parameters:
    ///   - lat: latitude, degrees.
    ///   - lon: longitude, degrees.
    ///   - accuracyM: horizontal accuracy, metres.
    ///   - t: same clock as `startedAt`, seconds.
    public mutating func add(lat: Double, lon: Double, accuracyM: Double, t: Double) {
        guard lat.isFinite, lon.isFinite, accuracyM.isFinite, accuracyM >= 0, t.isFinite,
              t >= startedAt, t - startedAt <= Self.windowS else { return }
        if accuracyM <= Self.fallbackAccuracyM { last = Coordinate(latitude: lat, longitude: lon) }
        guard accuracyM <= Self.goodAccuracyM else { return }
        latSum += lat
        lonSum += lon
        goodFixCount += 1
    }

    /// The window is over: `windowS` elapsed or `enoughGoodFixes` collected.
    /// - Parameter now: same clock as `startedAt`.
    public func isDone(now: Double) -> Bool {
        now - startedAt >= Self.windowS || goodFixCount >= Self.enoughGoodFixes
    }

    /// The mean of the good fixes, else the last fix ≤ `fallbackAccuracyM`, else nil.
    public func result() -> Coordinate? {
        guard goodFixCount > 0 else { return last }
        return Coordinate(latitude: latSum / Double(goodFixCount), longitude: lonSum / Double(goodFixCount))
    }

    /// Whether the last-known fix may stand in for a window with no usable fix: accuracy finite, ≥ 0
    /// and ≤ `fallbackAccuracyM`, and age finite and ≤ `fallbackMaxAgeS`. Caller:
    /// `IndoorGuide.completeExit`. Pinned by `exitAveragerFallbackNeedsAUsableFix`.
    /// - Parameters:
    ///   - accuracyM: `GeoFix.accuracy`, metres.
    ///   - ageS: now − `GeoFix.timestamp`, seconds (wall clock).
    public static func usableFallback(accuracyM: Double, ageS: Double) -> Bool {
        accuracyM.isFinite && accuracyM >= 0 && accuracyM <= fallbackAccuracyM
            && ageS.isFinite && ageS <= fallbackMaxAgeS
    }
}

/// The indoor leg's progress in words: the status report clause and the Guide card's status line.
/// Steps count from 1. Pinned by `indoorStatusLinesCountFromOne`.
public enum IndoorStatus {
    /// "Indoors: step 3 of 5." / "Indoors: at the exit, waiting for GPS." (`StatusFacts.indoorClause`).
    /// - Parameters:
    ///   - index: `IndoorProgress.index` (0-based).
    ///   - count: the script's step count.
    ///   - atExit: `IndoorProgress.atExit`.
    public static func statusClause(index: Int, count: Int, atExit: Bool) -> String {
        atExit ? "Indoors: at the exit, waiting for GPS." : "Indoors: step \(index + 1) of \(count)."
    }

    /// "Indoors · step 3 of 5" / "Indoors · at the exit" (GuideCard status line).
    /// - Parameters: as `statusClause`.
    public static func guideLine(index: Int, count: Int, atExit: Bool) -> String {
        atExit ? "Indoors · at the exit" : "Indoors · step \(index + 1) of \(count)"
    }
}

/// CMDeviceMotion `attitude.yaw` (radians, wrapping at ±π; positive = counter-clockwise / left with
/// `xArbitraryZVertical`) → the unwrapped degrees `IndoorRecorder` needs (a 190° U-turn must not
/// read as −170°). Each sample's change is taken as the shortest way round (at 10 Hz a real turn
/// never moves 180° between samples). Pinned by `yawUnwrapperKeepsCountingAcrossTheSeam`.
public struct IndoorYawUnwrapper: Sendable, Equatable {
    /// The last raw sample, degrees in (−180, 180].
    private var lastRaw: Double?
    /// The unwrapped total, degrees.
    private var total = 0.0

    /// A fresh unwrapper; the first sample is returned as-is.
    public init() {}

    /// Feed one sample.
    /// - Parameter radians: `CMAttitude.yaw`.
    /// - Returns: unwrapped degrees, or nil for a non-finite sample (ignored).
    public mutating func unwrap(radians: Double) -> Double? {
        guard radians.isFinite else { return nil }
        let deg = radians * 180 / .pi
        if let lastRaw {
            var delta = (deg - lastRaw).truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta -= 360 }
            if delta <= -180 { delta += 360 }
            total += delta
        } else {
            total = deg
        }
        lastRaw = deg
        return total
    }
}

/// The simulator / demo step source: `CANEKIT_INDOOR_SIM_STEPS_PER_S` and the Guide's "Simulate
/// walk" while indoors feed synthetic cumulative steps instead of CMPedometer.
/// Pinned by `simStepsParseTheRateAndCountWholeSteps`.
public enum IndoorSimSteps {
    /// "Simulate walk" rate when no environment rate is set, steps per second (a relaxed walk).
    public static let defaultRate = 1.8
    /// Highest accepted rate, steps per second (a larger value is clamped).
    public static let maxRate = 5.0
    /// A simulated walker says "next" by itself after this long on a step with no count (a door, a
    /// lift, the draft's "Say next when you get there"), seconds — else a simulation stalls there.
    public static let nextOnlyWaitS = 3.0

    /// The environment value as a rate: a positive number, clamped to `maxRate`; else nil (off).
    /// - Parameter text: `ProcessInfo.environment["CANEKIT_INDOOR_SIM_STEPS_PER_S"]`.
    public static func rate(from text: String?) -> Double? {
        guard let text, let v = Double(text.trimmingCharacters(in: .whitespaces)), v.isFinite, v > 0 else {
            return nil
        }
        return Swift.min(v, maxRate)
    }

    /// Cumulative synthetic steps after `elapsedS` seconds: floor(rate · t), never negative.
    /// - Parameters:
    ///   - rate: steps per second.
    ///   - elapsedS: seconds since the simulation began.
    public static func steps(rate: Double, elapsedS: Double) -> Int {
        guard rate.isFinite, elapsedS.isFinite, elapsedS > 0 else { return 0 }
        return Int((rate * elapsedS).rounded(.down))
    }
}

/// Recording-mode timings used by the app's Settings card (`IndoorGuide.startRecording` /
/// `addLandmark`). Pinned by `recorderTimingsAreTheSpec`.
extension IndoorRecorder {
    /// CMDeviceMotion sample interval while recording, seconds (10 Hz: a 60° turn held 1.5 s is
    /// 15 samples; the yaw unwrapper needs < 180° between samples).
    public static let yawSampleIntervalS = 0.1
    /// "Add landmark" arms a one-shot transcript hook for this long, seconds; a transcript after
    /// it goes to the conversation as usual (a push-to-talk that heard nothing must not turn the
    /// walker's next question into a landmark).
    public static let landmarkWindowS = 20.0

    /// Whether a transcript heard while "Add landmark" waits is a landmark. Not a landmark: blank
    /// text, or a command the conversation must act on — Stop route, "I'm outside", emergency and
    /// the yes / no answer to its prompt (`FastPathIntentClassifier.classify`). Everything else,
    /// including other fast-path phrases, is attached as spoken (a teammate naming "the help desk"
    /// is recording, not asking for help). Review round item 1: the hook used to swallow "stop".
    /// Caller: `IndoorGuide.takeTranscript`. Pinned by `landmarkHookLetsCommandsThrough`.
    /// - Parameter text: the finalized transcript.
    public static func isLandmarkText(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch FastPathIntentClassifier.classify(query: text) {
        case .some(.stopRoute), .some(.indoorOutside), .some(.emergency), .some(.confirm):
            return false
        default:
            return true
        }
    }
}
