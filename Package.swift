// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "gowa",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams", from: "6.2.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2", from: "2.4.4"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport", from: "2.12.0"),
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.39.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl", from: "2.37.6"),
    ],
    targets: [
        .executableTarget(
            name: "gowa",
            dependencies: [
                "Yams",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            path: "Sources/gowa"
        ),
        .testTarget(
            name: "gowaTests",
            dependencies: ["gowa"],
            path: "Tests/gowaTests"
        )
    ]
)
