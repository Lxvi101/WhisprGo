// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WhisprGo",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "WhisprGo", targets: ["WhisprGo"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift",
            from: "1.0.0"
        ),
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.5"
        ),
    ],
    targets: [
        .executableTarget(
            name: "WhisprGo",
            dependencies: [
                "AtomicSupport",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/WhisprGo"
        ),
        .target(
            name: "AtomicSupport",
            path: "Sources/AtomicSupport",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "WhisprGoTests",
            dependencies: ["WhisprGo"],
            path: "Tests/WhisprGoTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
