// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchBrowser",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchBrowser",
            path: "Sources/NotchBrowser"
        ),
        .testTarget(name: "NotchBrowserTests", dependencies: ["NotchBrowser"]),
    ]
)
