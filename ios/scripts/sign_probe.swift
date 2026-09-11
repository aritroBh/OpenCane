#!/usr/bin/env swift
//
//  sign_probe.swift — how far away can CaneKit read a sign? Measured, not guessed.
//
//  Street View frames are shot from mid-road, so real signs in them are too small to test sign
//  reading. This probe pastes a white "SIDEWALK CLOSED" sign onto each route frame (scaled to the
//  phone's portrait 3:4 frame, 960×1280 like the app's 1280 px sign-scan JPEG at quality 0.8) at a
//  range of letter heights, runs the SAME Vision text request the app runs
//  (`RecognizeTextRequest`, `.fast`, language correction, `minimumTextHeightFraction` 1/128 — see
//  HazardScanner.scanSigns / OnDeviceVision.detect), and reports the smallest letter height read.
//  It also runs Vision's default (1/32) for comparison.
//
//  Distance: the iPhone 17 Pro Max main camera covers ~69° along the long edge, so on a 1280 px
//  portrait frame an object d metres away spans ≈ 931 / d px per metre. A letter h px tall that is
//  L metres tall in the world is at d ≈ 931 · L / h. We print d for 7.5 cm (typical "SIDEWALK
//  CLOSED" legend) and 15 cm ("ROAD CLOSED") letters.
//
//    swift ios/scripts/sign_probe.swift ios/scripts/streetview
//

import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

let W = 960, H = 1280
let pxPerMetreAt1m = 931.0

func normalize(_ s: String) -> String {
    String(s.uppercased().map { $0.isLetter ? $0 : " " }).split(separator: " ").joined(separator: " ")
}

/// Background (aspect-fill) + a white sign with black two-line legend, letter cap height `cap` px.
func composite(_ bg: CGImage, cap: Int) -> Data? {
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let s = max(Double(W) / Double(bg.width), Double(H) / Double(bg.height))
    let dw = Double(bg.width) * s, dh = Double(bg.height) * s
    ctx.draw(bg, in: CGRect(x: (Double(W) - dw) / 2, y: (Double(H) - dh) / 2, width: dw, height: dh))
    // Helvetica Bold cap height ≈ 0.72 × point size.
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(Double(cap) / 0.72), nil)
    let lines = ["SIDEWALK", "CLOSED"].map { t -> CTLine in
        let attr = NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: NSColor.black])
        return CTLineCreateWithAttributedString(attr)
    }
    let widths = lines.map { CTLineGetTypographicBounds($0, nil, nil, nil) }
    let lineH = Double(cap) * 1.6
    let signW = (widths.max() ?? 0) + Double(cap) * 1.2, signH = lineH * 2 + Double(cap) * 0.8
    let x0 = (Double(W) - signW) / 2, y0 = Double(H) * 0.55
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: x0, y: y0, width: signW, height: signH))
    ctx.setStrokeColor(NSColor.black.cgColor); ctx.setLineWidth(max(1, Double(cap) / 8))
    ctx.stroke(CGRect(x: x0, y: y0, width: signW, height: signH))
    for (i, line) in lines.enumerated() {
        ctx.textPosition = CGPoint(x: x0 + (signW - widths[i]) / 2, y: y0 + signH - Double(cap) * 0.4 - lineH * Double(i + 1) + (lineH - Double(cap)) / 2)
        CTLineDraw(line, ctx)
    }
    guard let img = ctx.makeImage() else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    return CGImageDestinationFinalize(dest) ? out as Data : nil
}

/// True if the app's sign logic would find "SIDEWALK CLOSED" (lines read one by one and joined).
func reads(_ jpeg: Data, minFraction: Float?) async -> Bool {
    var req = RecognizeTextRequest()
    req.recognitionLevel = .fast
    req.usesLanguageCorrection = true
    if let minFraction { req.minimumTextHeightFraction = minFraction }
    let obs = (try? await req.perform(on: jpeg)) ?? []
    // Same joining rule as SignPolicy: close lines (≥ 1/80 tall) join freely; far lines join only
    // when stacked on one sign (x overlap, heights within 1.5x, gap under one line height).
    struct L { let text: String; let r: CGRect }
    let ls = obs.compactMap { o -> L? in
        guard let c = o.topCandidates(1).first, c.confidence >= 0.5 else { return nil }
        return L(text: normalize(c.string), r: o.boundingBox.cgRect)
    }
    var hay = ls.map { " \($0.text) " }
    hay.append(" " + ls.filter { $0.r.height >= 1.0 / 80 }.map(\.text).joined(separator: " ") + " ")
    let far = ls.filter { $0.r.height < 1.0 / 80 }.sorted { $0.r.minY > $1.r.minY }
    for (i, a) in far.enumerated() {
        var chain = [a]
        for b in far[(i + 1)...] {
            let u = chain[chain.count - 1].r, v = b.r
            let overlap = min(u.maxX, v.maxX) - max(u.minX, v.minX)
            let gap = u.minY - (v.minY + v.height)
            if overlap > 0, max(u.height, v.height) / min(u.height, v.height) <= 1.5,
               gap >= -0.5 * v.height, gap < max(u.height, v.height) { chain.append(b) }
        }
        if chain.count > 1 { hay.append(" " + chain.map(\.text).joined(separator: " ") + " ") }
    }
    return hay.contains { $0.contains(" SIDEWALK CLOSED ") }
}

struct Entry: Decodable { let file: String }
let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "ios/scripts/streetview")
let entries = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: dir.appendingPathComponent("frames.json")))) ?? []
let caps = [6, 8, 10, 12, 14, 16, 20, 24, 30, 40]   // 1/128 of 1280 = 10 px is the app's floor
var smallestApp: [Int] = [], smallestDefault: [Int] = []
print("letter cap height (px on a 1280 px portrait frame) → read with app settings (1/128) / Vision default (1/32)")
for e in entries {
    guard let src = CGImageSourceCreateWithURL(dir.appendingPathComponent(e.file) as CFURL, nil),
          let bg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("\(e.file): missing"); continue }
    var row: [String] = []
    var bestApp: Int?, bestDef: Int?
    for cap in caps {
        guard let jpeg = composite(bg, cap: cap) else { continue }
        let a = await reads(jpeg, minFraction: 1.0 / 128), d = await reads(jpeg, minFraction: nil)
        if a, bestApp == nil { bestApp = cap }
        if d, bestDef == nil { bestDef = cap }
        row.append("\(cap):\(a ? "✓" : "·")\(d ? "✓" : "·")")
    }
    if let bestApp { smallestApp.append(bestApp) }
    if let bestDef { smallestDefault.append(bestDef) }
    print("\(e.file.padding(toLength: 24, withPad: " ", startingAt: 0)) " + row.joined(separator: " "))
}
func metres(_ cap: Int, _ letter: Double) -> String { String(format: "%.1f", pxPerMetreAt1m * letter / Double(cap)) }
if let worstApp = smallestApp.max(), let worstDef = smallestDefault.max() {
    print("\nsmallest cap read on every frame: app settings \(worstApp) px, Vision default \(worstDef) px")
    print("⇒ app reads 7.5 cm letters from ≈ \(metres(worstApp, 0.075)) m and 15 cm letters from ≈ \(metres(worstApp, 0.15)) m")
    print("⇒ default would read them from ≈ \(metres(worstDef, 0.075)) m / \(metres(worstDef, 0.15)) m")
}
