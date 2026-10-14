// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "macrx",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .target(
            name: "MacrxCore",
            dependencies: ["TOMLKit"]
        ),
        .executableTarget(
            name: "macrx",
            dependencies: ["MacrxCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(
            name: "MacrxCoreTests",
            dependencies: ["MacrxCore"]
        ),
    ]
)
