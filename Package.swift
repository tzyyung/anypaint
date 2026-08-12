// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "anypaint",
    platforms: [
        .macOS(.v15)  // ScreenCaptureKit captureMicrophone／SCRecordingOutput 需要 macOS 15+
    ],
    dependencies: [
        // 本機 vendored（見 vendored/KeyboardShortcuts）：patch 過 .localized 修 C1 資源崩潰；
        // 版本已因 1.16 的 #Preview 巨集問題釘死 1.15，vendoring 無額外網路依賴。
        .package(path: "vendored/KeyboardShortcuts")
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
        ),
        // CFMessagePort RPC 客戶端 CLI（供 UI 自動化與端到端驗證腳本用，見 UITestServer）
        .executableTarget(
            name: "anypaintctl",
            dependencies: ["AnypaintKit"],
            path: "Sources/anypaintctl",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
