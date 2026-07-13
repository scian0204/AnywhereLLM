// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AnywhereLLM",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AnywhereLLM", path: "Sources/AnywhereLLM")
    ]
)
