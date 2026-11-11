// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ICReadKitXcodeGenTool",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "xcodegen", targets: ["XcodeGenBinary"])
    ],
    targets: [
        .binaryTarget(
            name: "XcodeGenBinary",
            url: "https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.artifactbundle.zip",
            checksum: "ef6d0a23bfb7393387f98e321ffd78a487231172e2e78c48d3c26275c263fd0c"
        )
    ]
)
