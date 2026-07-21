// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "anypaint",
    platforms: [
        .macOS(.v14)  // ScreenCaptureKit 的 SCScreenshotManager.captureImage 需要 macOS 14+
    ],
    dependencies: [
        // 全域快鍵 + 錄製 UI；底層同樣是 Carbon RegisterEventHotKey（免輔助使用權限）。
        // 釘在 1.15.x：1.16.0 起在 SwiftUI Recorder.swift 用了 #Preview 巨集，
        // 需要 Xcode 的 PreviewsMacros plugin，純 Command Line Tools 編不過。1.15.0 API 一致。
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", "1.15.0"..<"1.16.0")
    ],
    targets: [
        // 核心邏輯與 UI 模組（可被 app 與 self-test 共用）
        .target(
            name: "AnypaintKit",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Sources/AnypaintKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 實際的 app 執行檔（僅進入點）
        .executableTarget(
            name: "anypaint",
            dependencies: ["AnypaintKit"],
            path: "Sources/anypaint",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 純邏輯的自我測試執行檔（純 Command Line Tools 環境也能跑：swift run anypaint-selftest）
        .executableTarget(
            name: "anypaint-selftest",
            dependencies: ["AnypaintKit"],
            path: "Sources/anypaint-selftest",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
