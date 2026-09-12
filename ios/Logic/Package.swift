// swift-tools-version: 6.0
// CaneKitLogic — pure-Swift, Foundation-only logic for CaneKit.
// No ARKit / UIKit / WatchKit here so `swift test` runs on a Mac with only Command Line Tools.
//
//  Package.swift
//  Module: CaneKitLogic (SwiftPM manifest)
//
//  Purpose: declares the one library product the iOS app, the watch app and the widget link
//  against, plus the Swift Testing target that pins every numeric rule (metres, seconds,
//  degrees, Hz) the app relies on. `ios/scripts/test.sh` (`make test`) and the required CI job
//  `logic-tests` run `swift test` against this manifest.
//
//  Key invariants:
//    · The `swift-tools-version` line above must stay the first line of the file.
//    · Zero dependencies and Foundation-only sources — adding ARKit / UIKit / MapKit /
//      CoreLocation imports breaks the Command-Line-Tools-only test run.
//    · Swift 6 language mode, but NOT MainActor default isolation (unlike the app targets):
//      every type here is nonisolated; stateful classes are single-owner, not Sendable.
//    · Platforms must stay at iOS 26 / watchOS 26 (deployment targets of the app) + macOS 15
//      (host for `swift test`).
import PackageDescription

/// The `CaneKitLogic` package: one library (`CaneKitLogic`) and its test target
/// (`CaneKitLogicTests`, Swift Testing; every `.swift` file in the folders is picked up).
let package = Package(
    name: "CaneKitLogic",
    platforms: [.iOS("26.0"), .watchOS("26.0"), .macOS(.v15)],
    products: [
        .library(name: "CaneKitLogic", targets: ["CaneKitLogic"]),
    ],
    targets: [
        .target(
            name: "CaneKitLogic",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CaneKitLogicTests",
            dependencies: ["CaneKitLogic"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
