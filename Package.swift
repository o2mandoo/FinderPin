// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FinderPin",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FinderPin",
            path: "Sources/FinderPin",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
