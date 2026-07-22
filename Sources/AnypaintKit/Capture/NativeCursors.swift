import AppKit

/// 載入 macOS 原生游標資源（`cursor.pdf` + `info.plist` 的 hotspot），讓 resize 游標
/// 與系統完全一致、四個方向風格統一。這不是私有 API，只是讀系統框架裡 world-readable
/// 的資源檔（app 非 sandbox 可讀）；找不到就回 nil 由呼叫端 fallback。
enum NativeCursors {
    private static let base = "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Resources/cursors"

    static func load(_ name: String) -> NSCursor? {
        let dir = "\(base)/\(name)"
        guard let image = NSImage(contentsOfFile: "\(dir)/cursor.pdf"),
              let info = NSDictionary(contentsOfFile: "\(dir)/info.plist"),
              let hotx = (info["hotx"] as? NSNumber)?.doubleValue,
              let hoty = (info["hoty"] as? NSNumber)?.doubleValue
        else { return nil }
        return NSCursor(image: image, hotSpot: NSPoint(x: hotx, y: hoty))
    }
}
