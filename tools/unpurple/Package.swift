// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Unpurple",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "unpurple", targets: ["unpurple"]),
        .library(name: "UnpurpleCore", targets: ["UnpurpleCore"])
    ],
    targets: [
        .target(name: "UnpurpleCore", resources: [.copy("Unpurple.metal"), .copy("UnpurpleFloat.metal"), .copy("LICENSE.upstream")]),
        .executableTarget(name: "unpurple", dependencies: ["UnpurpleCore"]),
        .testTarget(name: "UnpurpleCoreTests", dependencies: ["UnpurpleCore"])
    ]
)
