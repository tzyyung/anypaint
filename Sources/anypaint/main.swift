import AppKit
import AnypaintKit

// SwiftPM executable 的進入點：手動建立 NSApplication。
// 設成 .accessory 讓它是選單列常駐 app（無 Dock 圖示），
// 即使直接跑執行檔（未透過 .app bundle 的 LSUIElement）也一致。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
