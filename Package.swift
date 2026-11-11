// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cans",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "BMAP"),
        .executableTarget(name: "Cans", dependencies: ["BMAP"]),
        .testTarget(name: "BMAPTests", dependencies: ["BMAP"]),
    ]
)
