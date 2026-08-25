// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ANAWatcher",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ANAWatcher", targets: ["ANAWatcher"])
    ],
    targets: [
        .executableTarget(
            name: "ANAWatcher",
            path: "Sources/ANAWatcher"
        )
    ]
)
