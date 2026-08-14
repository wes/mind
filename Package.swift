// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mind",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Mind",
            path: "Sources/Mind",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MindIconGen",
            path: "Sources/MindIconGen",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
