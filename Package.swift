// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "macfan",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MacFanCore", targets: ["MacFanCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "MacFanCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "macfan-cli",
            dependencies: [
                "MacFanCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
