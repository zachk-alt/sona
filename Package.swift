// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Murmur",
            path: "Sources/Murmur",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
