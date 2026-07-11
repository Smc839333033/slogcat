// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Slogcat",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Slogcat",
            path: "Sources/Slogcat"
        )
    ]
)
