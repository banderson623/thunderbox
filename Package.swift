// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Thunderbox",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Thunderbox",
            path: "Sources/Thunderbox"
        )
    ]
)
