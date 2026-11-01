// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Openline",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "OpenlineCore", targets: ["OpenlineCore"]),
        .library(name: "OpenlineStore", targets: ["OpenlineStore"]),
        .library(name: "OpenlineSIP", targets: ["OpenlineSIP"]),
        .library(name: "OpenlineKit", targets: ["OpenlineKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .binaryTarget(name: "CPJSIP", path: "Vendor/CPJSIP.xcframework"),
        .target(
            name: "OpenlineBridge",
            dependencies: ["CPJSIP"],
            cxxSettings: [
                .define("PJ_AUTOCONF", to: "1"),
                .define("PJ_IS_LITTLE_ENDIAN", to: "1"),
                .define("PJ_IS_BIG_ENDIAN", to: "0"),
            ],
            linkerSettings: [
                .linkedLibrary("resolv"),
                .linkedLibrary("c++"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AudioUnit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Foundation"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
            ]
        ),
        .target(name: "OpenlineCore"),
        .target(
            name: "OpenlineStore",
            dependencies: ["OpenlineCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "OpenlineSIP", dependencies: ["OpenlineCore", "OpenlineBridge"]),
        .target(name: "OpenlineKit", dependencies: ["OpenlineCore", "OpenlineStore"]),
        .executableTarget(
            name: "openline-agent",
            dependencies: ["OpenlineCore", "OpenlineStore", "OpenlineSIP", "OpenlineKit"]
        ),
        .testTarget(name: "OpenlineCoreTests", dependencies: ["OpenlineCore"]),
        .testTarget(name: "OpenlineStoreTests", dependencies: ["OpenlineStore"]),
        .testTarget(name: "OpenlineKitTests", dependencies: ["OpenlineKit"]),
    ],
    swiftLanguageModes: [.v6]
)
