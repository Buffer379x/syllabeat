// swift-tools-version: 6.0
// Fachlogik von SyllaBeat. Die App, der Inferenzdienst und sbtool nutzen dieselben Bibliotheken.
import PackageDescription

let package = Package(
    name: "SyllaBeatKit",
    defaultLocalization: "de",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SyllaBeatCore", targets: ["SyllaBeatCore"]),
        .library(name: "SyllaBeatMedia", targets: ["SyllaBeatMedia"]),
        .library(name: "SyllaBeatAudio", targets: ["SyllaBeatAudio"]),
        .library(name: "SyllaBeatUI", targets: ["SyllaBeatUI"]),
        .library(name: "SyllaBeatAI", targets: ["SyllaBeatAI"]),
        .library(name: "SyllaBeatModels", targets: ["SyllaBeatModels"]),
        .library(name: "SyllaBeatMLX", targets: ["SyllaBeatMLX"]),
        .executable(name: "sbtool", targets: ["sbtool"]),
    ],
    dependencies: [
        // Tokenizer für SigLIP 2 (Apache 2.0); exakt gepinnt wie im Spike M0.
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.5"),
        // Transkription mit Wortzeiten (MIT); exakt gepinnt wie im Spike M0.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
        // Lokale Sprach- und Bildmodelle (MIT); exakt gepinnt wie im Spike M0 und in der CI-Probe.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.32.3"),
    ],
    targets: [
        .target(name: "SyllaBeatCore"),
        .target(name: "SyllaBeatMedia", dependencies: ["SyllaBeatCore"]),
        .target(name: "SyllaBeatAudio", dependencies: ["SyllaBeatCore"]),
        .target(name: "SyllaBeatUI", dependencies: ["SyllaBeatCore", "SyllaBeatAudio"]),
        .target(name: "SyllaBeatAI", dependencies: ["SyllaBeatCore"]),
        .target(
            name: "SyllaBeatModels",
            dependencies: [
                "SyllaBeatCore", .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]),
        .target(
            name: "SyllaBeatMLX",
            dependencies: [
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]),
        .executableTarget(
            name: "sbtool",
            dependencies: [
                "SyllaBeatCore", "SyllaBeatMedia", "SyllaBeatAudio", "SyllaBeatModels", "SyllaBeatUI", "SyllaBeatAI",
            ]),
        .testTarget(name: "SyllaBeatCoreTests", dependencies: ["SyllaBeatCore"]),
        .testTarget(name: "SyllaBeatMediaTests", dependencies: ["SyllaBeatMedia"]),
        .testTarget(name: "SyllaBeatAudioTests", dependencies: ["SyllaBeatAudio"]),
        .testTarget(name: "SyllaBeatAITests", dependencies: ["SyllaBeatAI"]),
    ]
)
