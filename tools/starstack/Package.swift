// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StarStack", platforms: [.macOS("27.0")],
    products: [.executable(name: "starstack", targets: ["starstack"]),
               .executable(name: "nativebench", targets: ["nativebench"]),
               .executable(name: "meteorprep", targets: ["meteorprep"]),
               .executable(name: "meanmetal", targets: ["meanmetal"]),
               .library(name: "StarStackCore", targets: ["StarStackCore"])],
    targets: [.target(name: "StarStackCore"),
              .executableTarget(name: "starstack", dependencies: ["StarStackCore"]),
              .executableTarget(name: "meteorprep", dependencies: ["StarStackCore"]),
              .executableTarget(name: "meanmetal", dependencies: ["StarStackCore"],resources:[.copy("Mean.metal")]),
              .executableTarget(name: "nativebench", dependencies: ["StarStackCore"], resources: [.copy("Kernels.metal")]),
              .testTarget(name: "StarStackCoreTests", dependencies: ["StarStackCore"])],
    swiftLanguageModes: [.v5]
)
