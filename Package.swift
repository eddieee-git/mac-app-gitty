// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Gitty",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Gitty", path: "Sources/Gitty")
    ]
)
