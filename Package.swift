// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QwrySDK",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "QwrySDK", targets: ["QwrySDK"])],
    targets: [
        .target(name: "QwrySDK"),
        .testTarget(name: "QwrySDKTests", dependencies: ["QwrySDK"]),
    ]
)
