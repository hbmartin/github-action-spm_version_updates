// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BuildTools",
    dependencies: [
        .package(url: "https://github.com/SwiftGen/SwiftGenPlugin", .upToNextMajor(from: "6.6.0")),
        .package(url: "https://github.com/nicklockwood/SwiftFormat", .upToNextMinor(from: "0.52.0")),
    ]
)
