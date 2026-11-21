// swift-tools-version: 6.0
import PackageDescription

// NOT how the app is built. The app is an Xcode project generated from project.yml.
//
// This manifest exists only so that `swift build` on a Mac without Xcode can typecheck most of
// the app's sources against the macOS SDK (SwiftUI, WebKit and CoreBluetooth exist there too).
// Not covered by it:
//   - code inside `#if os(iOS)` / `#if canImport(UIKit)` (background tasks, UIKit calls);
//   - the three files excluded below: they use `@State`, which is a macro whose compiler
//     plugin ships only with Xcode.
let package = Package(
    name: "PaperboyAppTypecheck",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../PaperboyCore")],
    targets: [
        .target(
            name: "PaperboyAppTypecheck",
            dependencies: [
                .product(name: "PaperboyCore", package: "PaperboyCore"),
                .product(name: "PaperboyBLE", package: "PaperboyCore"),
            ],
            path: "Sources",
            exclude: ["PaperboyApp.swift", "ContentView.swift", "SettingsView.swift", "Assets.xcassets", "PrivacyInfo.xcprivacy"]
        )
    ]
)
