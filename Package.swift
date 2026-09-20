// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "gowa",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "gowa",
            path: "Sources/gowa"
        ),
        .testTarget(
            name: "gowaTests",
            dependencies: ["gowa"],
            path: "Tests/gowaTests"
        )
    ]
)
