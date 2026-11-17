// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BetterT3Notch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BetterT3Notch",
            path: "Sources/BetterT3Notch",
            linkerSettings: [.linkedLibrary("sqlite3")] // EditStats: live +/- from T3's local store
        ),
        .testTarget(
            name: "BetterT3NotchTests",
            dependencies: ["BetterT3Notch"],
            path: "Tests/BetterT3NotchTests"
        ),
    ]
)
