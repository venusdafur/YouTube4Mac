// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YouTube4Mac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "YouTube4Mac",
            targets: ["YouTube4Mac"]
        )
    ],
    targets: [
        .executableTarget(
            name: "YouTube4Mac"
        )
    ]
)
