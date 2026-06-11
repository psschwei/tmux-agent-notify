// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "tmux-agent-notify",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "NotifyCore"),
        .executableTarget(
            name: "notifyctl",
            dependencies: ["NotifyCore"]
        ),
        .executableTarget(
            name: "notifyd",
            dependencies: ["NotifyCore"]
        ),
        .testTarget(
            name: "NotifyCoreTests",
            dependencies: ["NotifyCore"]
        ),
    ]
)
