// swift-tools-version: 6.0
import PackageDescription

// CoreBluetooth refuses to run in a process that has no NSBluetoothAlwaysUsageDescription.
// A command-line tool has no bundle, so the Info.plist is embedded in the binary itself, in
// the __TEXT,__info_plist section, where the system looks for it.
let infoPlist = Context.packageDirectory + "/Sources/paperboy-cli/Info.plist"

let package = Package(
    name: "paperboy-cli",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../PaperboyCore")
    ],
    targets: [
        .executableTarget(
            name: "paperboy-cli",
            dependencies: [
                .product(name: "PaperboyCore", package: "PaperboyCore"),
                .product(name: "PaperboyBLE", package: "PaperboyCore"),
            ],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist])
            ]
        )
    ]
)
