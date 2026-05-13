// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LingyueCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "LingyueCore", targets: ["LingyueCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.7.5")
    ],
    targets: [
        .target(
            name: "LingyueCore",
            dependencies: ["SwiftSoup"],
            path: "Sources/LingyueCore"
        ),
        .testTarget(
            name: "LingyueCoreTests",
            dependencies: ["LingyueCore"],
            path: "Tests/LingyueCoreTests"
        )
    ]
)
