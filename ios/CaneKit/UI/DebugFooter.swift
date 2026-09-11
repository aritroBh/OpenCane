//
//  DebugFooter.swift
//  CaneKit
//
//  Developer strip: fps, gyro magnitude, tracking state, thermal, battery, Camera Control spike.
//  Hidden from VoiceOver; the blind user never needs it.
//

import SwiftUI

struct DebugFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("fps \(model.depth.fps, specifier: "%.0f") · |ω| \(model.depth.report.rotationRate, specifier: "%.2f") rad/s · frames \(model.depth.framesProcessed)")
            Text("tracking \(model.depth.tracking) · thermal \(model.thermalName) · battery \(model.batteryPercent)% · mesh \(model.depth.meshEnabled ? "on" : "off")")
            Text("Camera Control: \(model.cameraControlPresses == 0 ? "no events yet" : "\(model.cameraControlPresses) press(es)")")
        }
        .font(CKFont.mono)
        .foregroundStyle(CKColor.textSecondary)
        .accessibilityHidden(true)
    }
}
