// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AppAudioMixer",
    platforms: [
        .macOS("14.4") // Core Audio process taps (CATapDescription) require 14.4+
    ],
    targets: [
        .executableTarget(
            name: "AppAudioMixer",
            path: "Sources/AppAudioMixer"
        )
    ]
)
