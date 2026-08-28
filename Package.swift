// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "WireRoute",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "WireGuardKit", targets: ["WireGuardKit"]),
        .library(name: "WireRouteCore", targets: ["WireRouteCore"]),
        .library(name: "RouterOSKit", targets: ["RouterOSKit"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "WireGuardKit",
            dependencies: ["WireGuardKitGo", "WireGuardKitC"]
        ),
        .target(
            name: "WireGuardKitC",
            dependencies: [],
            publicHeadersPath: "."
        ),
        .target(
            name: "WireGuardKitGo",
            dependencies: [],
            exclude: [
                "goruntime-boottime-over-monotonic.diff",
                "go.mod",
                "go.sum",
                "api-apple.go",
                "Makefile"
            ],
            publicHeadersPath: ".",
            linkerSettings: [.linkedLibrary("wg-go")]
        ),
        .target(name: "WireRouteCore"),
        .target(name: "RouterOSKit"),
        .testTarget(name: "WireRouteCoreTests", dependencies: ["WireRouteCore"]),
        .testTarget(name: "RouterOSKitTests", dependencies: ["RouterOSKit"])
    ]
)
