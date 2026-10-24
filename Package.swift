// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LocalFlow",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LocalFlow",
            path: "Sources/LocalFlow",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
