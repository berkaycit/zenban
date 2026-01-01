// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GhosttySwift",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "GhosttySwift",
            targets: ["GhosttySwift"]
        ),
    ],
    dependencies: [
        .package(path: "../GhosttyKit"),
    ],
    targets: [
        .target(
            name: "GhosttySwift",
            dependencies: ["GhosttyKit"],
            path: "Sources/GhosttySwift"
        ),
    ]
)
