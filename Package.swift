// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Veil",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Veil",
            path: "Sources/Veil",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
