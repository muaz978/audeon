// swift-tools-version:5.9
import PackageDescription

// Audeon: a native macOS audio routing and monitoring app.
// Builds an executable that hosts a SwiftUI app and a CoreAudio routing engine.
let package = Package(
    name: "Audeon",
    platforms: [
        // macOS 14 baseline. Per-application process taps require 14.2+ and are
        // guarded at runtime so the rest of the app still works on 14.0/14.1.
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Audeon",
            path: "Sources/Audeon"
        )
    ]
)
