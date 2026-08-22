import AppKit
import AnypaintKit

/// 複製結果回報測試。
///
/// 背景：`writeObjects` 會回 `Bool`，而 `copy(image:)` 是「先 `clearContents()` 清空、再寫入」
/// ——寫入失敗時剪貼簿已經被清空，使用者按了「複製」卻什麼都貼不出來，畫面上零跡象。
/// 這組測試鎖兩條規則：失敗要**重試一次**（`writeObjects` 回 false 多半是別的行程在清空與
/// 寫入之間插隊，有文獻：alacritty#5824），以及**兩次都失敗必須回報失敗**讓呼叫端能告知使用者。
private let copyTestPasteboard = NSPasteboard(name: NSPasteboard.Name("anypaint.selftest.copyoutcome"))

func pasteboardCopyOutcomeTests() {
    // 1) 第一次就成功 → 不重試
    var calls = 0
    var outcome = PinboardService.attemptWrite { _ in calls += 1; return true }
    T.checkEq("第一次成功 → ok", outcome, .ok)
    T.checkEq("第一次成功就不再試", calls, 1)

    // 2) 第一次失敗、第二次成功 → 整體成功（這正是間歇性插隊的情況）
    calls = 0
    outcome = PinboardService.attemptWrite { _ in calls += 1; return calls == 2 }
    T.checkEq("第一次失敗第二次成功 → ok", outcome, .ok)
    T.checkEq("失敗後確實重試了一次", calls, 2)

    // 3) 兩次都失敗 → 必須回報失敗（呼叫端要據此提示使用者）
    calls = 0
    outcome = PinboardService.attemptWrite { _ in calls += 1; return false }
    T.checkEq("兩次都失敗 → failed", outcome, .failed)
    T.checkEq("不會無限重試", calls, 2)

    // 4) 真的寫一張圖進剪貼簿：回 ok，且剪貼簿確實拿得到 PNG
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8,
                        bytesPerRow: 0, space: srgb, bitmapInfo: info)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
    let image = NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: 100, height: 50))

    T.checkEq("writeImage 正常影像 → ok",
              PinboardService.writeImage(image, to: copyTestPasteboard), .ok)
    T.checkTrue("寫完剪貼簿真的有 PNG", copyTestPasteboard.data(forType: .png) != nil)
    T.checkEq("點數尺寸沒跑掉", NSImage(pasteboard: copyTestPasteboard)?.size, image.size)

    copyTestPasteboard.clearContents()
}
