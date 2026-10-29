// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TheOneRingPlanner",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "TheOneRingPlanner", targets: ["RingPlanner"])],
    targets: [
        .target(name: "RingCore"),
        .executableTarget(name: "RingPlanner", dependencies: ["RingCore"], resources: [.process("Assets")]),
        .executableTarget(name: "RingCoreChecks", dependencies: ["RingCore"], path: "Tests/RingCoreTests")
    ]
)
