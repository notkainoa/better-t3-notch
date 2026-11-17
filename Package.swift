// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BetterT3Notch",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"), // in-app updates
    ],
    targets: [
        .executableTarget(
            name: "BetterT3Notch",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/BetterT3Notch",
            linkerSettings: [
                .linkedLibrary("sqlite3"), // EditStats: live +/- from T3's local store
                // build.sh copies Sparkle.framework into the app's Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "BetterT3NotchTests",
            dependencies: ["BetterT3Notch"],
            path: "Tests/BetterT3NotchTests"
        ),
    ]
)
