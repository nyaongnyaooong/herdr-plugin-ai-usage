// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIUsageHerdr",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ai-usage-herdr", targets: ["AIUsageHerdr"])
    ],
    targets: [
        .target(
            name: "AIUsageCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "AIUsageHerdrKit",
            dependencies: ["AIUsageCore"]
        ),
        .executableTarget(
            name: "AIUsageHerdr",
            dependencies: ["AIUsageHerdrKit"]
        ),
        .testTarget(
            name: "AIUsageHerdrTests",
            dependencies: ["AIUsageHerdrKit"]
        )
    ]
)
