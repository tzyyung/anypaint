import AppKit

/// 負責與系統剪貼簿（NSPasteboard）互動：把截圖寫進去、把圖讀出來貼圖。
/// 單一職責：所有剪貼簿讀寫都集中在這裡。
/// public：ScrollPreviewWindowController（public API）的 init 參數用到這個型別，
/// Swift 存取控制要求該型別本身至少與使用它的 public 介面同級。
public final class PinboardService {
    private let pasteboard = NSPasteboard.general

    public init() {}

    /// 把影像打包成剪貼簿項目，**只註冊 PNG**。
    ///
    /// 為什麼不用 `writeObjects([NSImage])`：NSImage 只註冊 `public.tiff`，而 TIFF 未壓縮
    /// ——2880×1864 像素的全螢幕 Retina 選區實測 **20.5 MB**（同一張圖 PNG 是 117 KB，
    /// 隨機雜訊的最壞情況也只有 2.7 MB）。剪貼簿上的每個觀察者都要把宣告的型別整份讀一次
    /// （通用剪貼簿會把內容往其他裝置推、遠端桌面類工具會同步），接收端只拿得到 TIFF 時
    /// 也只能吞那 20 MB。
    ///
    /// 只放 PNG 不會犧牲相容性：**macOS 會在有人索取 `public.tiff` 時即時從 PNG 合成**
    /// （實測 `pasteboard.data(forType: .tiff)` 仍有值），而合成出來的那份不在
    /// `item.types` 裡，所以不會被觀察者掃到。
    ///
    /// `rep.size = image.size` 是必要的，不是多餘賦值：PNG 以它寫入解析度資訊。少了它，
    /// 接收端讀回的點數會等於像素數，Retina 截圖貼到其他 app 會**變成兩倍大**
    /// （與 `SelectionView.currentCroppedImage` 的既有正解同一件事）。
    ///
    /// - Returns: 取不到點陣資料時回 `nil`，呼叫端據此退回舊做法——寧可放大一點的 TIFF，
    ///   也不要靜默弄丟使用者的複製。
    public static func imageItem(for image: NSImage) -> NSPasteboardItem? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return imageItem(for: cg, pointSize: image.size)
    }

    /// 同上，供已經握有 CGImage 的呼叫端用（長圖不必先包成 NSImage）。
    public static func imageItem(for cgImage: CGImage, pointSize: NSSize) -> NSPasteboardItem? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = pointSize
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        return item
    }

    /// 把影像寫入剪貼簿（會清掉舊內容）。
    func copy(image: NSImage) {
        pasteboard.clearContents()
        if let item = Self.imageItem(for: image) {
            pasteboard.writeObjects([item])
        } else {
            pasteboard.writeObjects([image])   // 降級：打包不成也不能讓複製落空
        }
    }

    /// 長圖複製：PNG ＋ 檔案 URL 雙型別。部分接收端（實測＋社群回報：Electron/Chromium 應用
    /// 如 Slack/Discord/VS Code）對大張圖片走 TIFF 序列化會卡死或逾時拒收（spec §8），
    /// 檔案 URL 是它們的降級路徑——writeObjects 允許同時放多個 writer，各自以自己的型別
    /// 註冊，讀端揀自己認得的那個（已查證 NSPasteboard.writeObjects 官方文件）。
    /// 暫存檔放系統暫存目錄，session 結束不主動清（系統會清）。
    ///
    /// 影像那份走 `imageItem`（PNG）而不是 NSImage：長圖可達 30000px，包成 NSImage 放上去
    /// 等於把上百 MB 的未壓縮 TIFF 攤在剪貼簿上——那正是 spec §8 要避開的東西，當初只補了
    /// 檔案 URL 這條降級路徑，巨大的那份一直還在。
    ///
    /// - Parameter scale: 擷取時的 backingScaleFactor。cgImage 是擷取像素；剪貼簿上的點數
    ///   尺寸要除以它——Retina（scale=2）下若直接拿像素當點數會讓貼到其他 app 的圖顯示成
    ///   兩倍大（對齊 SelectionView.currentCroppedImage 的既有正解：size = 像素 / scale）。
    public func copyLarge(cgImage: CGImage, scale: CGFloat) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let pointSize = CoordinateUtils.pointSize(pixelWidth: cgImage.width, pixelHeight: cgImage.height, scale: scale)
        var items: [NSPasteboardWriting] = []
        if let item = Self.imageItem(for: cgImage, pointSize: pointSize) {
            items.append(item)
        } else {
            items.append(NSImage(cgImage: cgImage, size: pointSize))   // 降級：不能讓複製落空
        }
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
