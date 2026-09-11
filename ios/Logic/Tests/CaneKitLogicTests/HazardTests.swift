//
//  HazardTests.swift
//  CaneKitLogicTests
//
//  Pins Hazards.swift: the LiDAR ground-profile detector (drop-off, pothole, step up, low
//  obstacle; slopes and single noisy frames must NOT trigger), sign phrases, the vision-model
//  hazard reply parser, and the GeoJSON hazard map.
//

import Foundation
import Testing
@testable import CaneKitLogic

/// A synthetic ground profile: samples every 10 cm ahead from 0.8 to 3.5 m, five lateral columns
/// inside the corridor, phone 0.9 m above the ground. `profile(forward)` returns the ground
/// height relative to flat ground (negative = below).
private func ground(_ profile: (Float) -> Float = { _ in 0 }) -> [GroundSample] {
    var out: [GroundSample] = []
    var f: Float = 0.8
    while f <= 3.5 {
        for l: Float in [-0.3, -0.15, 0, 0.15, 0.3] {
            out.append(GroundSample(forward: f, lateral: l, height: -0.9 + profile(f)))
        }
        f += 0.1
    }
    return out
}

// MARK: GroundHazardDetector (single frame)

/// Flat sidewalk → nothing to say.
@Test func flatGroundIsQuiet() {
    #expect(GroundHazardDetector().classify(ground()) == nil)
}

/// A 6 % downhill ramp departs slowly and never jumps between bins → not a drop-off.
@Test func aSmoothRampIsNotAHazard() {
    let ramp = ground { f in f > 1.5 ? -(f - 1.5) * 0.06 : 0 }
    #expect(GroundHazardDetector().classify(ramp) == nil)
}

/// Curb down 15 cm at 2.1 m that stays down → drop-off at ~2.1 m.
@Test func aCurbDownIsADropOff() {
    let h = GroundHazardDetector().classify(ground { $0 >= 2.1 ? -0.15 : 0 })
    #expect(h?.kind == .dropOff)
    #expect(h.map { abs($0.distance - 2.1) < 0.35 } == true)
    #expect(h.map { $0.delta < -0.1 } == true)
}

/// 20 cm hole from 2.1 to 2.7 m, ground returns after → pothole.
@Test func aHoleThatComesBackUpIsAPothole() {
    let h = GroundHazardDetector().classify(ground { ($0 >= 2.1 && $0 < 2.7) ? -0.2 : 0 })
    #expect(h?.kind == .pothole)
}

/// 15 cm rise at 2.4 m that stays up → step up.
@Test func aCurbUpIsAStepUp() {
    let h = GroundHazardDetector().classify(ground { $0 >= 2.4 ? 0.15 : 0 })
    #expect(h?.kind == .stepUp)
}

/// 30 cm block from 2.1 to 2.4 m, ground behind it → low obstacle.
@Test func aShortBlockIsALowObstacle() {
    let h = GroundHazardDetector().classify(ground { ($0 >= 2.1 && $0 < 2.4) ? 0.3 : 0 })
    #expect(h?.kind == .lowObstacle)
}

/// Something taller than 50 cm is the lane grid's job, not a ground hazard.
@Test func tallThingsAreLeftToTheLaneGrid() {
    #expect(GroundHazardDetector().classify(ground { $0 >= 2.4 ? 0.9 : 0 }) == nil)
}

/// A drop outside the walking corridor (1 m to the side) is ignored.
@Test func hazardsOutsideTheCorridorAreIgnored() {
    let side = ground().map { GroundSample(forward: $0.forward, lateral: $0.lateral + 1.0,
                                           height: $0.forward >= 2.1 ? -1.1 : -0.9) }
    let centre = ground()
    #expect(GroundHazardDetector().classify(centre + side) == nil)
}

/// Too few near-field returns (e.g. phone pointed at the sky) → no ground reference → nil.
@Test func noNearFieldMeansNoVerdict() {
    let far = ground { $0 >= 2.1 ? -0.3 : 0 }.filter { $0.forward > 1.6 }
    #expect(GroundHazardDetector().classify(far) == nil)
}

// MARK: GroundHazardDetector (confirmation over frames)

/// One frame is not enough; three agreeing trusted frames out of five confirm.
@Test func aHazardNeedsThreeAgreeingFrames() {
    var d = GroundHazardDetector()
    let curb = ground { $0 >= 2.1 ? -0.15 : 0 }
    let r1 = d.update(curb, trusted: true)
    #expect(r1 == nil)
    let r2 = d.update(curb, trusted: true)
    #expect(r2 == nil)
    let r3 = d.update(curb, trusted: true)
    #expect(r3?.kind == .dropOff)
}

/// Frames taken mid-sweep (untrusted) never count toward confirmation.
@Test func sweepFramesDoNotConfirm() {
    var d = GroundHazardDetector()
    let curb = ground { $0 >= 2.1 ? -0.15 : 0 }
    for _ in 0..<5 {
        let r = d.update(curb, trusted: false)
        #expect(r == nil)
    }
}

/// Noise that flips between frames (hole, flat, step, flat, hole) never confirms.
@Test func flickeringNoiseNeverConfirms() {
    var d = GroundHazardDetector()
    let frames = [ground { $0 >= 2.1 ? -0.15 : 0 }, ground(), ground { $0 >= 2.4 ? 0.15 : 0 }, ground(),
                  ground { $0 >= 2.1 ? -0.15 : 0 }]
    for f in frames {
        let r = d.update(f, trusted: true)
        #expect(r == nil)
    }
}

// MARK: GroundHazardPolicy

/// Same hazard is announced once, again when ≥ 1 m closer or after 30 s; a new kind at once;
/// standing still at a curb does not repeat it every few seconds.
@Test func groundHazardsAreAnnouncedSparingly() {
    var p = GroundHazardPolicy()
    let far = GroundHazard(kind: .dropOff, distance: 3.0, delta: -0.15)
    let h1 = p.shouldAnnounce(far, now: 0)
    #expect(h1)
    let h2 = p.shouldAnnounce(GroundHazard(kind: .dropOff, distance: 2.6, delta: -0.15), now: 1)
    #expect(!h2)
    let h3 = p.shouldAnnounce(GroundHazard(kind: .dropOff, distance: 1.9, delta: -0.15), now: 2)
    #expect(h3)
    let h4 = p.shouldAnnounce(GroundHazard(kind: .stepUp, distance: 1.8, delta: 0.15), now: 2.5)
    #expect(h4)
    let h5 = p.shouldAnnounce(GroundHazard(kind: .stepUp, distance: 1.8, delta: 0.15), now: 9)
    #expect(!h5)   // standing at it: no nagging
    let h5b = p.shouldAnnounce(GroundHazard(kind: .stepUp, distance: 1.8, delta: 0.15), now: 33)
    #expect(h5b)   // long fallback repeat
}

/// The same kind somewhere else along the walk (anchor > 1 m away) is a new hazard.
@Test func aSecondCurbOfTheSameKindIsAnnounced() {
    var p = GroundHazardPolicy()
    let a = p.shouldAnnounce(GroundHazard(kind: .dropOff, distance: 2.5, delta: -0.15, anchor: 10), now: 0)
    #expect(a)
    let b = p.shouldAnnounce(GroundHazard(kind: .dropOff, distance: 2.5, delta: -0.15, anchor: 16), now: 5)
    #expect(b)
}

/// Samples every 5 cm (denser than `ground`) so a curb face can land in the middle of a bin.
private func denseGround(_ profile: (Float) -> Float) -> [GroundSample] {
    var out: [GroundSample] = []
    for k in 0...54 {
        let f = 0.8 + Float(k) * 0.05
        for l: Float in [-0.3, -0.15, 0, 0.15, 0.3] {
            out.append(GroundSample(forward: f, lateral: l, height: -0.9 + profile(f)))
        }
    }
    return out
}

/// A 12 cm curb up whose face falls mid-bin (1.95 m) splits its rise across two bins; it must
/// still be found, and reported at the nearer edge, not beyond the face.
@Test func aMidBinCurbFaceIsStillFound() {
    let h = GroundHazardDetector().classify(denseGround { $0 >= 1.94 ? 0.12 : 0 })
    #expect(h?.kind == .stepUp)
    #expect(h.map { $0.distance <= 1.95 } == true)
    let d = GroundHazardDetector().classify(denseGround { $0 >= 1.94 ? -0.13 : 0 })
    #expect(d?.kind == .dropOff)
    #expect(d.map { $0.distance <= 1.95 } == true)
}

/// A 10 % ramp (steeper than ADA allows) still never jumps over two bins.
@Test func aTenPercentRampIsNotAHazard() {
    #expect(GroundHazardDetector().classify(denseGround { $0 > 1.5 ? (($0 - 1.5) * 0.10) : 0 }) == nil)
    #expect(GroundHazardDetector().classify(denseGround { $0 > 1.5 ? -(($0 - 1.5) * 0.10) : 0 }) == nil)
}

/// A rise in the very last bin is not classified yet (step up or low obstacle is a guess there).
@Test func aRiseInTheLastBinWaitsForACloserLook() {
    #expect(GroundHazardDetector().classify(ground { $0 >= 3.25 ? 0.15 : 0 }) == nil)
}

/// The spoken line uses the shared distance phrasing.
@Test func groundHazardLine() {
    #expect(GroundHazard(kind: .dropOff, distance: 2.0, delta: -0.2).spokenLine == "Drop-off ahead, two meters.")
    #expect(GroundHazard(kind: .pothole, distance: 1.5, delta: -0.2).spokenLine == "Hole ahead, one and a half meters.")
}

// MARK: SignPolicy

/// The longest matching phrase wins and is spoken once per minute.
@Test func signsAreReadOnceAndSpecifically() {
    var p = SignPolicy()
    let seen = [(text: "Sidewalk-CLOSED ahead!", confidence: Float(0.9))]
    let h6 = p.line(for: seen, now: 0)
    #expect(h6 == "Sign: sidewalk closed.")
    let h7 = p.line(for: seen, now: 30)
    #expect(h7 == nil)
    let h8 = p.line(for: seen, now: 61)
    #expect(h8 == "Sign: sidewalk closed.")
}

/// Storefront text and low-confidence reads are ignored; words must match whole ("STOPPED" ≠ "STOP").
@Test func irrelevantOrUnsureTextIsIgnored() {
    var p = SignPolicy()
    let h9 = p.line(for: [(text: "Espresso Royale", confidence: 0.95)], now: 0)
    #expect(h9 == nil)
    let h10 = p.line(for: [(text: "DETOUR", confidence: 0.3)], now: 0)
    #expect(h10 == nil)
    let h11 = p.line(for: [(text: "Unstoppable deals", confidence: 0.9)], now: 0)
    #expect(h11 == nil)
    let h12 = p.line(for: [(text: "detour", confidence: 0.8)], now: 1)
    #expect(h12 == "Sign: detour.")
}

// MARK: HazardWatchPolicy

/// Checks only while walking and at most every 8 s.
@Test func hazardWatchAsksOnlyWhileWalkingAndRarely() {
    var p = HazardWatchPolicy()
    let h13 = p.shouldAsk(now: 0, speed: 0.2)
    #expect(!h13)
    let h14 = p.shouldAsk(now: 1, speed: 1.2)
    #expect(h14)
    let h15 = p.shouldAsk(now: 5, speed: 1.2)
    #expect(!h15)
    let h16 = p.shouldAsk(now: 9.5, speed: 1.2)
    #expect(h16)
}

/// NONE is silent; a hazard becomes one short caution; a reworded repeat is dropped.
@Test func hazardWatchRepliesBecomeShortCautions() {
    var p = HazardWatchPolicy()
    let h17 = p.line(forReply: "NONE", now: 0)
    #expect(h17 == nil)
    let h18 = p.line(forReply: "  none. ", now: 0)
    #expect(h18 == nil)
    let h19 = p.line(forReply: "Orange cones ahead, 3 meters. Also a tree.", now: 1)
    #expect(h19 == "Caution: Orange cones ahead, 3 meters.")
    let h20 = p.line(forReply: "orange cones ahead 3 meters", now: 5)
    #expect(h20 == nil)
    let h21 = p.line(forReply: "Scooter on the left, 2 meters", now: 6)
    #expect(h21 == "Caution: Scooter on the left, 2 meters.")
    let h22 = p.line(forReply: "Orange cones ahead, 3 meters", now: 40)
    #expect(h22 != nil)   // outside the 30 s window
}

// MARK: HazardGeoJSON

/// The hazard map is a valid FeatureCollection with lon/lat order and the spoken text.
@Test func hazardMapIsValidGeoJSON() throws {
    let r = HazardRecord(kind: "pothole", text: "Hole ahead, two meters.", latitude: 40.1105,
                         longitude: -88.2240, accuracy: 6, time: 1_789_000_000, photo: "hazard-1.jpg")
    let data = try HazardGeoJSON.encode([r])
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(obj?["type"] as? String == "FeatureCollection")
    let f = (obj?["features"] as? [[String: Any]])?.first
    let coords = (f?["geometry"] as? [String: Any])?["coordinates"] as? [Double]
    #expect(coords == [-88.2240, 40.1105])
    let props = f?["properties"] as? [String: Any]
    #expect(props?["kind"] as? String == "pothole")
    #expect(props?["photo"] as? String == "hazard-1.jpg")
}

// MARK: Review round 4 (sweep, stacked signs, decimals)

/// Walking toward a curb at 1.2 m/s: each evaluation sees it 0.5 m closer. World-anchored
/// agreement (distance + travelled) still confirms it by the third trusted evaluation.
@Test func aCurbYouWalkTowardStillConfirms() {
    var d = GroundHazardDetector()
    var result: GroundHazard?
    for i in 0..<3 {
        let walked = Float(i) * 0.5
        let frame = ground { $0 >= 3.0 - walked ? -0.15 : 0 }
        let r = d.update(frame, trusted: true, travelled: walked, time: Double(i) * 0.4)
        result = r
    }
    #expect(result?.kind == .dropOff)
}

/// Stale evaluations (older than 2 s) never pair with fresh ones.
@Test func staleEvaluationsExpire() {
    var d = GroundHazardDetector()
    let curb = ground { $0 >= 2.1 ? -0.15 : 0 }
    _ = d.update(curb, trusted: true, time: 0)
    _ = d.update(curb, trusted: true, time: 0.2)
    let late = d.update(curb, trusted: true, time: 5)
    #expect(late == nil)
}

/// A wall filling part of a bin (tall returns) is not a step up.
@Test func aPartialWallIsNotAStep() {
    var samples = ground()
    for f in stride(from: Float(2.4), to: 2.7, by: 0.1) {
        for l: Float in [-0.3, -0.15] { samples.append(GroundSample(forward: f, lateral: l, height: -0.9 + 1.2)) }
    }
    let h = GroundHazardDetector().classify(samples.filter { !($0.forward >= 2.4 && $0.forward < 2.7 && $0.lateral > 0) })
    #expect(h?.kind != .stepUp && h?.kind != .lowObstacle)
}

/// Stacked sign text ("SIDEWALK" over "CLOSED") is read as one sign.
@Test func stackedSignLinesAreJoined() {
    var p = SignPolicy()
    let r = p.line(for: [(text: "SIDEWALK", confidence: 0.6), (text: "CLOSED", confidence: 0.6)], now: 0)
    #expect(r == "Sign: sidewalk closed.")
}

/// A recently spoken sign does not block a second sign in the same view.
@Test func aSecondSignIsStillRead() {
    var p = SignPolicy()
    let first = p.line(for: [(text: "ROAD CLOSED", confidence: 0.9)], now: 0)
    #expect(first == "Sign: road closed.")
    let second = p.line(for: [(text: "ROAD CLOSED", confidence: 0.9), (text: "DETOUR", confidence: 0.9)], now: 5)
    #expect(second == "Sign: detour.")
}

/// A STOP sign faces drivers: never spoken. A crossing's PUSH BUTTON sign is, as one phrase.
@Test func stopSignsAreForDriversPushButtonIsForWalkers() {
    var p = SignPolicy()
    let stop = p.line(for: [(text: "STOP", confidence: 0.95)], now: 0)
    #expect(stop == nil)
    let push = p.line(for: [(text: "PUSH BUTTON", confidence: 0.9), (text: "FOR WALK SIGNAL", confidence: 0.8)], now: 1)
    #expect(push == "Sign: push button.")
}

/// Far, small text: a multi-word safety sign is read, a lone storefront word is not.
@Test func farTextReadsSafetySignsButNotStorefrontWords() {
    var p = SignPolicy()
    let far: Float = 1.0 / 120
    let exit = p.line(for: [SignPolicy.SeenText(text: "EXIT", confidence: 0.9, height: far)], now: 0)
    #expect(exit == nil)
    let closed = p.line(for: [SignPolicy.SeenText(text: "SIDEWALK CLOSED", confidence: 0.9, height: far)], now: 1)
    #expect(closed == "Sign: sidewalk closed.")
    let nearExit = p.line(for: [SignPolicy.SeenText(text: "EXIT", confidence: 0.9, height: 1.0 / 40)], now: 2)
    #expect(nearExit == "Sign: exit.")
}

/// Far lines are never joined: a distant "ROAD" and a shop's "CLOSED" are not a ROAD CLOSED sign.
@Test func farLinesAreNotJoinedIntoAPhantomSign() {
    var p = SignPolicy()
    let far: Float = 1.0 / 120
    let phantom = p.line(for: [SignPolicy.SeenText(text: "ROAD", confidence: 0.9, height: far),
                               SignPolicy.SeenText(text: "CLOSED", confidence: 0.9, height: far)], now: 0)
    #expect(phantom == nil)
    let real = p.line(for: [SignPolicy.SeenText(text: "ROAD", confidence: 0.9, height: 1.0 / 30),
                            SignPolicy.SeenText(text: "CLOSED", confidence: 0.9, height: 1.0 / 30)], now: 1)
    #expect(real == "Sign: road closed.")
}

/// A SeenText with no height is treated as far: a lone word of unknown size is not read.
@Test func unknownTextSizeCountsAsFar() {
    var p = SignPolicy()
    let r = p.line(for: [SignPolicy.SeenText(text: "EXIT", confidence: 0.9)], now: 0)
    #expect(r == nil)
}

/// Only close text, or several words, may be mentioned to the walker or the language model.
@Test func onlyCloseOrMultiWordTextMayBeMentioned() {
    let p = SignPolicy()
    #expect(!p.mayMention(SignPolicy.SeenText(text: "EXIT", confidence: 0.9, height: 1.0 / 150)))
    #expect(p.mayMention(SignPolicy.SeenText(text: "EXIT", confidence: 0.9, height: 1.0 / 40)))
    #expect(p.mayMention(SignPolicy.SeenText(text: "Sidewalk closed", confidence: 0.9, height: 1.0 / 150)))
}

/// A partial read of a sign just spoken ("CLOSED" after "SIDEWALK CLOSED") is not re-announced.
@Test func aPartialReadOfTheSameSignIsQuiet() {
    var p = SignPolicy()
    let full = p.line(for: [(text: "SIDEWALK", confidence: 0.9), (text: "CLOSED", confidence: 0.9)], now: 0)
    #expect(full == "Sign: sidewalk closed.")
    let partial = p.line(for: [(text: "CLOSED", confidence: 0.9)], now: 3)
    #expect(partial == nil)
}

/// A hazard logged without a GPS fix gets a null geometry, not a point at 0, 0.
@Test func aHazardWithoutAFixHasNullGeometry() throws {
    let r = HazardRecord(kind: "sign", text: "Sign: exit.", latitude: 0, longitude: 0, accuracy: -1, time: 0)
    let obj = try JSONSerialization.jsonObject(with: HazardGeoJSON.encode([r])) as? [String: Any]
    let f = (obj?["features"] as? [[String: Any]])?.first
    #expect(f?["geometry"] is NSNull)
}

/// A late reply keeps the hazard and its side but loses the (now wrong) distance.
@Test func aLateReplyLosesItsDistance() {
    #expect(HazardWatchPolicy.withoutDistance("Orange cones ahead, 3 meters") == "Orange cones ahead")
    #expect(HazardWatchPolicy.withoutDistance("Scooter on the left about 2.5 m.") == "Scooter on the left.")
    #expect(HazardWatchPolicy.withoutDistance("Low branch ahead") == "Low branch ahead")
}

/// A decimal distance survives the first-sentence cut.
@Test func hazardReplyKeepsDecimals() {
    var p = HazardWatchPolicy()
    let r = p.line(forReply: "Scooter ahead, 2.5 meters. Also a tree.", now: 0)
    #expect(r == "Caution: Scooter ahead, 2.5 meters.")
}
