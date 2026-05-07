// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Rocky",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Rocky", targets: ["Rocky"]),
        .library(name: "RockyKit", targets: ["RockyKit"]),
        .library(name: "Telemetry", targets: ["Telemetry"]),
        .library(name: "SidecarHost", targets: ["SidecarHost"]),
        .library(name: "RobotLink", targets: ["RobotLink"]),
        .library(name: "RockyVision", targets: ["RockyVision"]),
        .library(name: "Voice", targets: ["Voice"]),
        .library(name: "Cognition", targets: ["Cognition"]),
        .library(name: "Perception", targets: ["Perception"]),
        .library(name: "Memory", targets: ["Memory"]),
    ],
    dependencies: [
        // Loads .gltf models for SceneKit. Used by ReachyHead3D to drive
        // the live robot-pose avatar. Maintained by Warren Moore.
        .package(url: "https://github.com/warrenm/GLTFKit2.git",
                 from: "0.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "Rocky",
            dependencies: [
                "RockyKit", "Telemetry", "SidecarHost", "RobotLink",
                "RockyVision", "Voice", "Cognition", "Perception", "Memory",
                .product(name: "GLTFKit2", package: "GLTFKit2"),
            ],
            path: "Sources/Rocky",
            exclude: [],
            resources: [
                .copy("Resources/Reachy_head.gltf"),
            ]
        ),
        .target(
            name: "RockyKit",
            path: "Sources/RockyKit"
        ),
        .target(
            name: "Telemetry",
            dependencies: ["RockyKit"],
            path: "Sources/Telemetry"
        ),
        .target(
            name: "SidecarHost",
            dependencies: ["RockyKit", "Telemetry"],
            path: "Sources/SidecarHost"
        ),
        .target(
            name: "RobotLink",
            dependencies: ["RockyKit", "Telemetry"],
            path: "Sources/RobotLink"
        ),
        .target(
            name: "RockyVision",
            dependencies: ["RockyKit", "Telemetry", "SidecarHost", "RobotLink"],
            path: "Sources/Vision"
        ),
        .target(
            name: "Voice",
            dependencies: ["RockyKit", "Telemetry", "SidecarHost", "RobotLink"],
            path: "Sources/Voice"
        ),
        .target(
            name: "Cognition",
            dependencies: ["RockyKit", "Telemetry", "Memory"],
            path: "Sources/Cognition"
        ),
        .target(
            name: "Memory",
            dependencies: ["RockyKit", "Telemetry", "SidecarHost"],
            path: "Sources/Memory"
        ),
        .target(
            name: "Perception",
            dependencies: ["RockyKit", "Telemetry", "RobotLink", "RockyVision"],
            path: "Sources/Perception"
        ),
        .testTarget(
            name: "RockyKitTests",
            dependencies: ["RockyKit"],
            path: "Tests/RockyKitTests"
        ),
        .testTarget(
            name: "RobotLinkTests",
            dependencies: ["RobotLink", "RockyKit"],
            path: "Tests/RobotLinkTests"
        ),
        .testTarget(
            name: "SidecarHostTests",
            dependencies: ["SidecarHost"],
            path: "Tests/SidecarHostTests"
        ),
        .testTarget(
            name: "VisionTests",
            dependencies: ["RockyVision", "SidecarHost", "Telemetry", "RockyKit"],
            path: "Tests/VisionTests"
        ),
        .testTarget(
            name: "VoiceTests",
            dependencies: ["Voice", "Telemetry", "RockyKit"],
            path: "Tests/VoiceTests"
        ),
        .testTarget(
            name: "CognitionTests",
            dependencies: ["Cognition", "Telemetry", "RockyKit"],
            path: "Tests/CognitionTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
