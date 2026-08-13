import AnypaintKit
import AppKit
import ImageIO
import CoreGraphics

/// AnimationFormat 純格式對應 + Img2webpEngine 變延遲分支 + LevelMeterView.zoneColor + parseRect。
nonisolated func exportFormatTests() {
    // AnimationFormat.fileExtension
    T.checkEq("format: gif→gif", AnimationFormat.gif.fileExtension, "gif")
    T.checkEq("format: apng→png", AnimationFormat.apng.fileExtension, "png")

    // containerProperties：GIF 用 GIF dict + loop 0；APNG 用 PNG dict + loop 0
    let gifC = AnimationFormat.gif.containerProperties
    let gifDict = gifC[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    T.checkTrue("format: GIF 容器用 GIF dict", gifDict != nil)
    T.checkEq("format: GIF loopCount=0（無限循環）", gifDict?[kCGImagePropertyGIFLoopCount] as? Int, 0)
    let apngC = AnimationFormat.apng.containerProperties
    let pngDict = apngC[kCGImagePropertyPNGDictionary] as? [CFString: Any]
    T.checkTrue("format: APNG 容器用 PNG dict", pngDict != nil)
    T.checkEq("format: APNG loopCount=0", pngDict?[kCGImagePropertyAPNGLoopCount] as? Int, 0)
    T.checkTrue("format: GIF 容器不含 PNG dict", gifC[kCGImagePropertyPNGDictionary] == nil)

    // perFrameProperties：逐格 delay 進正確的格式 dict
    let gifF = AnimationFormat.gif.perFrameProperties(delaysSeconds: [0.1, 0.2])
    T.checkEq("format: GIF perFrame 格數", gifF.count, 2)
    let gf0 = gifF[0][kCGImagePropertyGIFDictionary] as? [CFString: Any]
    T.checkEq("format: GIF 第0格 delay=0.1", gf0?[kCGImagePropertyGIFDelayTime] as? Double, 0.1)
    let apngF = AnimationFormat.apng.perFrameProperties(delaysSeconds: [0.05])
    let af0 = apngF[0][kCGImagePropertyPNGDictionary] as? [CFString: Any]
    T.checkEq("format: APNG 第0格 delay=0.05", af0?[kCGImagePropertyAPNGDelayTime] as? Double, 0.05)

    // Img2webpEngine.arguments：等延遲折疊成一個 -d；變延遲每段各一個 -d
    let equal = Img2webpEngine.arguments(delaysMs: [100, 100, 100],
                                         frames: ["a.png", "b.png", "c.png"], output: "o.webp")
    T.checkEq("img2webp: 等延遲只出現一次 -d", equal.filter { $0 == "-d" }.count, 1)
    let varied = Img2webpEngine.arguments(delaysMs: [100, 200],
                                          frames: ["a.png", "b.png"], output: "o.webp")
    T.checkEq("img2webp: 變延遲兩段各一個 -d", varied.filter { $0 == "-d" }.count, 2)
    T.checkTrue("img2webp: 變延遲含 100 與 200", varied.contains("100") && varied.contains("200"))
    T.checkEq("img2webp: 開頭 -loop 0", Array(equal.prefix(2)), ["-loop", "0"])
    T.checkEq("img2webp: 結尾 -o output", Array(varied.suffix(2)), ["-o", "o.webp"])

    // LevelMeterView.zoneColor：最後格紅、倒數第2黃、其餘綠
    T.checkEq("zoneColor: 最後格=紅", LevelMeterView.zoneColor(for: 11, totalBars: 12), NSColor.systemRed)
    T.checkEq("zoneColor: 倒數第2=黃", LevelMeterView.zoneColor(for: 10, totalBars: 12), NSColor.systemYellow)
    T.checkEq("zoneColor: 中段=綠", LevelMeterView.zoneColor(for: 0, totalBars: 12), NSColor.systemGreen)

    // CoordinateUtils.parseRect（原 AppDelegate.parseRect，已搬到純函式家）
    T.checkEq("parseRect: 正常", CoordinateUtils.parseRect("1,2,3,4"), CGRect(x: 1, y: 2, width: 3, height: 4))
    T.checkTrue("parseRect: 含空白容忍", CoordinateUtils.parseRect(" 1 , 2 , 3 , 4 ") == CGRect(x: 1, y: 2, width: 3, height: 4))
    T.checkTrue("parseRect: 欄位不足→nil", CoordinateUtils.parseRect("1,2,3") == nil)
    T.checkTrue("parseRect: 非數字→nil", CoordinateUtils.parseRect("a,b,c,d") == nil)
    T.checkTrue("parseRect: 空字串→nil", CoordinateUtils.parseRect("") == nil)
}
