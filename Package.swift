// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "gowa",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams", from: "6.2.0")
    ],
    targets: [
        .executableTarget(
            name: "gowa",
            dependencies: ["Yams"],
            path: "Sources/gowa"
        ),
        .testTarget(
            name: "gowaTests",
            dependencies: ["gowa"],
            path: "Tests/gowaTests"
        )
    ]
)
