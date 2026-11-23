// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DittoMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DittoMac", targets: ["DittoMac"]),
        .library(name: "DittoCore", targets: ["DittoCore"]),
    ],
    targets: [
        .target(
            name: "DittoCore",
            path: "Sources/DittoCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "DittoMac",
            dependencies: ["DittoCore"],
            path: "Sources/DittoMac",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Network"),
                .linkedFramework("CoreImage"),
            ]
        ),
        .testTarget(
            name: "DittoCoreTests",
            dependencies: ["DittoCore"],
            path: "Tests/DittoCoreTests"
        ),
    ]
)
