//
//  LaneGridView.swift
//  CaneKit
//
//  The 3×2 depth grid (Head / Torso × Left / Center / Right) with the TRUSTED / SWEEPING pill.
//  Readable from ~1 m: rounded tabular digits, lane-ladder fills with ink text, a level word
//  on every tile so meaning never rests on colour alone. VoiceOver reads each row as one
//  sentence (docs/design.md §6.2).
//
//  Implements docs/design.md §6.2 (Depth grid), the lane ladder of §2, and the §4 / §7 rules
//  "no animation on the depth grid, no colour cross-fades on lane tiles": tiles re-render at
//  the depth engine's ~15 Hz with instant changes. Deviation from §6.2: VoiceOver gets one
//  element per row ("Head row", "Torso row") instead of one for the whole grid.
//
//  Accessibility contract: tiles are hidden; each row is one element labelled "<Row> row" with
//  a spoken value ("left one meter, center clear, right clear" / "no depth data").
//  ⚠ test contract: testAccessibilityLabelsExist queries `app.otherElements["Head row"]`.
//

import CaneKitLogic
import SwiftUI

/// The "Obstacles" card: trust pill plus the Head and Torso rows of three lane tiles each.
///
/// Pure display: takes a `LaneReport` value and has no state or actions (tiles are not tappable,
/// design.md §3).
struct LaneGridView: View {
    /// Latest per-frame depth summary from `DepthEngine` (`head` / `torso` are 3 metres each,
    /// left → right; plus `isTrusted` and `depthAvailable`).
    let report: LaneReport

    /// Column names, left → right; used for the tile captions and the spoken row value.
    private static let laneNames = ["Left", "Center", "Right"]

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

    /// One labelled row of three tiles, exposed to VoiceOver as a single element.
    ///
    /// Accessibility: label "\(title) row", value from `spoken(_:)`, trait `.updatesFrequently`.
    /// ⚠ test contract: the "Head row" label format is queried by the XCUITests.
    /// - Parameters:
    ///   - title: "Head" or "Torso"; shown as the row caption and used in the label.
    ///   - values: three distances in metres, left → right (non-finite = nothing seen).
    private func row(title: String, values: [Float]) -> some View {
        VStack(alignment: .leading, spacing: CKSpacing.xs) {
            Text(title)
                .font(CKFont.secondary.weight(.semibold))
                .foregroundStyle(CKColor.textSecondary)
            HStack(spacing: CKSpacing.sm) {
                ForEach(0..<3, id: \.self) { i in
                    LaneTile(label: Self.laneNames[i], distance: values[i], hasData: report.depthAvailable)
                }
            }
        }
        // ⚠ test contract: one element per row, label "<title> row".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) row")
        .accessibilityValue(spoken(values))
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// Spoken row value: "no depth data" without depth, else "left <d>, center <d>, right <d>"
    /// where each <d> is `SpokenDistance.phrase` under 4.5 m and "clear" otherwise (the same
    /// 4.5 m cutoff as the visible tile text).
    private func spoken(_ values: [Float]) -> String {
        guard report.depthAvailable else { return "no depth data" }
        return zip(Self.laneNames, values).map { name, d in
            "\(name.lowercased()) \(d.isFinite && d < 4.5 ? SpokenDistance.phrase(d) : "clear")"
        }.joined(separator: ", ")
    }
}

/// One cell: metres (or "clear"), a level word, lane-ladder fill. Hidden from VoiceOver —
/// the row exposes the combined value.
///
/// Three-way redundancy (design.md §0 rule 2): fill colour + level word (STOP / NEAR / FAR /
/// CLEAR / NO DATA) + a number, so no state depends on colour alone. Text on a lane fill is
/// `ink`; on the no-data fill it is `textSecondary`.
struct LaneTile: View {
    /// Column caption: "Left", "Center" or "Right".
    let label: String
    /// Nearest distance in this cell in metres; non-finite means nothing seen.
    let distance: Float
    /// False when the depth engine has no depth at all; the tile then shows "—" / NO DATA.
    let hasData: Bool

    /// Ladder level from CaneKitLogic (thresholds live there, not in the UI).
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

    /// Visible metres: "—" without data, "clear" at ≥ 4.5 m or non-finite, else "%.1f m".
    /// 4.5 m is a display cutoff, distinct from the 2.0 m colour threshold.
    private var text: String {
        guard hasData else { return "—" }
        guard distance.isFinite, distance < 4.5 else { return "clear" }
        return String(format: "%.1f m", distance)
    }

    /// Uppercase level word drawn under the number (the glyph-equivalent of design.md §2).
    private var levelWord: String {
        switch level {
        case .urgent: return "STOP"
        case .near: return "NEAR"
        case .far: return "FAR"
        case .clear: return "CLEAR"
        case .noData: return "NO DATA"
        }
    }

    /// Lane-ladder fill for the level (identical in light and dark; brighter under HC).
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

/// Canvas preview with one tile of every lit level plus a clear (infinite) head-right cell.
#Preview {
    LaneGridView(report: LaneReport(
        grid: LaneGrid(head: [3.2, 1.0, .infinity], torso: [0.5, 1.6, 2.4], centerDepth: 1.6),
        isTrusted: true, depthAvailable: true))
    .padding(CKSpacing.gutter)
    .background(CKColor.background)
}
