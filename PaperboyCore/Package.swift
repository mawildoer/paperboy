// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaperboyCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PaperboyCore", targets: ["PaperboyCore"]),
        .library(name: "PaperboyBLE", targets: ["PaperboyBLE"]),
    ],
    targets: [
        // Everything that needs neither UIKit nor WebKit nor a radio.
        .target(name: "PaperboyCore"),
        // CoreBluetooth transport shared by the iOS app and the Mac CLI.
        .target(name: "PaperboyBLE", dependencies: ["PaperboyCore"]),
        .testTarget(name: "PaperboyCoreTests", dependencies: ["PaperboyCore"]),
    ]
)
