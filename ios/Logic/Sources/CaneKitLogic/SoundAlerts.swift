//
//  SoundAlerts.swift
//  CaneKitLogic
//
//  Which sounds a blind pedestrian needs to be told about, and how often.
//
//  Purpose: the phone's microphone hears traffic the LiDAR cannot see — a siren two blocks away, a
//  horn behind the walker, a car pulling out of a driveway. `SoundWatcher` (app target) runs
//  Apple's built-in `SNClassifySoundRequest(classifierIdentifier: .version1)` over the mic and
//  hands every (label, confidence) pair here; everything with a number in it — the confidence
//  gates, how many consecutive analysis windows must agree, and how long before the same sound is
//  announced again — lives in this file with tests (AGENTS.md hard rule 3).
//
//  Label identifiers: Apple documents "hundreds of sounds" for the built-in classifier but
//  publishes **no list of the label strings**, and the documented way to get them is
//  `SNClassifySoundRequest.knownClassifications` ("every prediction label in the request's
//  underlying sound classifier model"). So `candidateLabels` below is *not* a guess that ships:
//  `SoundWatcher` intersects it with `knownClassifications` at start-up, logs the matches and the
//  misses (`sound_watch_labels`), and only ever matches identifiers this phone actually has. The
//  `probe_f_sound_labels` record written by `SensorProbe` is the same measurement taken by hand.
//
//  Key invariants:
//    · A siren is cheaper to get wrong than to miss, so it has the lowest confidence gate; a
//      "vehicle" is the noisiest class on a street and has the highest.
//    · Nothing is announced on a single window. Two consecutive windows must agree, which at the
//      app's ~0.5 s window hop costs ≤ 1 s of latency and removes most single-frame flickers.
//    · The same kind is not repeated inside `repeatInterval`, so standing at a busy corner does
//      not turn into a stream of speech over the route instructions.
//    · These are *advisory* cues at `.obstacle` priority. They must never outrank a route line or
//      "Head height." — a sound the walker can already hear is worth less than a warning they
//      cannot (docs/design.md §5, AGENTS.md hard rule 8).
//  Tests: SoundAlertsTests.swift.
//

import Foundation

/// A danger sound worth speaking, and the line spoken for it.
/// Deliberately only three kinds: a blind walker acting on a sound needs to know *what* to do
/// (stop, check behind, wait), and a finer taxonomy ("ambulance" vs "police car") changes nothing.
public enum DangerSound: String, Sendable, CaseIterable {
    /// Emergency vehicle sirens, civil-defence sirens, alarms of that shape.
    case siren
    /// Car / truck / air / train horns — someone is warning *somebody*, possibly the walker.
    case horn
    /// Engines, tyres, a vehicle passing: something is moving nearby that the cane will not find.
    case vehicle

    /// What the walker hears. Short, because it plays over route guidance, and neutral, because
    /// the classifier is not certain enough to tell anyone to jump.
    /// ⚠ These strings are prefetched by the natural voice (`AppModel.commonLines`); changing one
    /// without changing that list costs a synthesis round-trip on the first play.
    public var spokenLine: String {
        switch self {
        case .siren: return "Siren nearby."
        case .horn: return "Horn nearby."
        case .vehicle: return "Vehicle sound nearby."
        }
    }

    /// Confidence (0…1) this kind needs before it is even a candidate.
    /// A siren is loud, distinctive and the most consequential to miss, so it is gated lowest; a
    /// generic vehicle sound is the most common false positive on a sidewalk, so it is gated
    /// highest and is off unless the walker asked for it.
    public var minimumConfidence: Double {
        switch self {
        case .siren: return 0.50
        case .horn: return 0.60
        case .vehicle: return 0.75
        }
    }

    /// Seconds before this kind may be spoken again. A siren approaches, so it is worth a
    /// reminder sooner; standing next to traffic must not produce a running commentary.
    public var repeatInterval: Double {
        switch self {
        case .siren: return 15
        case .horn: return 12
        case .vehicle: return 30
        }
    }
}

/// The label table and the gates shared by `SoundWatcher` and `SensorProbe`.
public enum SoundAlerts {

    /// Candidate label identifiers for each kind, in the snake_case style Apple's built-in
    /// classifier uses. This is a *superset* on purpose: `SoundWatcher` keeps only the entries
    /// that appear in `SNClassifySoundRequest.knownClassifications` on the running phone and logs
    /// the rest, so a label that does not exist in this iOS version costs nothing and is visible
    /// in the trip log rather than silently never firing.
    /// ⚠ Never match a label that is not in `knownClassifications`: that is how a feature ends up
    /// looking enabled while being dead.
    public static let labels: [DangerSound: [String]] = [
        .siren: ["siren", "emergency_vehicle", "police_siren", "ambulance_siren",
                 "fire_engine_siren", "civil_defense_siren", "emergency_vehicle_siren",
                 "car_alarm"],
        .horn: ["car_horn", "vehicle_horn", "vehicle_horn_car_horn_honking", "air_horn",
                "train_horn", "honk", "truck_horn", "bicycle_bell"],
        .vehicle: ["vehicle", "motor_vehicle_road", "car_passing_by", "traffic_noise",
                   "engine", "engine_accelerating", "engine_idling", "engine_revving",
                   "bus", "truck", "motorcycle", "tire_squeal", "skidding", "car"],
    ]

    /// Every candidate identifier, sorted — what `SensorProbe` checks against the phone and what
    /// `SoundWatcher` filters at start-up.
    public static var candidateLabels: [String] {
        labels.values.flatMap { $0 }.sorted()
    }

    /// The kind a label belongs to, or nil when the label is not a danger sound.
    /// - Parameter label: an identifier from `SNClassificationResult.classifications`.
    public static func kind(for label: String) -> DangerSound? {
        for (kind, names) in labels where names.contains(label) { return kind }
        return nil
    }
}

/// Turns a stream of classifier results into at most one spoken line per danger kind per
/// `repeatInterval`, requiring agreement across consecutive analysis windows.
///
/// A value type with no clock of its own (like `StraightWalkDetector` and `GroundHazardPolicy`):
/// the owner passes `now` in seconds and writes the mutated copy back.
public struct SoundAlertPolicy: Sendable, Equatable {

    /// Consecutive windows that must name the same kind above its gate before anything is spoken.
    /// Two windows at the app's 0.5 s hop = ≤ 1 s of latency for a large drop in false positives;
    /// three cost 1.5 s, which is a car-length at 10 m/s and was judged too slow.
    public var requiredWindows: Int = 2

    /// The kind the current run of windows agrees on, and how many windows long it is.
    private var pending: DangerSound?
    private var pendingCount = 0
    /// When each kind was last announced (seconds), so `repeatInterval` is per kind.
    private var lastSpoken: [DangerSound: Double] = [:]

    /// Creates a policy with the default 2-window agreement.
    public init() {}

    /// Feed one classification window's best danger-sound candidate.
    ///
    /// The caller passes the highest-confidence classification that maps to a `DangerSound`; a
    /// window with no danger sound passes `nil`, which breaks the run. Confidence below the
    /// kind's own gate also breaks it — a half-heard siren is not a siren.
    /// - Parameters:
    ///   - kind: the danger sound this window suggests, or nil.
    ///   - confidence: 0…1 from `SNClassification.confidence`.
    ///   - now: monotonic seconds.
    /// - Returns: the kind to announce, or nil. Returns non-nil at most once per
    ///   `kind.repeatInterval`.
    public mutating func update(kind: DangerSound?, confidence: Double, now: Double) -> DangerSound? {
        guard let kind, confidence >= kind.minimumConfidence else {
            pending = nil
            pendingCount = 0
            return nil
        }
        if pending == kind {
            pendingCount += 1
        } else {
            pending = kind
            pendingCount = 1
        }
        guard pendingCount >= requiredWindows else { return nil }
        if let last = lastSpoken[kind], now - last < kind.repeatInterval { return nil }
        lastSpoken[kind] = now
        // Keep the run going: a siren that stays audible must not re-announce until the interval
        // is up, and resetting here would let it re-arm on the very next window.
        return kind
    }

    /// Forget the run and every repeat timer (route start / stop, the switch going off), so a new
    /// walk never inherits the last walk's silence window.
    public mutating func reset() {
        pending = nil
        pendingCount = 0
        lastSpoken.removeAll()
    }
}
