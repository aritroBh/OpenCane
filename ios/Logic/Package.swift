// swift-tools-version: 6.0
// CaneKitLogic — pure-Swift, Foundation-only logic for CaneKit.
// No ARKit / UIKit / WatchKit here so `swift test` runs on a Mac with only Command Line Tools.
//
//  Package.swift
//  Module: CaneKitLogic (SwiftPM manifest)
//
//  Purpose: declares the one library product the iOS app (`CaneKit`) and the watch app
//  (`CaneKitWatch`) link against — `ios/project.yml` lists it as `packages: CaneKitLogic` at
//  `path: Logic`; the widget extension does NOT link it — plus the Swift Testing target that pins
//  every numeric rule (metres, seconds, degrees, Hz) the app relies on (AGENTS.md hard rule 3:
//  decisions with a number go here, with a test). `ios/scripts/test.sh` (`make test`, the local
//  gate before every commit) and the manual-only CI job `logic-tests` (Linux, `swift:6.2`
//  container, `.github/workflows/ci.yml`) run `swift test` against this manifest.
//
//  Owner / callers: SwiftPM and XcodeGen read it; nobody imports it. Tests: `Tests/
//  CaneKitLogicTests/` (run `make test` for the current count rather than trusting a number in
//  a doc).
//
//  Key invariants:
//    · The `swift-tools-version` line above must stay the first line of the file.
//    · Zero dependencies and Foundation-only sources — adding ARKit / UIKit / MapKit /
//      CoreLocation imports breaks the Command-Line-Tools-only test run and the Linux CI job.
//      Today every source imports only Foundation, and tests only Foundation + Testing.
//    · Swift 6 language mode, but NOT MainActor default isolation (unlike the app targets):
//      every type here is nonisolated; stateful classes are single-owner, not Sendable.
//    · Platforms must stay at iOS 26 / watchOS 26 (deployment targets of the app) + macOS 15
//      (host for `swift test` on the Mac); Linux ignores the platforms list.
//    · ⚠ Tests must not call a `mutating` member directly inside `#expect` — hoist it into a
//      local first (AGENTS.md "Commands", Step 27: `make test` did not compile at all).
import PackageDescription

/// The `CaneKitLogic` package: one library (`CaneKitLogic`) and its test target
/// (`CaneKitLogicTests`, Swift Testing; every `.swift` file in the folders is picked up). Both
/// targets use the default SwiftPM layout (`Sources/CaneKitLogic`, `Tests/CaneKitLogicTests`),
/// which is why no `path:` is given.
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
