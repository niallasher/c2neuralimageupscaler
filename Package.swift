// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "C2NeuralUpscaler",
    platforms: [
        .iOS(.v15),
        .visionOS(.v1),
        .macOS(.v12)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "C2NeuralUpscaler",
            targets: ["C2NeuralUpscaler"]),
    ],
    targets: [
        .target(name: "C2PlatformIndependentImage"),
        .target(name: "C2NeuralUpscaler",
                dependencies: ["C2PlatformIndependentImage"]),
    ]
)
