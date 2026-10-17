// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Clasificador",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Clasificador",
            path: "Sources/Clasificador",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // AVKit hay que enlazarlo a mano: el autolink solo mete
            // _AVKit_SwiftUI, y sin AVKit el VideoPlayer aborta al no
            // encontrar la clase AVPlayerView.
            linkerSettings: [.linkedFramework("AVKit")]
        )
    ]
)
