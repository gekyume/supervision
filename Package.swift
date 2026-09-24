// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "Supervision",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Supervision",
            path: "Sources/Supervision",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("EventKit"),
                .linkedFramework("ApplicationServices"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "supervision",
            path: "Sources/cli",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
