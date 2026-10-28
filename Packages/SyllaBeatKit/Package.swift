// swift-tools-version: 6.0
// Fachlogik von SyllaBeat. Die App, der Inferenzdienst und sbtool nutzen dieselben Bibliotheken.
import PackageDescription

let package = Package(
    name: "SyllaBeatKit",
    defaultLocalization: "de",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SyllaBeatCore", targets: ["SyllaBeatCore"]),
        .library(name: "SyllaBeatAI", targets: ["SyllaBeatAI"]),
        .executable(name: "sbtool", targets: ["sbtool"]),
    ],
    targets: [
        .target(name: "SyllaBeatCore"),
        .target(name: "SyllaBeatAI", dependencies: ["SyllaBeatCore"]),
        .executableTarget(name: "sbtool", dependencies: ["SyllaBeatCore"]),
        .testTarget(name: "SyllaBeatCoreTests", dependencies: ["SyllaBeatCore"]),
        .testTarget(name: "SyllaBeatAITests", dependencies: ["SyllaBeatAI"]),
    ]
)
