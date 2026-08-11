import AppKit
import AnypaintKit

/// 剪貼簿酬載測試。
///
/// 為什麼要測這件事：`writeObjects([NSImage])` 只註冊 `public.tiff`，而 TIFF 未壓縮
/// ——全螢幕 Retina 選區實測 20.5 MB。剪貼簿的每個觀察者都要整份讀一次。
/// 這組測試鎖住「放上去的是 PNG、尺寸不跑掉、只認 TIFF 的接收端仍拿得到」三條規則，
/// 不鎖任何具體位元組數（那會隨編碼器版本漂移）。
///
/// 一律用**具名剪貼簿**，不動 `NSPasteboard.general`——測試不該清掉使用者的剪貼簿。
private let testPasteboard = NSPasteboard(name: NSPasteboard.Name("anypaint.selftest.pasteboard"))

/// 造一張「像截圖」的圖：大片白底＋文字般的細節條。像素尺寸與點數尺寸差 2 倍（模擬 Retina）。
private func makeTestImage(pixelWidth: Int, pixelHeight: Int, scale: CGFloat) -> NSImage {
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    let ctx = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                        bytesPerRow: 0, space: srgb, bitmapInfo: info)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
    for row in stride(from: 20, to: max(21, pixelHeight - 20), by: 34) {
        var x = 40
        while x < pixelWidth - 80 {
            let seg = 6 + (x * 7 + row) % 22
            ctx.fill(CGRect(x: x, y: row, width: seg, height: 13))
            x += seg + 8
        }
    }
    let cg = ctx.makeImage()!
    return NSImage(cgImage: cg, size: NSSize(width: CGFloat(pixelWidth) / scale,
                                             height: CGFloat(pixelHeight) / scale))
}

/// 一個剪貼簿觀察者（通用剪貼簿、遠端桌面同步工具）會掃到的總量：
/// 每個 item 宣告的每個型別各讀一次。按需合成的型別不在 `item.types` 裡，不會被算進來。
private func declaredBytes(_ pb: NSPasteboard) -> Int {
    (pb.pasteboardItems ?? []).reduce(0) { sum, item in
        sum + item.types.reduce(0) { $0 + (item.data(forType: $1)?.count ?? 0) }
    }
}

func pasteboardPayloadTests() {
    let scale: CGFloat = 2
    let image = makeTestImage(pixelWidth: 2880, pixelHeight: 1864, scale: scale)

    // 對照組：現行做法放上去有多大
    testPasteboard.clearContents()
    testPasteboard.writeObjects([image])
    let tiffOnlyBytes = declaredBytes(testPasteboard)

    guard let item = PinboardService.imageItem(for: image) else {
        T.checkTrue("imageItem 對 CGImage 撐著的 NSImage 應該成功", false)
        return
    }

    T.checkTrue("imageItem 宣告 public.png", item.types.contains(.png))
    T.checkTrue("imageItem 不自己宣告 public.tiff（未壓縮的那份不該進酬載）",
                !item.types.contains(.tiff))

    testPasteboard.clearContents()
    testPasteboard.writeObjects([item])
    let pngBytes = declaredBytes(testPasteboard)

    // 只鎖「明顯變小」這條規則。實測文字類截圖是 0.6%、隨機雜訊最壞情況 13.4%，
    // 門檻放在 25% 以留編碼器版本差異的餘裕。
    T.checkTrue("PNG 酬載明顯小於 TIFF（實測門檻 25%）",
                tiffOnlyBytes > 0 && pngBytes * 4 < tiffOnlyBytes)

    // 尺寸不跑掉：少了 PNG 的 DPI，接收端會把 Retina 圖當成兩倍大。
    let readBack = NSImage(pasteboard: testPasteboard)
    T.checkEq("讀回的點數尺寸與原圖相同（Retina 貼上不會變兩倍大）",
              readBack?.size, image.size)
    T.checkEq("讀回的像素尺寸沒被縮",
              (readBack?.representations.first as? NSBitmapImageRep)
                  .map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) },
              CGSize(width: 2880, height: 1864))

    // 只認 TIFF 的舊接收端：macOS 會按需從 PNG 合成，不必我們自己放。
    T.checkTrue("只認 TIFF 的接收端仍拿得到（macOS 按需合成）",
                testPasteboard.data(forType: .tiff) != nil)

    // 降級路徑：取不到點陣資料就回 nil，讓呼叫端退回舊做法，不要靜默弄丟複製。
    T.checkEq("imageItem 對沒有點陣表現的 NSImage 回 nil（呼叫端據此降級）",
              PinboardService.imageItem(for: NSImage(size: NSSize(width: 10, height: 10))), nil)

    // 非 Retina（scale=1）：點數＝像素，不該被硬塞 2 倍 DPI
    let flat = makeTestImage(pixelWidth: 800, pixelHeight: 600, scale: 1)
    testPasteboard.clearContents()
    if let flatItem = PinboardService.imageItem(for: flat) {
        testPasteboard.writeObjects([flatItem])
        T.checkEq("scale=1 的圖點數尺寸不變", NSImage(pasteboard: testPasteboard)?.size, flat.size)
    } else {
        T.checkTrue("scale=1 的圖也應該打包成功", false)
    }

    testPasteboard.clearContents()
}

/// 下游往返：截圖複製 → 貼圖（讀剪貼簿）→ OCR／存檔。
/// 改成放 PNG 之後，這條路上每個接手的人拿到的東西都得跟以前一樣。
func pasteboardRoundTripTests() {
    let image = makeTestImage(pixelWidth: 1200, pixelHeight: 800, scale: 2)
    guard let item = PinboardService.imageItem(for: image) else {
        T.checkTrue("往返測試前置：imageItem 應該成功", false); return
    }
    testPasteboard.clearContents()
    testPasteboard.writeObjects([item])

    // 貼圖讀剪貼簿走的就是這個呼叫（對齊 PinboardService.imageFromPasteboard）
    let pinned = (testPasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.first
    T.checkTrue("貼圖讀得到剪貼簿影像", pinned != nil)
    // 貼圖視窗依點數尺寸開，尺寸錯了視窗就錯
    T.checkEq("貼圖拿到的點數尺寸與截圖時相同", pinned?.size, image.size)

    // 貼圖視窗的 OCR 走 cgImage(forProposedRect:)，要拿到全解析度像素
    var proposed = CGRect(origin: .zero, size: pinned?.size ?? .zero)
    let ocrSource = pinned?.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    T.checkEq("OCR 取得的是全解析度像素（不是點數）",
              ocrSource.map { CGSize(width: $0.width, height: $0.height) },
              CGSize(width: 1200, height: 800))

    // 存檔鏈的 NSImage 版走 tiffRepresentation，PNG 撐著的 NSImage 也要能存
    if let pinned {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("anypaint-selftest-roundtrip-\(UUID().uuidString).png")
        let wrote = (try? CaptureSaver.writePNG(image: pinned, to: tmp)) != nil
        T.checkTrue("PNG 撐著的 NSImage 仍存得出檔（存檔鏈走 tiffRepresentation）", wrote)
        if wrote {
            let reread = NSImage(contentsOf: tmp)
            T.checkEq("存出來的檔案像素尺寸沒縮",
                      (reread?.representations.first as? NSBitmapImageRep)
                          .map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) },
                      CGSize(width: 1200, height: 800))
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    // 廣色域：擷取來源在 P3 螢幕上是 Display P3，PNG 往返不得把色域換掉。
    // 這裡比對的是**色彩空間本身**——比對「轉到 sRGB 後的像素值」沒有鑑別力
    // （P3 的飽和紅夾進 sRGB 兩邊都是 255,0,0）。
    if let p3 = CGColorSpace(name: CGColorSpace.displayP3),
       let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                           space: p3,
                           bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                       | CGBitmapInfo.byteOrder32Little.rawValue) {
        ctx.setFillColor(CGColor(colorSpace: p3, components: [1, 0, 0, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let cg = ctx.makeImage()!
        testPasteboard.clearContents()
        if let p3Item = PinboardService.imageItem(for: cg, pointSize: NSSize(width: 32, height: 32)) {
            testPasteboard.writeObjects([p3Item])
            let back = NSImage(pasteboard: testPasteboard)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
            T.checkEq("Display P3 往返後色彩空間不變",
                      back?.colorSpace?.name as String?, cg.colorSpace?.name as String?)
        } else {
            T.checkTrue("P3 圖也應該打包成功", false)
        }
    }

    testPasteboard.clearContents()
}
