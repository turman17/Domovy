// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Domovy",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DomovyCore", targets: ["DomovyCore"]),
        .executable(name: "domo", targets: ["domo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // Vendored zstd 1.5.7, decompression only (Codex `.jsonl.zst`, Zed threads). See VENDORED.md.
        .target(
            name: "CZstd",
            path: "Sources/CZstd",
            exclude: ["LICENSE", "VENDORED.md"],
            cSettings: [
                .define("ZSTD_DISABLE_ASM"),
                .define("ZSTD_LEGACY_SUPPORT", to: "0"),
            ]
        ),
        .target(
            name: "DomovyCore",
            dependencies: ["CZstd"],
            path: "Sources/DomovyCore"
        ),
        .executableTarget(
            name: "domo",
            dependencies: [
                "DomovyCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/domo"
        ),
        .testTarget(
            name: "DomovyCoreTests",
            dependencies: ["DomovyCore"],
            path: "Tests/DomovyCoreTests"
        ),
    ]
)
