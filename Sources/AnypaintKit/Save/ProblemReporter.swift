import AppKit

/// 把「使用者按了按鈕但事情沒成」講出來的單一出口。
///
/// 為什麼需要它：`PinboardService.copy` 是「先清空剪貼簿、再寫入」，寫入失敗時剪貼簿已經空了，
/// 而框選在呼叫複製之前就已經 dismiss（`SelectionOverlayController.finish` 先 dismiss 再呼叫
/// handler），所以畫面上不會留下任何可以顯示 toast 的地方。既有的失敗回饋只有
/// `NSSound.beep()`——只有聲音、沒有說明，使用者無從判斷是自己這邊沒複製到，還是貼上那邊的問題。
///
/// **不要在 RPC（CFMessagePort callback）路徑上呼叫這個方法**：`runModal` 會卡死整條自動化通道
/// （同 `startRecord` 不進互動式權限詢問的理由，見 `docs/automation.md`）。自動化路徑要把結果
/// 放進事件 payload 讓呼叫端自己判斷。
@MainActor
public enum ProblemReporter {
    /// 顯示一則說明並發出提示音。accessory app 平時不是前景，先 activate 否則警示可能被蓋住。
    public static func report(_ what: String, detail: String) {
        NSSound.beep()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = what
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// 複製失敗的固定文案。剪貼簿在失敗當下已經被清空，所以「貼上會沒東西」是事實陳述。
    public static func reportCopyFailed() {
        report("複製沒有成功",
               detail: "剪貼簿現在是空的，貼上不會有東西。請再截一次。")
    }

    /// 有選區但擷取不出影像（原本會靜默關掉框選，什麼都不複製也不說）。
    public static func reportCropFailed() {
        report("這個選區沒有擷取成功",
               detail: "沒有複製也沒有存檔。請重新拉一次選區，範圍不要超出螢幕邊緣。")
    }
}
