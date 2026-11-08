// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "redact_names",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "redact_names",
            dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .testTarget(name: "redact_namesTests", dependencies: ["redact_names"]),
    ]
)
