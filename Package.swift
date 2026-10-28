// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tinycap",
    platforms: [.macOS(.v15)],
    cxxLanguageStandard: .cxx17,
    products: [
        .executable(name: "Tinycap", targets: ["Tinycap"]),
    ],
    targets: [
        // Pure logic (geometry, file naming, settings, GIF encoder), unit-tested.
        .target(name: "TinycapCore"),
        // C interface over libvpx + libwebm for WebM export. Run scripts/build-vpx.sh
        // first; it builds the pinned libraries into build/vendor.
        .target(
            name: "VPXBridge",
            cxxSettings: [
                .headerSearchPath("../../build/vendor/include"),
                .headerSearchPath("../../build/vendor/include/libwebm"),
            ],
            linkerSettings: [
                .unsafeFlags(["-Lbuild/vendor/lib"]),
                .linkedLibrary("vpx"),
                .linkedLibrary("webm"),
                .linkedLibrary("c++"),
            ]
        ),
        // The menu-bar app. Use scripts/build-app.sh to wrap it in a signed .app bundle.
        .executableTarget(name: "Tinycap", dependencies: ["TinycapCore", "VPXBridge"]),
        .testTarget(name: "TinycapCoreTests", dependencies: ["TinycapCore"]),
    ]
)
