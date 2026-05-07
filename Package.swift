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
    ],
    targets: [
        .executableTarget(
            name: "Rocky",
            dependencies: [
                "RockyKit", "Telemetry", "SidecarHost", "RobotLink",
                "RockyVision", "Voice", "Cognition", "Perception",
            ],
            path: "Sources/Rocky",
            exclude: []
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
            dependencies: ["RockyKit", "Telemetry"],
            path: "Sources/Cognition"
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
