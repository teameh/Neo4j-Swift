// swift-tools-version:4.0
import PackageDescription

let package = Package(
    name: "Theo",
    products: [
        .library(name: "Theo", targets: ["Theo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/teameh/Bolt-swift.git", .branch("1.0.2-swift-tools-4")),
        .package(url: "https://github.com/antitypical/Result.git", from: "5.0.0")
    ],
    targets: [
        .target(
            name: "Theo",
            dependencies: ["Bolt", "Result"]),
        .testTarget(
            name: "TheoTests",
            dependencies: ["Theo"]),
    ]
)
