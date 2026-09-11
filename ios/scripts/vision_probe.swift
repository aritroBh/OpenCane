#!/usr/bin/env swift
//
//  vision_probe.swift — run the app's on-device camera logic over a folder of images on the Mac.
//
//  Same Apple Vision requests the phone runs (OnDeviceVision.swift): scene classification and text
//  recognition, then the same sign-phrase matching (CaneKitLogic.SignPolicy phrases) and the same
//  path-hazard label map (OnDeviceHazards). Point it at Street View captures of the route to see
//  what CaneKit would say at each corner before walking it.
//
//    swift ios/scripts/vision_probe.swift ios/scripts/streetview      # reads frames.json there
//
//  Keep `signPhrases` / `hazardMap` in sync with Hazards.swift / OnDeviceVision.swift.
//

import Foundation
import Vision

let signPhrases = [
    "SIDEWALK CLOSED", "ROAD CLOSED", "USE OTHER SIDEWALK", "NO PEDESTRIANS", "DO NOT ENTER",
    "WET FLOOR", "KEEP OUT", "WORK ZONE", "CONSTRUCTION", "DETOUR", "DANGER", "CAUTION",
    "PUSH BUTTON", "CLOSED", "EXIT", "ENTRANCE", "PULL", "PUSH",
].sorted { $0.count > $1.count }
// Exact identifiers (OnDeviceHazards.map) — substring matching produced "ice" from license_plate.
let hazardMap: [String: String] = [
    "fence": "a fence", "stairs": "stairs", "staircase": "stairs", "scooter": "a scooter",
    "bicycle": "a bicycle", "motorcycle": "a motorcycle", "pole": "a pole",
    "fire_hydrant": "a fire hydrant", "hydrant": "a fire hydrant", "bench": "a bench",
    "trash_can": "a trash can", "snow": "snow", "ice": "ice", "dog": "a dog",
]
let boring: Set<String> = ["outdoor", "structure", "material", "blue_sky", "sky", "daytime",
                           "night_sky", "land", "people", "adult"]

func normalize(_ s: String) -> String {
    String(s.uppercased().map { $0.isLetter ? $0 : " " }).split(separator: " ").joined(separator: " ")
}

struct Entry: Decodable { let file: String; let lat: Double; let lon: Double; let heading: Double? }

let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "ios/scripts/streetview")
let entries = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: dir.appendingPathComponent("frames.json")))) ?? []
if entries.isEmpty { print("no frames.json in \(dir.path)"); exit(1) }

for e in entries {
    guard let data = try? Data(contentsOf: dir.appendingPathComponent(e.file)) else { print("\(e.file): missing"); continue }
    let labels = ((try? await ClassifyImageRequest().perform(on: data)) ?? [])
        .filter { $0.confidence >= 0.25 && !boring.contains($0.identifier) }
        .sorted { $0.confidence > $1.confidence }.prefix(6)
    var t = RecognizeTextRequest(); t.recognitionLevel = .accurate; t.minimumTextHeightFraction = 1.0 / 128   // as HazardScanner
    let texts = ((try? await t.perform(on: data)) ?? []).compactMap { $0.topCandidates(1).first }
        .filter { $0.confidence >= 0.5 }.map(\.string)
    let lines = texts.map(normalize)
    let norm = lines.map { " \($0) " } + [" " + lines.joined(separator: " ") + " "]   // stacked sign lines
    let sign = signPhrases.first { p in norm.contains { $0.contains(" \(p) ") } }
    // On the phone this is also gated on LiDAR seeing something ahead; here we show the label match.
    let hazard = labels.first { $0.confidence >= 0.35 && hazardMap[$0.identifier.lowercased()] != nil }
        .flatMap { hazardMap[$0.identifier.lowercased()] }
    print("── \(e.file)  (\(e.lat), \(e.lon)) heading \(Int(e.heading ?? 0))°")
    print("   sees:   " + labels.map { "\($0.identifier) \(Int($0.confidence * 100))%" }.joined(separator: ", "))
    if !texts.isEmpty { print("   text:   " + texts.prefix(6).joined(separator: " | ")) }
    print("   says:   " + [sign.map { "Sign: \($0.lowercased())." }, hazard.map { "Caution: \($0) ahead." }]
        .compactMap { $0 }.joined(separator: "  ") + (sign == nil && hazard == nil ? "(nothing)" : ""))
}
