// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftMOD",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "SwiftMOD", targets: ["SwiftMOD"])
    ],
    targets: [
        .target(name: "SwiftMOD"),
        .testTarget(name: "SwiftMODTests", dependencies: ["SwiftMOD"])
    ],
    swiftLanguageModes: [.v6]
)
