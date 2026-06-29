// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "agent-signaller",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "SignalerCore"
        ),
        .executableTarget(
            name: "SignalerCLI",
            dependencies: ["SignalerCore"]
        ),
        .executableTarget(
            name: "SignalerApp",
            dependencies: ["SignalerCore"]
        ),
    ]
)
