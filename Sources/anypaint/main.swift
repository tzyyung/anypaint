import AppKit
import AnypaintKit

// SwiftPM executable 的進入點：手動建立 NSApplication。
// 設成 .accessory 讓它是選單列常駐 app（無 Dock 圖示），
// 即使直接跑執行檔（未透過 .app bundle 的 LSUIElement）也一致。
//
// MainActor.assumeIsolated：main.swift 的 top-level code 在此 target 的 Swift 5 language
// mode 下不會自動視為 @MainActor（該預設隔離是 Swift 6 mode 的行為），但這段程式碼本來就
// 全程跑在主執行緒（executable 進入點，尚未 app.run() 前不存在其他執行緒）——用
// assumeIsolated 讓編譯器接受呼叫 AppDelegate()（Task 14 起因為持有 @MainActor 的
// ScrollCaptureSession/ScrollPreviewWindowController 而整個 class 標了 @MainActor）。
// 已查證：assumeIsolated 是 Swift concurrency 官方 API，若實際不在 MainActor 上執行會在
// debug 觸發 assertion——此處由「executable 尚未 app.run()」的既有事實保證安全。
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
