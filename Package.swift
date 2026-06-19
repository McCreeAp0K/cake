// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cake",
    platforms: [
        .macOS(.v14)   // 目标平台：macOS 14 Sonoma+
    ],
    targets: [
        .executableTarget(
            name: "Cake",
            path: "Sources/Cake"
        )
    ]
)
