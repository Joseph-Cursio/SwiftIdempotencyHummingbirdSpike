// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftIdempotencyHummingbirdSpike",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(path: "../../SwiftIdempotency"),
    ],
    targets: [
        .executableTarget(
            name: "SwiftIdempotencyHummingbirdSpike",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "SwiftIdempotency", package: "SwiftIdempotency"),
            ]
        ),
        .testTarget(
            name: "SwiftIdempotencyHummingbirdSpikeTests",
            dependencies: [
                "SwiftIdempotencyHummingbirdSpike",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "SwiftIdempotency", package: "SwiftIdempotency"),
                .product(name: "SwiftIdempotencyTestSupport", package: "SwiftIdempotency"),
            ]
        ),
    ]
)
