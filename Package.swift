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
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.10.0"
        ),
        .package(
            url: "https://github.com/ml-explore/mlx-swift",
            exact: "0.32.3"
        ),
        .package(
            url: "https://github.com/facebook/zstd",
            exact: "1.5.7"
        ),
    ],
    targets: [
        .executableTarget(
            name: "WhisprGo",
            dependencies: [
                "AtomicSupport",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "libzstd", package: "zstd"),
            ],
            path: "Sources/WhisprGo",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
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
