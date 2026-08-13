import AnypaintKit
import CoreGraphics

/// AutomationCapture.cropPlan：非互動截圖的選區→螢幕+像素裁切純幾何。
nonisolated func automationCaptureTests() {
    // 主螢幕 1440×900 點 @2x（原點 0,0），次螢幕在右邊 (1440,0) 1440×900 點 @2x
    let main = AutomationCapture.DisplayGeometry(frameGlobal: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                 pointSize: CGSize(width: 1440, height: 900), scale: 2)
    let right = AutomationCapture.DisplayGeometry(frameGlobal: CGRect(x: 1440, y: 0, width: 1440, height: 900),
                                                  pointSize: CGSize(width: 1440, height: 900), scale: 2)
    let displays = [main, right]

    // 選區 (100,50,200,100) 全在主螢幕 → index 0；本地=選區(原點相同),
    // pixelCropRect：Y 翻轉 (900-50-100=750)*2=1500,x*2=200,寬200*2=400,高100*2=200
    guard let p0 = AutomationCapture.cropPlan(globalRect: CGRect(x: 100, y: 50, width: 200, height: 100), displays: displays) else {
        T.checkTrue("autoCrop: 主螢幕命中", false); return
    }
    T.checkEq("autoCrop: 主螢幕 index 0", p0.index, 0)
    T.checkEq("autoCrop: 像素裁切(Y翻轉×scale)", p0.pixelCrop, CGRect(x: 200, y: 1500, width: 400, height: 200))

    // 選區在右螢幕 (1500,50,200,100) → index 1；本地 x=1500-1440=60
    guard let p1 = AutomationCapture.cropPlan(globalRect: CGRect(x: 1500, y: 50, width: 200, height: 100), displays: displays) else {
        T.checkTrue("autoCrop: 次螢幕命中", false); return
    }
    T.checkEq("autoCrop: 次螢幕 index 1", p1.index, 1)
    T.checkEq("autoCrop: 次螢幕本地×scale x=120", p1.pixelCrop.origin.x, 120)   // (1500-1440)*2

    // 跨螢幕（沒有任一螢幕完整包住）→ nil
    T.checkTrue("autoCrop: 跨螢幕→nil",
                AutomationCapture.cropPlan(globalRect: CGRect(x: 1400, y: 50, width: 100, height: 100), displays: displays) == nil)
    // 完全在螢幕外→nil
    T.checkTrue("autoCrop: 螢幕外→nil",
                AutomationCapture.cropPlan(globalRect: CGRect(x: 5000, y: 50, width: 100, height: 100), displays: displays) == nil)
    // 空螢幕清單→nil
    T.checkTrue("autoCrop: 無螢幕→nil",
                AutomationCapture.cropPlan(globalRect: CGRect(x: 0, y: 0, width: 10, height: 10), displays: []) == nil)
}
