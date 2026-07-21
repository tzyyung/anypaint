import AppKit

/// 負責與系統剪貼簿（NSPasteboard）互動：把截圖寫進去、把圖讀出來貼圖。
/// 單一職責：所有剪貼簿讀寫都集中在這裡。
final class PinboardService {
    private let pasteboard = NSPasteboard.general

    /// 把影像寫入剪貼簿（會清掉舊內容）。
    func copy(image: NSImage) {
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    /// 從剪貼簿讀出影像；沒有影像則回 nil。
    func imageFromPasteboard() -> NSImage? {
        let classes: [AnyClass] = [NSImage.self]
        guard
            let objects = pasteboard.readObjects(forClasses: classes, options: nil) as? [NSImage],
            let image = objects.first
        else {
            return nil
        }
        return image
    }
}
