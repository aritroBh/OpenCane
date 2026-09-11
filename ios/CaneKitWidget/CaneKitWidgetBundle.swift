//
//  CaneKitWidgetBundle.swift
//  CaneKitWidget
//
//  Widget extension entry: hosts the navigation Live Activity (Dynamic Island + lock screen).
//

import SwiftUI
import WidgetKit

@main
struct CaneKitWidgetBundle: WidgetBundle {
    var body: some Widget {
        NavLiveActivity()
    }
}
