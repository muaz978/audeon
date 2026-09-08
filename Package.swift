// swift-tools-version:6.0
import PackageDescription

// Audeon: a native macOS audio routing and monitoring app.
// Builds an executable that hosts a SwiftUI app and a CoreAudio routing engine.
//
// The tools version is what selects the Swift 6 language mode, so strict
// concurrency checking is on by default for every target rather than being
// something a developer has to remember to pass. Getting here took four passes:
// the diagnostics it turns into errors found a use-after-free in the driver, a
// recorder that could be fed by two audio threads at once, and a route that
// outlived the device it played to.
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
        ),
        .testTarget(
            name: "AudeonTests",
            dependencies: ["Audeon"],
            path: "Tests/AudeonTests"
        )
    ]
)
