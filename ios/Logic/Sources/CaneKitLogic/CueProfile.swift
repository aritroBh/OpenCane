//
//  CueProfile.swift
//  CaneKitLogic
//
//  How much OpenCane says and taps: a verbosity level (Quiet / Standard / Detailed) × a place
//  (Outdoors / Indoors), reduced to plain rules the app asks before it speaks a name or a sign or
//  sets the head distance. Cue design v2, Step 36 (docs/cue_design_v2.md §3.3 and §3.5).
//
//  Why: the first field log was 7.6 unsolicited lines a minute and 34 head cues a minute, and blind
//  travellers are consistent that an aid must not repeat what the cane already finds (furniture,
//  walls) and that silence has to mean "nothing to act on" (research P1, P3, P7). A level lets the
//  walker choose; a place makes indoor clutter quieter.
//
//  ⚠ Default Detailed + Outdoors = today's behaviour (owner decision 2026-09-12, AGENTS.md "How we
//  engineer" 6): the calmer levels are opt-in until a trip log from the MOUNTED cane tunes them
//  (`ios/scripts/cue_audit.py` says whether a log was mounted). The one Detailed change is that it
//  never names walls — a spoken-line reduction, the cane trails walls.
//
//  Torso haptics by level live next door in `TorsoHapticPolicy.swift` (Step 41), which takes a
//  `CueRules` value and the decider's output; this file only holds the level × place decisions.
//  Pure: Foundation-only. Owner: `AppModel.cueLevel` / `cuePlace` (persisted with
//  `Settings.string`, changed from Settings → Cues); `AppModel.cueRules` rebuilds the value, and
//  `applyCueRules` pushes `headEnterM` into `CueDecider.thresholds.head` and `allowedSignPhrases`
//  into `HazardScanner.signAllowedPhrases`; `allowsName` is read per report in `AppModel.handle`,
//  which also hands the value to `TorsoHapticPolicy.update`.
//  Tests: `CueProfileTests.swift` (12, suite "Cue profile") + `SignPhraseFilterTests` (4, same file).
//

import Foundation

/// How much the app volunteers. Raw values are persisted (`UserDefaults` key `cueLevel`) — never
/// rename them (`rawValuesAreStable`). An unknown stored value falls back to `.detailed` in the app.
public enum CueLevel: String, CaseIterable, Sendable, Codable {
    /// No obstacle names; safety signs only; no torso taps at all (`TorsoHapticPolicy`, Step 41).
    /// Head-height and ground-hazard warnings are identical at every level — the safety floor.
    case quiet
    /// Door names while a route guides; every sign; centre torso = two onset taps (< 1.5 m and
    /// closing, a strong triple < 0.6 m), no loop, no side taps.
    case standard
    /// Today's behaviour: every speakable name except wall, every sign, the centre Geiger loop and
    /// side taps (minus a side tap while a wall or hedge is being trailed — shoreline suppression).
    case detailed

    /// Spoken once when the walker changes the level (`.nav`, prefetched via
    /// `CueRules.allSpokenLines`). Pinned by `profileChangeLines`.
    public var spokenLine: String {
        switch self {
        case .quiet: return "Quiet cues."
        case .standard: return "Standard cues."
        case .detailed: return "Detailed cues."
        }
    }

    /// The picker's visible title (and VoiceOver value). ⚠ UI test contract (AGENTS.md rule 9):
    /// `testCuePickersChangeAndRestore` taps these segment titles.
    public var title: String {
        switch self {
        case .quiet: return "Quiet"
        case .standard: return "Standard"
        case .detailed: return "Detailed"
        }
    }
}

/// Where the walker is. Raw values are persisted (`UserDefaults` key `cuePlace`) — never rename
/// them (`rawValuesAreStable`). An unknown stored value falls back to `.outdoors` in the app.
public enum CuePlace: String, CaseIterable, Sendable, Codable {
    /// Today's behaviour: 1.5 m head distance, names and signs follow the level.
    case outdoors
    /// Rooms: no obstacle names, safety signs only, 1.2 m head distance [H].
    case indoors

    /// Spoken once when the walker changes the place (`.nav`, prefetched). Research: a mode switch
    /// with no indication was a named complaint about the Sunu Band (P10). Pinned by `profileChangeLines`.
    public var spokenLine: String {
        switch self {
        case .outdoors: return "Outdoor mode."
        case .indoors: return "Indoor mode."
        }
    }

    /// The picker's visible title (and VoiceOver value). ⚠ UI test contract, as `CueLevel.title`.
    public var title: String {
        switch self {
        case .outdoors: return "Outdoors"
        case .indoors: return "Indoors"
        }
    }
}

/// The decisions a (level, place) pair implies. Value type; the app rebuilds it on every change.
public struct CueRules: Sendable, Equatable {
    /// The verbosity level these rules came from.
    public let level: CueLevel
    /// The place these rules came from.
    public let place: CuePlace

    /// Detailed + Outdoors: today's behaviour (the app's defaults). Pinned by `defaultIsTodaysBehaviour`.
    public static let `default` = CueRules(level: .detailed, place: .outdoors)

    /// Sign phrases a Quiet or Indoors walker still hears: closures, danger and the crossing push
    /// button (a decision point) — never EXIT / ENTRANCE / PUSH / PULL chatter. Every entry must be
    /// in `SignPolicy.phrases` (`quietAndIndoorsReadOnlySafetySigns`). ⚠ A phrase added to
    /// `SignPolicy.phrases` is silent under Quiet / Indoors until it is also added here.
    public static let safetySignPhrases: Set<String> = [
        "SIDEWALK CLOSED", "ROAD CLOSED", "USE OTHER SIDEWALK", "NO PEDESTRIANS", "DO NOT ENTER",
        "WET FLOOR", "KEEP OUT", "WORK ZONE", "CONSTRUCTION", "DETOUR", "DANGER", "CAUTION",
        "PUSH BUTTON", "CLOSED",
    ]

    /// Every line a level or place change can speak, for `AppModel.commonLines` (`profileChangeLines`).
    /// ⚠ Prefetch matches by bytes: edit a `spokenLine` and this list follows automatically, but
    /// never hand-copy these strings elsewhere.
    public static let allSpokenLines: [String] =
        CueLevel.allCases.map(\.spokenLine) + CuePlace.allCases.map(\.spokenLine)

    /// Whether a head cue needs the overhang signature (Step 52, `HeadGate`): the torso cell of
    /// the same lane ≥ 0.5 m farther, non-finite or uncovered. ON by default — owner decision
    /// 2026-09-13 ("keep it on for now, we'll keep testing"); it supersedes the Steps 34–37 note
    /// "Walls still get 'Head height.' (owner: 'Leave as is')". `AppModel.applyCueRules` pushes it
    /// into `CueThresholds.requireOverhangSignature`; `AppModel.cueRules` reads the valve
    /// `Settings.bool("overhangSignature", default: true)` (no UI; hard rule 9 labels untouched).
    /// Pinned by `defaultRulesRequireTheOverhangSignature`.
    public let requireOverhangSignature: Bool

    /// - Parameters:
    ///   - level: verbosity level.
    ///   - place: outdoors or indoors.
    ///   - requireOverhangSignature: the Step 52 head gate (default ON, owner decision 2026-09-13).
    public init(level: CueLevel, place: CuePlace, requireOverhangSignature: Bool = true) {
        self.level = level
        self.place = place
        self.requireOverhangSignature = requireOverhangSignature
    }

    /// Head-band distance (metres) below which a head cue fires: today's 1.5 m outdoors, 1.2 m
    /// indoors, where rooms are small and shelves and door frames crowd the band. ⚠ 1.2 m is a
    /// research hypothesis [H] (docs/cue_design_v2.md §3.5), opt-in by choosing Indoors.
    /// Pinned by `indoorHeadThresholds`, `defaultIsTodaysBehaviour`.
    public var headEnterM: Float {
        place == .indoors ? 1.2 : CueThresholds().head
    }

    /// May an obstacle name for `cls` be spoken?
    /// - Indoors: never (the cane finds furniture; rooms are where names piled up).
    /// - Quiet: never. Standard: doors only, and only while a route guides (a door is a decision
    ///   point on a route, clutter off it). Detailed: every speakable class except wall.
    /// - Parameters:
    ///   - cls: the mesh class straight ahead.
    ///   - navigating: `NavigationEngine.isNavigating`.
    /// Pinned by `quietProfileHasNoObstacleNames`, `standardAllowsOnlyDoorsOnARoute`,
    /// `detailedNeverSaysWall`, `indoorsHasNoObstacleNames`.
    public func allowsName(_ cls: ObstacleClass, navigating: Bool) -> Bool {
        guard cls.spokenName != nil, place == .outdoors else { return false }
        switch level {
        case .quiet: return false
        case .standard: return cls == .door && navigating
        case .detailed: return cls != .wall
        }
    }

    /// A sentence to add when the walker turns obstacle names on but this level or place limits
    /// them, so "Obstacle names on." is never a promise that stays silent (Step 36 review); nil for
    /// Detailed outdoors. Spoken by `AppModel.setOption`. Pinned by `namesLimitLine`.
    public var namesLimitLine: String? {
        if place == .indoors { return "Indoor mode names nothing." }
        switch level {
        case .quiet: return "Quiet cues name nothing."
        case .standard: return "Standard cues name only doors, on a route."
        case .detailed: return nil
        }
    }

    /// Sign phrases that may be spoken: `safetySignPhrases` for Quiet or Indoors, nil (= every
    /// phrase) otherwise. Fed to `SignPolicy.allowedPhrases` (via `HazardScanner.signAllowedPhrases`).
    /// Pinned by `quietAndIndoorsReadOnlySafetySigns`, `fullerLevelsReadEverySign`.
    public var allowedSignPhrases: Set<String>? {
        (level == .quiet || place == .indoors) ? Self.safetySignPhrases : nil
    }
}
