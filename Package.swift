// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CCUsageBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CCUsageBar", targets: ["CCUsageBar"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "1.9.4")
    ],
    targets: [
        .executableTarget(
            name: "CCUsageBar",
            dependencies: [
                "KeyboardShortcuts"
            ],
            path: "CCUsageBar/CCUsageBar",
            exclude: [
                "Assets.xcassets",
                "CCUsageBar.entitlements"
            ],
            swiftSettings: [
                .unsafeFlags(["-default-isolation", "MainActor"])
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
