// swift-tools-version: 6.0
import PackageDescription

// Essais: one notebook to write in, day after day.
let package = Package(
    name: "Essais",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Updates: checks docs/appcast.xml on the website and offers new releases.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Essais",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Essais",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // build.sh copies Sparkle.framework into Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
