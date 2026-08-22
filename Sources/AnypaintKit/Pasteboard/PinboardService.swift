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

    /// 複製結果。呼叫端據此決定要不要告訴使用者——**失敗不可以是無聲的**：
    /// `copy` 是「先 `clearContents()` 清空、再寫入」，寫入失敗時剪貼簿已經空了，
    /// 使用者按了「複製」卻什麼都貼不出來，而框選已經關掉，畫面上不會留下任何跡象。
    public enum CopyOutcome: Equatable {
        case ok
        case failed
    }

    /// 寫入的重試決策（純邏輯，與 `NSPasteboard` 無關以便測試）。
    ///
    /// 為什麼要重試：`writeObjects` 回 false 的已知成因是**別的行程在我們清空與寫入之間
    /// 取得剪貼簿所有權**（有文獻的實例：alacritty#5824「Unable to store text in clipboard:
    /// NSPasteboard#writeObjects: returned false」）。這種競爭是間歇性的，再試一次多半就成功
    /// ——這也解釋了使用者「多按幾次才成功」的體感。
    ///
    /// - Parameter attempt: 回傳這次寫入是否成功；參數是第幾次嘗試（0 起算）。
    public static func attemptWrite(maxAttempts: Int = 2, _ attempt: (Int) -> Bool) -> CopyOutcome {
        for i in 0..<maxAttempts where attempt(i) { return .ok }
        return .failed
    }

    /// 把影像寫進指定剪貼簿並回報結果（`pasteboard` 可注入以便測試）。
    /// 失敗會重試一次，兩次都失敗才回 `.failed`。
    public static func writeImage(_ image: NSImage, to pasteboard: NSPasteboard) -> CopyOutcome {
        let item = imageItem(for: image)
        return attemptWrite { _ in
            pasteboard.clearContents()
            if let item {
                return pasteboard.writeObjects([item])
            }
            return pasteboard.writeObjects([image])   // 降級：打包不成也不能讓複製落空
        }
    }

    /// 把影像寫入剪貼簿（會清掉舊內容）。
    /// **回傳值必須被檢查**——`.failed` 代表剪貼簿現在是空的，呼叫端要告知使用者。
    @discardableResult
    func copy(image: NSImage) -> CopyOutcome {
        Self.writeImage(image, to: pasteboard)
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
    @discardableResult
    public func copyLarge(cgImage: CGImage, scale: CGFloat) -> CopyOutcome {
        let pb = NSPasteboard.general
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
        return Self.attemptWrite { _ in
            pb.clearContents()
            return pb.writeObjects(items)
        }
    }

    /// 把文字寫入剪貼簿（OCR／QR 結果用）。
    /// 與 `copy(image:)` 一樣會清掉舊內容——複製文字後貼上不該還拿到上一張圖，
    /// 也一樣會在失敗時回 `.failed`（`setString` 同樣有回傳值，失敗時剪貼簿已被清空）。
    @discardableResult
    func copy(text: String) -> CopyOutcome {
        Self.attemptWrite { _ in
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        }
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
