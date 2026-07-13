// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AnywhereLLM",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LLMCore", path: "Sources/LLMCore"),
        .executableTarget(
            name: "AnywhereLLM",
            dependencies: ["LLMCore"],
            path: "Sources/AnywhereLLM"
        ),
        .testTarget(
            name: "LLMCoreTests",
            dependencies: ["LLMCore"],
            path: "Tests/LLMCoreTests"
        ),
    ]
)
