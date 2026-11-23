// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingCopilot",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "MeetingCopilot",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
