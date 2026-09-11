//
//  WatchContentView.swift
//  CaneKit Watch
//
//  Glanceable wrist screen: the current instruction, distance, and (step 5) big Next /
//  Describe / Recenter buttons plus crown-rotation "next".
//

import SwiftUI

struct WatchContentView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CaneKit")
                .font(.headline)
            Text(model.instruction)
                .font(.title3.weight(.semibold))
                .lineLimit(3)
                .minimumScaleFactor(0.7)
            if let d = model.distanceM {
                Text("\(d) m")
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            Label(model.phoneReachable ? "Phone connected" : "Phone not connected",
                  systemImage: model.phoneReachable ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

#Preview {
    WatchContentView()
        .environment(WatchModel())
}
