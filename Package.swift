// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "AeroGrid", platforms: [.macOS(.v14)], products: [
    .executable(name: "AeroGrid", targets: ["AeroGrid"]),
], targets: [
    .target(name: "GridCore"),
    .executableTarget(name: "AeroGrid", dependencies: ["GridCore"]),
    .testTarget(name: "GridCoreTests", dependencies: ["GridCore"], resources: [.copy("Fixtures")]),
], swiftLanguageModes: [.v5])
