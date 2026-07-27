import AppKit

/// 負責與系統剪貼簿（NSPasteboard）互動：把截圖寫進去、把圖讀出來貼圖。
/// 單一職責：所有剪貼簿讀寫都集中在這裡。
/// public：ScrollPreviewWindowController（public API）的 init 參數用到這個型別，
/// Swift 存取控制要求該型別本身至少與使用它的 public 介面同級。
public final class PinboardService {
    private let pasteboard = NSPasteboard.general

    public init() {}

    /// 把影像寫入剪貼簿（會清掉舊內容）。
    func copy(image: NSImage) {
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    /// 長圖複製：影像＋檔案 URL 雙型別。部分接收端（實測＋社群回報：Electron/Chromium 應用
    /// 如 Slack/Discord/VS Code）對大張圖片走 TIFF 序列化會卡死或逾時拒收（spec §8），
    /// 檔案 URL 是它們的降級路徑——writeObjects 允許同時放多個 writer，各自以自己的型別
    /// 註冊，讀端揀自己認得的那個（已查證 NSPasteboard.writeObjects 官方文件）。
    /// 暫存檔放系統暫存目錄，session 結束不主動清（系統會清）。
    ///
    /// - Parameter scale: 擷取時的 backingScaleFactor。cgImage 是擷取像素；NSImage 的 `size`
    ///   是點數（point）——Retina（scale=2）下若直接拿像素當點數會讓貼到其他 app 的圖顯示成
    ///   兩倍大（對齊 SelectionView.currentCroppedImage 的既有正解：size = 像素 / scale）。
    public func copyLarge(cgImage: CGImage, scale: CGFloat) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let pointSize = NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        let image = NSImage(cgImage: cgImage, size: pointSize)
        var items: [NSPasteboardWriting] = [image]
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("anypaint-scroll-\(ProcessInfo.processInfo.globallyUniqueString).png")
        if (try? CaptureSaver.writePNG(cgImage: cgImage, to: tmp)) != nil {
            items.append(tmp as NSURL)
        }
        pb.writeObjects(items)
    }

    /// 把文字寫入剪貼簿（OCR／QR 結果用）。
    /// 與 `copy(image:)` 一樣會清掉舊內容——複製文字後貼上不該還拿到上一張圖。
    func copy(text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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
