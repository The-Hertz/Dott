// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Dott",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Dott", path: "Sources/Dott")
    ]
)
