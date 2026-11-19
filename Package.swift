// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "PhotoAI",
    platforms: [
        .macOS(.v27)
    ],
    products: [
        .library(name: "PhotoAICore", targets: ["PhotoAICore"]),
        .executable(name: "PhotoAIApp", targets: ["PhotoAIApp"]),
        .executable(name: "photoai", targets: ["photoai"])
    ],
    targets: [
        .target(
            name: "PhotoAICore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "PhotoAIApp", dependencies: ["PhotoAICore"]),
        .executableTarget(name: "photoai", dependencies: ["PhotoAICore"]),
        .testTarget(name: "PhotoAICoreTests", dependencies: ["PhotoAICore"])
    ]
)
