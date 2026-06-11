// swift-tools-version:5.9
// E2E sample manifest. The dependency pin and the frozen tags of the fixture
// repo make the expected result deterministic: exactly one minor update to
// 1.2.3 (2.0.0-beta.1 is a pre-release, 2.0.0 is above the major constraint).
import PackageDescription

let package = Package(
    name: "E2EManifest",
    products: [],
    dependencies: [
        .package(url: "https://github.com/hbmartin/spm-action-e2e-fixture", from: "1.0.0"),
    ],
    targets: []
)
