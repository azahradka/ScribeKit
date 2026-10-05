// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ScribeKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ScribeKit", targets: ["ScribeKit"]),
        .executable(name: "scribe", targets: ["scribe"]),
    ],
    dependencies: [
        // No traits: leaves out the prebuilt NemoTextProcessing binary, which ScribeKit does not use.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4", traits: []),
    ],
    targets: [
        .target(
            name: "ScribeKit",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .executableTarget(
            name: "scribe",
            dependencies: ["ScribeKit"]
        ),
        .testTarget(
            name: "ScribeKitTests",
            dependencies: ["ScribeKit"]
        ),
    ]
)
