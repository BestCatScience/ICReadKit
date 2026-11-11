// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ICReadKit",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "ICReadKit", targets: ["ICReadKit"])
    ],
    targets: [
        .target(name: "ICReadKit"),
        .testTarget(name: "ICReadKitTests", dependencies: ["ICReadKit"]),
    ]
)
