// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Tidemark",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Tidemark", path: "Sources/Tidemark")
    ]
)
