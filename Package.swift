// swift-tools-version:5.9
import PackageDescription

// DottKit: il motore (memoria, registro, giornata, cura, salute). Solo Foundation: gira anche su Linux, quindi si collauda ovunque.
// Dott: l'app (AppKit/SwiftUI), solo macOS.
var targets: [Target] = [
    .target(name: "DottKit", path: "Sources/DottKit"),
    .testTarget(name: "DottKitTests", dependencies: ["DottKit"], path: "Tests/DottKitTests"),
]
var products: [Product] = [.library(name: "DottKit", targets: ["DottKit"])]

#if os(macOS)
targets.append(.executableTarget(name: "Dott", dependencies: ["DottKit"], path: "Sources/Dott"))
products.append(.executable(name: "Dott", targets: ["Dott"]))
#endif

let package = Package(
    name: "Dott",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
