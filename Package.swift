// swift-tools-version:5.9
import PackageDescription
// Package exists only so `swift test` can run the core logic; the app builds from the Xcode project.
let package = Package(
    name: "PlannerCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    targets: [
        .target(name: "PlannerCore", path: "Sources/PlannerCore"),
        .testTarget(name: "PlannerCoreTests", dependencies: ["PlannerCore"], path: "Tests/PlannerCoreTests"),
    ]
)
