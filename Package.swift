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
        .target(
            name: "DomovyCore",
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
