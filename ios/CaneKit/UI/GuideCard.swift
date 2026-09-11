//
//  GuideCard.swift
//  CaneKit
//
//  The Guide: what the blind user (via VoiceOver) and the sighted teammate both need first —
//  the current instruction, the distance, and the big buttons. Route picker underneath:
//  the recorded demo route or a typed MapKit destination.
//

import CaneKitLogic
import SwiftUI

struct GuideCard: View {
    @Environment(AppModel.self) private var model
    @ScaledMetric(relativeTo: .largeTitle) private var hero = 64

    var body: some View {
        @Bindable var model = model
        CKCard(title: "Guide") {
            Text(model.nav.instruction)
                .font(CKFont.instruction)
                .foregroundStyle(CKColor.textPrimary)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits([.isHeader, .updatesFrequently])

            if let d = model.nav.distanceToNext, model.nav.isNavigating || model.nav.arrived {
                HStack(alignment: .firstTextBaseline, spacing: CKSpacing.sm) {
                    Text("\(d)")
                        .font(CKFont.hero(min(hero, 80)))
                        .foregroundStyle(CKColor.textPrimary)
                    Text("m").font(CKFont.button).foregroundStyle(CKColor.textSecondary)
                    Spacer()
                    if let err = model.nav.bearingError {
                        CKStatusPill(text: bearingWord(err), tone: abs(err) <= 25 ? .trusted : .warning,
                                     systemImage: abs(err) <= 25 ? "arrow.up" : (err > 0 ? "arrow.turn.up.right" : "arrow.turn.up.left"),
                                     spoken: "Heading: \(bearingWord(err))", updatesFrequently: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(d) meters to the next point")
            }

            HStack(spacing: CKSpacing.sm) {
                CKStatusPill(text: gpsWord, tone: gpsTone, systemImage: "location",
                             spoken: "GPS: \(gpsWord)", updatesFrequently: true)
                if model.nav.gpsWeak {
                    CKStatusPill(text: "GPS weak", tone: .warning, systemImage: "exclamationmark.triangle")
                }
            }

            if model.nav.isNavigating {
                HStack(spacing: CKSpacing.lg) {
                    CKBigButton(title: "Next", systemImage: "forward.fill",
                                hint: "Skips to the next instruction") { model.nav.next() }
                    CKBigButton(title: "Recenter", systemImage: "location.north.line", role: .secondary,
                                hint: "Sets straight ahead as the beacon's forward direction") { model.recenter() }
                }
                HStack(spacing: CKSpacing.sm) {
                    CKStatusPill(text: beaconWord, tone: model.beacon.isRunning && model.beaconEnabled ? .trusted : .neutral,
                                 systemImage: "dot.radiowaves.left.and.right",
                                 spoken: "Beacon: \(beaconWord)", updatesFrequently: true)
                    CKStatusPill(text: model.head.isConnected ? "Head tracked" : "Compass only",
                                 tone: .neutral, systemImage: "airpodspro",
                                 spoken: model.head.isConnected ? "AirPods head tracking on" : "No AirPods head tracking")
                }
                CKBigButton(title: "Stop route", systemImage: "stop.fill", role: .destructive,
                            hint: "Ends guidance") { model.stopRoute() }
            } else {
                CKBigButton(title: "Start demo route", systemImage: "figure.walk",
                            hint: "Starts the recorded ISR Townsend Hall to CIF route") { model.startDemoRoute() }
                HStack(spacing: CKSpacing.sm) {
                    TextField("Or type a destination", text: $model.destinationQuery)
                        .textFieldStyle(.roundedBorder)
                        .font(CKFont.body)
                        .submitLabel(.go)
                        .onSubmit { model.startMapKitRoute() }
                        .accessibilityLabel("Destination")
                    Button("Go") { model.startMapKitRoute() }
                        .buttonStyle(CKBigButtonStyle(role: .secondary))
                        .frame(minHeight: CKMetrics.touchTarget)
                        .disabled(model.isBuildingRoute)
                        .accessibilityHint("Builds a walking route with Apple Maps")
                }
            }
            if let err = model.routeError ?? model.location.lastError {
                Text(err).font(CKFont.secondary).foregroundStyle(CKColor.laneUrgent)
            }
        }
    }

    private var beaconWord: String {
        guard model.beaconEnabled else { return "Beacon off" }
        guard model.beacon.isRunning else { return model.beacon.lastError ?? "Beacon idle" }
        return "Beacon \(Int(model.beacon.renderedVolume * 100))%"
    }

    private func bearingWord(_ err: Double) -> String {
        if abs(err) <= 25 { return "On course" }
        return err > 0 ? "Veer right \(Int(abs(err)))°" : "Veer left \(Int(abs(err)))°"
    }

    private var gpsWord: String {
        guard let f = model.location.fix else {
            return model.location.denied ? "Denied" : (model.location.isRunning ? "Searching" : "Off")
        }
        return f.accuracy < 0 ? "No accuracy" : "±\(Int(f.accuracy)) m"
    }

    private var gpsTone: CKStatusPill.Tone {
        guard let f = model.location.fix, f.accuracy >= 0 else { return .neutral }
        return f.accuracy <= 15 ? .trusted : .warning
    }
}
