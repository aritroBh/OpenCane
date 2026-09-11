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
                // Never truncate: the spotter reads this line over the walker's shoulder.
                .lineLimit(nil)
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

            CKBigButton(title: model.describer.isDescribing ? "Describing…" : "Where am I",
                        systemImage: "eye", role: .secondary,
                        hint: "Takes a photo and reads out hazards and landmarks ahead",
                        value: model.describer.isDescribing ? "in progress" : nil) { model.describeScene() }
                .disabled(model.describer.isDescribing)
            if !model.describer.lastDescription.isEmpty {
                Text(model.describer.lastDescription)
                    .font(CKFont.body)
                    .foregroundStyle(CKColor.textPrimary)
                    .accessibilityLabel("Scene: \(model.describer.lastDescription)")
            }
            if let err = model.describer.lastError {
                Text(err).font(CKFont.secondary).foregroundStyle(CKColor.laneUrgent)
            }

            if model.nav.isNavigating {
                // Two per row: three-up hyphenates "Recenter" on a 17 Pro Max at default type size.
                HStack(spacing: CKSpacing.lg) {
                    CKBigButton(title: "Repeat", systemImage: "arrow.counterclockwise",
                                hint: "Says the current instruction again") { model.repeatInstruction() }
                    CKBigButton(title: "Next", systemImage: "forward.fill", role: .secondary,
                                hint: "Skips to the next instruction") { model.nav.next() }
                }
                CKBigButton(title: "Recenter", systemImage: "location.north.line", role: .secondary,
                            hint: "Sets straight ahead as the beacon's forward direction") { model.recenter() }
                HStack(spacing: CKSpacing.sm) {
                    CKStatusPill(text: beaconWord, tone: !model.audioRoute.headphonesConnected ? .warning
                                 : (model.beacon.isRunning && model.beaconEnabled ? .trusted : .neutral),
                                 systemImage: "dot.radiowaves.left.and.right",
                                 spoken: "Beacon: \(beaconWord)", updatesFrequently: true)
                    CKStatusPill(text: headWord,
                                 tone: model.audioRoute.headphonesConnected ? .neutral : .warning,
                                 systemImage: "airpodspro",
                                 spoken: headSpoken)
                }
                CKBigButton(title: "Stop route", systemImage: "stop.fill", role: .destructive,
                            hint: "Ends guidance") { model.stopRoute() }
            } else {
                if model.nav.arrived {
                    // The arrival line + trip summary are the longest of the walk: keep Repeat.
                    CKBigButton(title: "Repeat", systemImage: "arrow.counterclockwise",
                                hint: "Says the arrival line again") { model.repeatInstruction() }
                }
                CKBigButton(title: "Start demo route", systemImage: "figure.walk",
                            hint: "Starts the recorded ISR Townsend Hall to CIF route") { model.startDemoRoute() }
                HStack(spacing: CKSpacing.sm) {
                    TextField("Or type a destination", text: $model.destinationQuery)
                        .textFieldStyle(.roundedBorder)
                        .font(CKFont.body)
                        .submitLabel(.go)
                        .onSubmit { model.startMapKitRoute() }
                        .accessibilityLabel("Destination")
                    Button {
                        model.startMapKitRoute()
                    } label: {
                        // Explicit padding + fixedSize: the HStack must never squeeze this label.
                        Text("Go")
                            .font(CKFont.body.weight(.semibold))
                            .padding(.horizontal, CKSpacing.lg)
                            .frame(minWidth: 64, minHeight: CKMetrics.touchTarget)
                    }
                        .buttonStyle(CKBigButtonStyle(role: .secondary))
                        .fixedSize(horizontal: true, vertical: false)
                        .disabled(model.isBuildingRoute)
                        .accessibilityLabel("Go")
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
        guard model.audioRoute.headphonesConnected else { return "Beacon paused" }
        guard model.beacon.isRunning else { return model.beacon.lastError ?? "Beacon idle" }
        return "Beacon \(Int(model.beacon.renderedVolume * 100))%"
    }

    /// No headphones → say so; AirPods motion flowing → head tracked; else compass only.
    private var headWord: String {
        guard model.audioRoute.headphonesConnected else { return "No AirPods" }
        return model.head.isConnected ? "Head tracked" : "Compass only"
    }

    private var headSpoken: String {
        guard model.audioRoute.headphonesConnected else { return "No headphones connected; beacon paused" }
        return model.head.isConnected ? "\(model.audioRoute.outputName), head tracking on"
                                      : "\(model.audioRoute.outputName), no head tracking"
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
