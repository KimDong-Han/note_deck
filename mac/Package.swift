// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NoteDeck",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "NoteDeckCore", path: "Sources/NoteDeckCore"),
        .executableTarget(name: "NoteDeck", dependencies: ["NoteDeckCore"], path: "Sources/NoteDeck"),
        .executableTarget(name: "notedeck-cli", dependencies: ["NoteDeckCore"], path: "Sources/notedeck-cli"),
    ]
)
