// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Clasificador",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Clasificador",
            path: "Sources/Clasificador",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
