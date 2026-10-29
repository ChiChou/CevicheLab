// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Chromatic",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "chromatic", targets: ["chromatic"]),
        .library(name: "ChromaticCore", targets: ["ChromaticCore"])
    ],
    targets: [
        .target(name: "ChromaticCore", resources: [.copy("Chromatic.metal"), .copy("LICENSE.upstream")]),
        .executableTarget(name: "chromatic", dependencies: ["ChromaticCore"]),
        .testTarget(name: "ChromaticCoreTests", dependencies: ["ChromaticCore"])
    ]
)
