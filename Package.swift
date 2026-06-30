// swift-tools-version:5.9
import PackageDescription

// Audeon: a native macOS audio routing and monitoring app.
// Builds an executable that hosts a SwiftUI app and a CoreAudio routing engine.
let package = Package(
    name: "Audeon",
    platforms: [
        // macOS 13 covers the AVAudioEngine routing engine used in v1.
        // Per-application process taps (roadmap) require macOS 14.2+.
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Audeon",
            path: "Sources/Audeon"
        )
    ]
)
