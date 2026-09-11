// swift-tools-version: 6.0
// CaneKitLogic — pure-Swift, Foundation-only logic for CaneKit.
// No ARKit / UIKit / WatchKit here so `swift test` runs on a Mac with only Command Line Tools.
import PackageDescription

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
