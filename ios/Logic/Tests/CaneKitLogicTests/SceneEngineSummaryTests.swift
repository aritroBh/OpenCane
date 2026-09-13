//
//  SceneEngineSummaryTests.swift
//  CaneKitLogicTests
//
//  Purpose: pins SceneEngineSummary.swift — the words on the Details tab's "Scene engine" card.
//
//  Why these are the tests: the owner asked to *see* when Muse answers and when the on-device model
//  does, so the failure mode is a card that is vague where it should be specific — "answered" with
//  no model name, a fallback with no reason, a hazard watch that says "off" without saying what on
//  would do. Every test below fixes one exact string for one state. The two numbers in the hazard
//  watch line (8 s, 2.5 s) are passed in, and one test proves the wording follows them rather than
//  a literal.
//
//  Source pinned: `ios/Logic/Sources/CaneKitLogic/SceneEngineSummary.swift` (`SceneEngineFacts`,
//  `SceneEngineSummary.chain` / `lastAnswer` / `when` / `gate` / `hazardWatch` / `cues` /
//  `spokenSummary`, `latency`, `age`, `DescribeTrigger.spoken`). Caller: `SceneEngineCard`
//  (ios/CaneKit/UI/ContentView.swift).
//

import Testing
@testable import CaneKitLogic

/// A phone with a Muse key, nothing asked yet, hazard watch off, today's cue defaults. Every test
/// mutates one or two fields.
private func idle(cloud: String? = "Muse") -> SceneEngineFacts {
    SceneEngineFacts(cloudName: cloud, onDeviceName: "On-device", lastSource: nil, lastCloudMs: nil,
                     lastLatencyMs: nil, lastFallbackReason: nil, lastGate: nil, lastError: nil,
                     secondsSinceLast: nil, lastTrigger: nil, hazardWatchOn: false,
                     hazardWatchIntervalS: 8, hazardCloudDeadlineS: cloud == nil ? nil : 2.5,
                     lastWatchSource: nil, lastWatchMs: nil, lastWatchReason: nil,
                     secondsSinceWatch: nil, cueLevelTitle: "Detailed", cuePlaceTitle: "Outdoors",
                     namesOn: false)
}

@Test func chainPillNamesTheOrder() {
    #expect(SceneEngineSummary.chain(idle()).text == "Muse → On-device")
    #expect(SceneEngineSummary.chain(idle(cloud: nil)).text == "On-device only")
    #expect(SceneEngineSummary.chain(idle()).spoken.contains("asks Muse first"))
}

@Test func neverAskedYet() {
    let line = SceneEngineSummary.lastAnswer(idle())
    #expect(line.text == "Not asked yet.")
    #expect(SceneEngineSummary.when(idle()) == nil)
    #expect(SceneEngineSummary.gate(idle()) == nil)
}

@Test func cloudAnswerNamesTheModelAndLatency() {
    var f = idle()
    f.lastSource = "Muse"; f.lastCloudMs = 1_940; f.lastLatencyMs = 1_940; f.lastGate = "spoken"
    let line = SceneEngineSummary.lastAnswer(f)
    #expect(line.text == "Muse answered in 1.9 s")
    #expect(line.spoken == "Muse answered the last Where am I in 1.9 seconds.")
}

@Test func onDeviceOnlyAnswerHasNoCloudStory() {
    var f = idle(cloud: nil)
    f.lastSource = "On-device"; f.lastLatencyMs = 420; f.lastGate = "on-device"
    #expect(SceneEngineSummary.lastAnswer(f).text == "On-device answered in 420 ms")
    #expect(SceneEngineSummary.gate(f) == nil)
}

@Test func fallbackSaysWhy() {
    var f = idle()
    f.lastSource = "On-device"; f.lastFallbackReason = "The request timed out."; f.lastGate = "on-device"
    #expect(SceneEngineSummary.lastAnswer(f).text == "On-device answered — Muse: The request timed out.")
    f.lastCloudMs = 18_040
    #expect(SceneEngineSummary.lastAnswer(f).text
            == "On-device answered — Muse: The request timed out. (after 18 s)")
    #expect(SceneEngineSummary.lastAnswer(f).spoken.contains("because Muse failed"))
    // The gate line belongs to a cloud sentence; an on-device answer has none.
    #expect(SceneEngineSummary.gate(f) == nil)
}

@Test func gateRefusalIsExplained() {
    var f = idle()
    f.lastSource = "Muse"; f.lastCloudMs = 2_100; f.lastGate = "refused: invented distance"
    #expect(SceneEngineSummary.gate(f)?.text
            == "Muse's sentence was refused: invented distance. On-device spoke instead.")
    f.lastGate = "edited: dropped count"
    #expect(SceneEngineSummary.gate(f)?.text == "Muse's sentence was edited: dropped count.")
    f.lastGate = "spoken"
    #expect(SceneEngineSummary.gate(f)?.text == "Muse's sentence passed the gate.")
}

@Test func gateLineOnlyWhenTheCloudAnswered() {
    var f = idle()
    f.lastSource = "On-device"; f.lastGate = "on-device"
    #expect(SceneEngineSummary.gate(f) == nil)
    f.lastSource = nil; f.lastGate = "error"; f.lastError = "Scene description failed."
    #expect(SceneEngineSummary.gate(f) == nil)
}

@Test func aFailureIsSaidAsAFailure() {
    var f = idle()
    f.lastGate = "no frame"; f.lastError = "No camera frame"
    #expect(SceneEngineSummary.lastAnswer(f).text == "No camera frame.")
    f.lastGate = "error"; f.lastError = "HTTP 401: bad key"
    #expect(SceneEngineSummary.lastAnswer(f).text == "Failed — HTTP 401: bad key")
}

@Test func ageIsRelative() {
    #expect(SceneEngineSummary.age(3) == "just now")
    #expect(SceneEngineSummary.age(9.9) == "just now")
    #expect(SceneEngineSummary.age(45) == "45 s ago")
    #expect(SceneEngineSummary.age(120) == "2 min ago")
    #expect(SceneEngineSummary.age(3_600) == "1 h ago")
    #expect(SceneEngineSummary.age(120, spoken: true) == "2 minutes ago")
    #expect(SceneEngineSummary.age(60, spoken: true) == "1 minute ago")
    #expect(SceneEngineSummary.age(7_200, spoken: true) == "2 hours ago")
}

@Test func latencyReadsInSecondsAboveOne() {
    #expect(SceneEngineSummary.latency(850) == "850 ms")
    #expect(SceneEngineSummary.latency(1_000) == "1 s")
    #expect(SceneEngineSummary.latency(1_000, spoken: true) == "1 second")
    #expect(SceneEngineSummary.latency(10_748) == "10.7 s")
    #expect(SceneEngineSummary.seconds(2.5) == "2.5 s")
    #expect(SceneEngineSummary.seconds(8) == "8 s")
}

@Test func whenLineJoinsAgeAndTrigger() {
    var f = idle()
    f.lastSource = "Muse"; f.lastGate = "spoken"; f.secondsSinceLast = 130; f.lastTrigger = .watch
    #expect(SceneEngineSummary.when(f)?.text == "2 min ago · from the watch")
    #expect(SceneEngineSummary.when(f)?.spoken == "2 minutes ago, from the watch.")
    f.secondsSinceLast = 2; f.lastTrigger = .button
    #expect(SceneEngineSummary.when(f)?.text == "just now · from the Guide button")
    #expect(SceneEngineSummary.when(f)?.spoken == "Just now, from the Guide button.")
}

@Test func triggerWordsAreSpoken() {
    // Raw values are a trip-log contract; spoken words must all exist and differ.
    let words = DescribeTrigger.allCases.map(\.spoken)
    #expect(Set(words).count == DescribeTrigger.allCases.count)
    #expect(DescribeTrigger.actionButton.rawValue == "actionButton")
    #expect(DescribeTrigger.cameraControl.spoken == "Camera Control")
}

@Test func hazardWatchOffSaysWhenItWouldRun() {
    #expect(SceneEngineSummary.hazardWatch(idle()).text
            == "Hazard watch off — when on, asks Muse every 8 s while a route guides, on-device after 2.5 s")
    #expect(SceneEngineSummary.hazardWatch(idle(cloud: nil)).text
            == "Hazard watch off — when on, asks the on-device model every 8 s while a route guides")
    // The numbers are the app's constants, not literals: change them and the words follow.
    var f = idle()
    f.hazardWatchIntervalS = 12; f.hazardCloudDeadlineS = 3
    #expect(SceneEngineSummary.hazardWatch(f).text
            == "Hazard watch off — when on, asks Muse every 12 s while a route guides, on-device after 3 s")
    #expect(SceneEngineSummary.hazardWatch(idle()).spoken
            == "Hazard watch is off. When on, it asks Muse every 8 seconds while a route guides, and the on-device model answers if Muse takes more than 2.5 seconds.")
}

@Test func hazardWatchOnNamesTheLastAnswer() {
    var f = idle()
    f.hazardWatchOn = true
    #expect(SceneEngineSummary.hazardWatch(f).text
            == "Hazard watch on — asks Muse every 8 s while a route guides, on-device after 2.5 s. Nothing asked yet.")
    f.lastWatchSource = "Muse"; f.lastWatchMs = 1_200; f.secondsSinceWatch = 30
    #expect(SceneEngineSummary.hazardWatch(f).text == "Hazard watch: Muse answered in 1.2 s · 30 s ago")
    f.lastWatchSource = "On-device"; f.lastWatchReason = "The request timed out."; f.lastWatchMs = 2_500
    #expect(SceneEngineSummary.hazardWatch(f).text
            == "Hazard watch: On-device answered — Muse: The request timed out. · 30 s ago")
}

@Test func hazardWatchFailureIsSaidAsAFailure() {
    var f = idle()
    f.hazardWatchOn = true
    f.lastWatchSource = nil; f.lastWatchError = "Hazard watch: The request timed out."; f.secondsSinceWatch = 30
    #expect(SceneEngineSummary.hazardWatch(f).text == "Hazard watch: last check failed — The request timed out. · 30 s ago")
    #expect(SceneEngineSummary.hazardWatch(f).spoken == "The last hazard watch check failed 30 seconds ago: The request timed out.")
    // Off, or with no failure recorded, the old lines stand.
    f.lastWatchError = nil
    #expect(SceneEngineSummary.hazardWatch(f).text.hasSuffix("Nothing asked yet."))
}

@Test func cuesLineNamesLevelPlaceAndNames() {
    #expect(SceneEngineSummary.cues(idle()).text == "Detailed · Outdoors · names off")
    #expect(SceneEngineSummary.cues(idle()).spoken == "Cues: Detailed, Outdoors, obstacle names off.")
    var f = idle()
    f.cueLevelTitle = "Quiet"; f.cuePlaceTitle = "Indoors"; f.namesOn = true
    #expect(SceneEngineSummary.cues(f).text == "Quiet · Indoors · names on")
}

@Test func summaryReadsEveryRowInOrder() {
    var f = idle()
    f.lastSource = "Muse"; f.lastCloudMs = 1_940; f.lastGate = "spoken"; f.secondsSinceLast = 5
    f.lastTrigger = .button
    let s = SceneEngineSummary.spokenSummary(f)
    let order = ["asks Muse first", "Muse answered the last Where am I", "Just now",
                 "passed the gate", "Hazard watch is off", "Cues: Detailed"]
    var cursor = s.startIndex
    for needle in order {
        guard let r = s.range(of: needle, range: cursor..<s.endIndex) else {
            Issue.record("missing or out of order: \(needle) in \(s)")
            return
        }
        cursor = r.upperBound
    }
}
