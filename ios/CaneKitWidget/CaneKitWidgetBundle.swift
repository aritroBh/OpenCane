//
//  CaneKitWidgetBundle.swift
//  CaneKitWidget
//
//  Widget extension entry: hosts the navigation Live Activity (Dynamic Island + lock screen).
//
//  Implements the extension side of docs/design.md §6.7. No home-screen widgets: the bundle
//  contains only `NavLiveActivity`.
//
//  Accessibility contract: none of its own; see NavLiveActivity.swift.
//

import SwiftUI
import WidgetKit

/// `@main` entry of the `com.aritro.canekit.widget` extension; vends the one Live Activity.
@main
struct CaneKitWidgetBundle: WidgetBundle {
    var body: some Widget {
        NavLiveActivity()
    }
}
