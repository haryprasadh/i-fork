// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "IFork",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "IFork", path: "Sources/IFork")
    ]
)
