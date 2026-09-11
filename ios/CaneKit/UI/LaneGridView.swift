//
//  LaneGridView.swift
//  CaneKit
//
//  The 3×2 depth grid (Head / Torso × Left / Center / Right) with the TRUSTED / SWEEPING pill.
//  Readable from ~1 m: rounded tabular digits, lane-ladder fills with ink text, a level word
//  on every tile so meaning never rests on colour alone. VoiceOver reads each row as one
//  sentence (docs/design.md §6.2).
//

import CaneKitLogic
import SwiftUI

struct LaneGridView: View {
    let report: LaneReport

    private let laneNames = ["Left", "Center", "Right"]

    var body: some View {
        CKCard(title: "Obstacles") {
            HStack {
                Spacer()
                CKStatusPill(text: report.isTrusted ? "Trusted" : "Sweeping",
                             tone: report.isTrusted ? .trusted : .warning,
                             systemImage: report.isTrusted ? "checkmark" : "arrow.left.arrow.right",
                             spoken: report.isTrusted ? "Depth trusted" : "Sweeping, warnings paused",
                             updatesFrequently: true)
            }
            row(title: "Head", values: report.head)
            row(title: "Torso", values: report.torso)
        }
    }

    private func row(title: String, values: [Float]) -> some View {
        VStack(alignment: .leading, spacing: CKSpacing.xs) {
            Text(title)
                .font(CKFont.secondary.weight(.semibold))
                .foregroundStyle(CKColor.textSecondary)
            HStack(spacing: CKSpacing.sm) {
                ForEach(0..<3, id: \.self) { i in
                    LaneTile(label: laneNames[i], distance: values[i], hasData: report.depthAvailable)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) row")
        .accessibilityValue(spoken(values))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func spoken(_ values: [Float]) -> String {
        guard report.depthAvailable else { return "no depth data" }
        return zip(laneNames, values).map { name, d in
            "\(name.lowercased()) \(d.isFinite && d < 4.5 ? SpokenDistance.phrase(d) : "clear")"
        }.joined(separator: ", ")
    }
}

/// One cell: metres (or "clear"), a level word, lane-ladder fill. Hidden from VoiceOver —
/// the row exposes the combined value.
struct LaneTile: View {
    let label: String
    let distance: Float
    let hasData: Bool

    private var level: TileLevel { TileLevel.level(for: distance, hasData: hasData) }

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(level == .noData ? CKColor.textSecondary : CKColor.ink.opacity(0.7))
            Text(text)
                .font(CKFont.tile)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(levelWord)
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(level == .noData ? CKColor.textSecondary : CKColor.ink)
        .frame(maxWidth: .infinity)
        .padding(.vertical, CKSpacing.md)
        .background(fill, in: RoundedRectangle(cornerRadius: CKRadius.tile, style: .continuous))
        .accessibilityHidden(true)
    }

    private var text: String {
        guard hasData else { return "—" }
        guard distance.isFinite, distance < 4.5 else { return "clear" }
        return String(format: "%.1f m", distance)
    }

    private var levelWord: String {
        switch level {
        case .urgent: return "STOP"
        case .near: return "NEAR"
        case .far: return "FAR"
        case .clear: return "CLEAR"
        case .noData: return "NO DATA"
        }
    }

    private var fill: Color {
        switch level {
        case .urgent: return CKColor.laneUrgent
        case .near: return CKColor.laneNear
        case .far: return CKColor.laneFar
        case .clear: return CKColor.laneClear
        case .noData: return CKColor.laneNoData
        }
    }
}

#Preview {
    LaneGridView(report: LaneReport(
        grid: LaneGrid(head: [3.2, 1.0, .infinity], torso: [0.5, 1.6, 2.4], centerDepth: 1.6),
        isTrusted: true, depthAvailable: true))
    .padding(CKSpacing.gutter)
    .background(CKColor.background)
}
