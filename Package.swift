// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CleanerCRTV",
    platforms: [.macOS("26.0")],
    targets: [
        // Lógica sem interface: varreduras, regras, remoção segura. Testável.
        .target(
            name: "CleanerCore",
            path: "Sources/CleanerCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "CleanerCRTV",
            dependencies: ["CleanerCore"],
            path: "Sources/CleanerCRTV",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CleanerCoreTests",
            dependencies: ["CleanerCore"],
            path: "Tests/CleanerCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
