//
//  ArrivalCardView.swift
//  CaneKit
//
//  Shown once the last waypoint fires: distance, minutes, steps — the "fitness hook without a
//  fitness app" (docs/ideas.md §5.4). Also visible while walking so the teammate sees the trip.
//
//  Implements docs/design.md §6.4 (Arrival card: three tabular stats). Deviation: it is an inline
//  card on the root scroll view (titled "This trip" while walking, "Arrived" after), not a sheet,
//  and it has no Describe / Done buttons (Guide's "Where am I" is the describe path).
//
//  Accessibility contract: the whole card is one combined element whose label is
//  `TripTracker.spokenSummary(destination:)`, so VoiceOver hears one sentence instead of six
//  fragments. No XCUITest queries it (a simulator walk never arrives).
//

import SwiftUI

/// Trip summary card: distance walked, elapsed minutes and steps, plus the step source line.
///
/// `ContentView` inserts it only while navigating or after arrival.
struct ArrivalCardView: View {
    /// App-wide owner of `trip` (TripTracker) and `nav` (arrival state).
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
        // One VoiceOver sentence for the whole card (spoken summary from TripTracker).
        .accessibilityElement(children: .combine)
        .accessibilityLabel(trip.spokenSummary(destination: model.nav.arrived ? "Arrived" : "So far"))
    }

    /// One stat column: a large tabular value (`CKFont.tile`, shrinks to 60 % before it would
    /// truncate) over a secondary caption.
    /// - Parameters:
    ///   - value: the formatted number ("1.0 km", "14", "1300", or "—").
    ///   - label: the unit caption ("walked", "minutes", "steps").
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

    /// Distance walked: "N m" below 950 m, "%.1f km" from 950 m up (950 m is the switch-over).
    private func distanceText(_ m: Double) -> String {
        m >= 950 ? String(format: "%.1f km", m / 1000) : "\(Int(m.rounded())) m"
    }

    /// Elapsed seconds → whole minutes, rounded to nearest.
    private func minutesText(_ s: TimeInterval) -> String {
        "\(Int((s / 60).rounded()))"
    }
}
