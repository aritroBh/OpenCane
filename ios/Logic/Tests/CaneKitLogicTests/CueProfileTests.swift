//
//  CueProfileTests.swift
//  CaneKitLogicTests
//
//  Tests for the cue verbosity level × place rules (cue design v2, Step 36). The breaks these catch:
//  a default that silently changes today's behaviour before a mounted trip log tunes it (owner
//  decision 2026-09-12: default Detailed = today), a Quiet or Indoors profile that still names
//  furniture the cane finds anyway (research P1/P7), a Quiet profile that drops a safety sign, and
//  a persisted raw value that renames and resets every walker's choice.
//

import CaneKitLogic
import Testing

@Suite("Cue profile")
struct CueProfileTests {

    @Test("the default is Detailed outdoors, and its head distance is today's")
    func defaultIsTodaysBehaviour() {
        let rules = CueRules.default
        #expect(rules.level == .detailed)
        #expect(rules.place == .outdoors)
        #expect(rules.headEnterM == CueThresholds().head)
    }

    @Test("Quiet names nothing, on or off a route")
    func quietProfileHasNoObstacleNames() {
        let rules = CueRules(level: .quiet, place: .outdoors)
        for c in ObstacleClass.allCases {
            #expect(!rules.allowsName(c, navigating: true))
            #expect(!rules.allowsName(c, navigating: false))
        }
    }

    @Test("Standard names only doors, and only while a route guides")
    func standardAllowsOnlyDoorsOnARoute() {
        let rules = CueRules(level: .standard, place: .outdoors)
        #expect(rules.allowsName(.door, navigating: true))
        #expect(!rules.allowsName(.door, navigating: false))
        for c in ObstacleClass.allCases where c != .door {
            #expect(!rules.allowsName(c, navigating: true))
        }
    }

    @Test("Detailed names every speakable class except wall (the cane trails walls)")
    func detailedNeverSaysWall() {
        let rules = CueRules(level: .detailed, place: .outdoors)
        #expect(!rules.allowsName(.wall, navigating: true))
        for c: ObstacleClass in [.table, .seat, .window, .door] {
            #expect(rules.allowsName(c, navigating: false))
        }
        for c: ObstacleClass in [.none, .floor, .ceiling] {
            #expect(!rules.allowsName(c, navigating: true))   // never speakable at all
        }
    }

    @Test("Indoors names nothing at any level")
    func indoorsHasNoObstacleNames() {
        for level in CueLevel.allCases {
            let rules = CueRules(level: level, place: .indoors)
            for c in ObstacleClass.allCases { #expect(!rules.allowsName(c, navigating: true)) }
        }
    }

    @Test("Quiet or Indoors reads only safety signs; the safety set are real sign phrases")
    func quietAndIndoorsReadOnlySafetySigns() {
        #expect(CueRules.safetySignPhrases.isSubset(of: Set(SignPolicy.phrases)))
        #expect(CueRules.safetySignPhrases.contains("SIDEWALK CLOSED"))
        #expect(CueRules.safetySignPhrases.contains("DETOUR"))
        #expect(CueRules.safetySignPhrases.contains("CONSTRUCTION"))
        #expect(CueRules.safetySignPhrases.contains("PUSH BUTTON"))   // a crossing decision point
        for rules in [CueRules(level: .quiet, place: .outdoors), CueRules(level: .detailed, place: .indoors)] {
            #expect(rules.allowedSignPhrases == CueRules.safetySignPhrases)
            #expect(!(rules.allowedSignPhrases?.contains("EXIT") ?? true))
        }
    }

    @Test("Standard and Detailed outdoors read every sign phrase")
    func fullerLevelsReadEverySign() {
        #expect(CueRules(level: .standard, place: .outdoors).allowedSignPhrases == nil)
        #expect(CueRules(level: .detailed, place: .outdoors).allowedSignPhrases == nil)
    }

    @Test("indoors the head distance is shorter")
    func indoorHeadThresholds() {
        #expect(CueRules(level: .detailed, place: .indoors).headEnterM == 1.2)
        #expect(CueRules(level: .quiet, place: .outdoors).headEnterM == 1.5)
    }

    @Test("each change has one fixed line, and all of them are listed for the prefetch")
    func profileChangeLines() {
        #expect(CueLevel.quiet.spokenLine == "Quiet cues.")
        #expect(CueLevel.standard.spokenLine == "Standard cues.")
        #expect(CueLevel.detailed.spokenLine == "Detailed cues.")
        #expect(CuePlace.indoors.spokenLine == "Indoor mode.")
        #expect(CuePlace.outdoors.spokenLine == "Outdoor mode.")
        let all = CueLevel.allCases.map(\.spokenLine) + CuePlace.allCases.map(\.spokenLine)
        #expect(Set(CueRules.allSpokenLines) == Set(all))
    }

    /// Step 36 review: "turn on obstacle names" by voice said "Obstacle names on." while Quiet or
    /// Indoors let no name through, so the walker was told a feature worked that stayed silent.
    @Test("turning names on explains a level or place that limits them; Detailed outdoors needs no note")
    func namesLimitLine() {
        #expect(CueRules(level: .detailed, place: .outdoors).namesLimitLine == nil)
        #expect(CueRules(level: .quiet, place: .outdoors).namesLimitLine == "Quiet cues name nothing.")
        #expect(CueRules(level: .standard, place: .outdoors).namesLimitLine == "Standard cues name only doors, on a route.")
        for level in CueLevel.allCases {
            #expect(CueRules(level: level, place: .indoors).namesLimitLine == "Indoor mode names nothing.")
        }
    }

    @Test("persisted raw values never change (renaming resets every walker's setting)")
    func rawValuesAreStable() {
        #expect(CueLevel.allCases.map(\.rawValue) == ["quiet", "standard", "detailed"])
        #expect(CuePlace.allCases.map(\.rawValue) == ["outdoors", "indoors"])
        #expect(CueLevel(rawValue: "bogus") == nil)
    }
}

@Suite("Sign phrase filter")
struct SignPhraseFilterTests {

    @Test("a phrase outside the allowed set is not spoken, and does not block a later allowed one")
    func filteredPhraseIsSkipped() {
        var policy = SignPolicy()
        policy.allowedPhrases = CueRules.safetySignPhrases
        #expect(policy.line(for: [(text: "EXIT", confidence: 0.9)], now: 0) == nil)
        #expect(policy.line(for: [(text: "SIDEWALK CLOSED", confidence: 0.9)], now: 1) == "Sign: sidewalk closed.")
    }

    /// Step 36 review (Muse, agents): a disallowed phrase must not suppress an allowed phrase in
    /// the same frame, even one it contains — the filter runs before the "inside an already
    /// matched phrase" de-dup counts it as matched.
    @Test("a disallowed phrase in the same frame never swallows an allowed one")
    func sameFrameAllowedPhraseSurvives() {
        var policy = SignPolicy()
        policy.allowedPhrases = CueRules.safetySignPhrases
        #expect(policy.line(for: [(text: "ENTRANCE", confidence: 0.9), (text: "DANGER", confidence: 0.9)], now: 0)
                == "Sign: danger.")
        // A hypothetical disallowed long phrase containing an allowed short one.
        var narrow = SignPolicy()
        narrow.allowedPhrases = ["CLOSED"]
        #expect(narrow.line(for: [(text: "SIDEWALK CLOSED", confidence: 0.9)], now: 0) == "Sign: closed.")
    }

    @Test("nil allows every phrase (today's behaviour)")
    func nilAllowsAll() {
        var policy = SignPolicy()
        #expect(policy.allowedPhrases == nil)
        #expect(policy.line(for: [(text: "EXIT", confidence: 0.9)], now: 0) == "Sign: exit.")
    }

    @Test("a filtered phrase is not stamped, so allowing it later reads it at once")
    func filteredPhraseIsNotStamped() {
        var policy = SignPolicy()
        policy.allowedPhrases = CueRules.safetySignPhrases
        _ = policy.line(for: [(text: "EXIT", confidence: 0.9)], now: 0)
        policy.allowedPhrases = nil
        #expect(policy.line(for: [(text: "EXIT", confidence: 0.9)], now: 1) == "Sign: exit.")
    }
}
