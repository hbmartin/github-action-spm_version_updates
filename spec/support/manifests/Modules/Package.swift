// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Modules",
    products: [],
    dependencies: [
        .package(url: "https://github.com/onevcat/Kingfisher", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.2.3"),
        .package(url: "https://github.com/kean/Nuke", "12.0.0"..<"13.0.0"),
        .package(url: "https://github.com/hbmartin/analytics-swift.git", branch: "main"),
        // Temporarily disabled while we evaluate alternatives:
        // .package(url: "https://github.com/some/disabled", from: "1.0.0"),
        .package(
            url: "https://github.com/getsentry/sentry-cocoa.git",
            revision: "14aa6e47b03b820fd2b338728637570b9e969994"
        ),
        .package(path: "../LocalOnly"),
    ],
    targets: []
)
