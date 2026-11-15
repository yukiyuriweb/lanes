// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Lanes",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Lanes", path: "Sources/Lanes")
    ],
    swiftLanguageModes: [.v5]
)
