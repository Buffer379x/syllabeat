// swift-tools-version: 6.0
// M0-Spike: Baut der GitHub-Runner „xcode-27“ die ML-Abhängigkeiten von 0.3.0?
import PackageDescription

let package = Package(
    name: "CIProbe",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.32.3"),
    ],
    targets: [
        .executableTarget(name: "CIProbe", dependencies: [
            .product(name: "WhisperKit", package: "WhisperKit"),
            .product(name: "MLXVLM", package: "mlx-swift-lm"),
        ]),
        .testTarget(name: "CIProbeTests"),
    ]
)
