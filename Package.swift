// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "UURemoteKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "UURemoteKit", targets: ["UURemoteKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.39.0"),
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "157.0.0"),
    ],
    targets: [
        .target(
            name: "UURemoteKit",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "WebRTC", package: "WebRTC"),
            ]
        ),
        .testTarget(
            name: "UURemoteKitTests",
            dependencies: ["UURemoteKit"]
        ),
    ]
)
