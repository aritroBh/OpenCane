//
//  ArrivalCardView.swift
//  CaneKit
//
//  Shown once the last waypoint fires: distance, minutes, steps — the "fitness hook without a
//  fitness app" (docs/ideas.md §5.4). Also visible while walking so the teammate sees the trip.
//

import SwiftUI

struct ArrivalCardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let trip = model.trip
        CKCard(title: model.nav.arrived ? "Arrived" : "This trip") {
            HStack(spacing: CKSpacing.lg) {
                stat(value: distanceText(trip.distanceM), label: "walked")
                stat(value: minutesText(trip.elapsed), label: "minutes")
                stat(value: trip.steps.map { "\($0)" } ?? "—", label: "steps")
            }
            Text(trip.stepSource == "HealthKit" ? "Steps from Apple Health (watch + phone)" :
                 trip.stepSource == "Pedometer" ? "Steps from the phone pedometer" : "Steps unavailable")
                .font(CKFont.secondary)
                .foregroundStyle(CKColor.textSecondary)
            if let err = trip.lastError {
                Text(err).font(CKFont.secondary).foregroundStyle(CKColor.laneUrgent)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(trip.spokenSummary(destination: model.nav.arrived ? "Arrived" : "So far"))
    }

    private func stat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(CKFont.tile)
                .foregroundStyle(CKColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label).font(CKFont.secondary).foregroundStyle(CKColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func distanceText(_ m: Double) -> String {
        m >= 950 ? String(format: "%.1f km", m / 1000) : "\(Int(m.rounded())) m"
    }

    private func minutesText(_ s: TimeInterval) -> String {
        "\(Int((s / 60).rounded()))"
    }
}
