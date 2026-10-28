// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tinycap",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Tinycap", targets: ["Tinycap"]),
    ],
    targets: [
        // Pure logic (geometry, file naming, settings), unit-tested.
        .target(name: "TinycapCore"),
        // The menu-bar app. Use scripts/build-app.sh to wrap it in a signed .app bundle.
        .executableTarget(name: "Tinycap", dependencies: ["TinycapCore"]),
        .testTarget(name: "TinycapCoreTests", dependencies: ["TinycapCore"]),
    ]
)
