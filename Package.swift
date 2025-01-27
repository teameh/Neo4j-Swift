// swift-tools-version:5.0
import PackageDescription

let package = Package(
    name: "Theo",
	platforms: [
	        .macOS(.v10_14),
	        .iOS(.v12),
	        .tvOS(.v12)
	    ],
    products: [
        .library(name: "Theo", targets: ["Theo"])
    ],
    dependencies: [
        .package(url: "https://github.com/Neo4j-Swift/Bolt-swift.git", .branch("master"))
        /*.package(url: "https://github.com/lukaskubanek/LoremSwiftum.git", .revision("6c6018aec1c61a40c2aa06a68eb843ce42bca262")),*/
    ],
    targets: [
        .target(
            name: "Theo",
            dependencies: ["Bolt"]),
        .testTarget(
            name: "TheoTests",
            dependencies: ["Theo" /* "LoremSwiftum" */])
    ]
)
