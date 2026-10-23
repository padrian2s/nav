// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Nav",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Nav",
            path: "Sources/Nav",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
