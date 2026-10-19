// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MajsoulHelper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MajsoulHelper", targets: ["MajsoulHelper"])
    ],
    dependencies: [
        // Sparkle：Mac App Store 外分发的事实标准更新框架（2026-10-16 集成）。
        // 集成要点见 scripts/build_app.sh 的 Sparkle 段与 docs/更新发布.md。
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "MajsoulHelper",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/MajsoulHelper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
