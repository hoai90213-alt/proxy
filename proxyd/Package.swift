// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LuminaProxyDaemon",
    platforms: [
        .macOS(.v13),
        .iOS(.v15)
    ],
    products: [
        .executable(name: "LuminaProxyDaemon", targets: ["LuminaProxyDaemon"])
    ],
    targets: [
        .executableTarget(
            name: "LuminaProxyDaemon",
            path: "Sources/LuminaProxyDaemon"
        )
    ]
)

