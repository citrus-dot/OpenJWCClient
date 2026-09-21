// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenJWCCore",
    platforms: [
        // D6：iOS 18 baseline（Liquid Glass 为 26 增强，属 UI 层决策）；
        // macOS 15 支撑 Tahoe 升级前的域层开发（阶段 1–3 全部 swift test 驱动）。
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "OpenJWCCore", targets: ["OpenJWCCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
        .package(url: "https://github.com/scinfu/SwiftSoup", from: "2.8.0"),
    ],
    targets: [
        .target(
            name: "OpenJWCCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ]
        ),
        .testTarget(name: "OpenJWCCoreTests", dependencies: ["OpenJWCCore"]),
    ]
)
