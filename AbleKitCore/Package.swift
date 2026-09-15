// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AbleKitCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AbleKitCore", targets: ["AbleKitCore"])
    ],
    targets: [
        .target(
            name: "AbleKitCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AbleKitCoreTests",
            dependencies: ["AbleKitCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
