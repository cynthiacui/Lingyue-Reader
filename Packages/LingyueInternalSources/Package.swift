// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LingyueInternalSources",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "LingyueInternalSources", targets: ["LingyueInternalSources"])
    ],
    dependencies: [
        .package(path: "../LingyueCore")
    ],
    targets: [
        .target(
            name: "LingyueInternalSources",
            dependencies: [
                .product(name: "LingyueCore", package: "LingyueCore")
            ],
            path: "Sources/LingyueInternalSources"
        ),
        .testTarget(
            name: "LingyueInternalSourcesTests",
            dependencies: ["LingyueInternalSources"],
            path: "Tests/LingyueInternalSourcesTests"
        )
    ]
)
