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

    // RecordMath.videoBitrate（原 WriterBox.init 內嵌公式）
    // 1920×1080 H.264：2073600*3.75*0.9 = 6998400
    T.checkEq("bitrate: 1080p H.264", RecordMath.videoBitrate(pixelWidth: 1920, pixelHeight: 1080, useHEVC: false), 6_998_400)
    // HEVC 是 H.264 的一半
    T.checkEq("bitrate: HEVC=H264 的一半",
              RecordMath.videoBitrate(pixelWidth: 1920, pixelHeight: 1080, useHEVC: true), 3_499_200)
    // 極小尺寸吃 20 萬下限
    T.checkEq("bitrate: 小尺寸吃下限 200k", RecordMath.videoBitrate(pixelWidth: 16, pixelHeight: 16, useHEVC: false), 200_000)

    // RecordMath.parseRecordDuration（原 RecordHUD.durationSeconds）
    T.checkTrue("duration: 空白→nil", RecordMath.parseRecordDuration("") == nil)
    T.checkTrue("duration: 非整數→nil", RecordMath.parseRecordDuration("2.5") == nil)
    T.checkTrue("duration: 0→nil", RecordMath.parseRecordDuration("0") == nil)
    T.checkTrue("duration: 負→nil", RecordMath.parseRecordDuration("-3") == nil)
    T.checkEq("duration: 5→5", RecordMath.parseRecordDuration("5"), 5)
    T.checkEq("duration: 700→夾到600", RecordMath.parseRecordDuration("700"), 600)
    T.checkEq("duration: 含空白 ' 8 '→8", RecordMath.parseRecordDuration(" 8 "), 8)

    // RecordMath.nextPeak（原 LevelMeterView peak-hold）
    T.checkEq("nextPeak: 更高→更新", RecordMath.nextPeak(bars: 8, currentPeak: 5), 8)
    T.checkEq("nextPeak: 相等→保持", RecordMath.nextPeak(bars: 5, currentPeak: 5), 5)
    T.checkEq("nextPeak: 更低→衰減一格", RecordMath.nextPeak(bars: 2, currentPeak: 5), 4)
    T.checkEq("nextPeak: 已在0→不為負", RecordMath.nextPeak(bars: 0, currentPeak: 0), 0)

    // RecordMath.clampedExportDuration（原 GifExporter.prepareReader）
    // 請求 5s、母帶 10s、範圍起點 3s → min(5, 10-3=7)=5
    T.checkEq("exportDur: 請求短於剩餘→請求", RecordMath.clampedExportDuration(requested: 5, assetDuration: 10, rangeStart: 3), 5)
    // 請求 8s 超過剩餘 7s → 夾到 7
    T.checkEq("exportDur: 請求超剩餘→夾到剩餘", RecordMath.clampedExportDuration(requested: 8, assetDuration: 10, rangeStart: 3), 7)

    // RecordMath.outputPointLength（原 GifExporter 像素→點）
    T.checkEq("outLen: 2880px@2x→1440", RecordMath.outputPointLength(pixels: 2880, pointScale: 2), 1440)
    T.checkEq("outLen: 四捨五入", RecordMath.outputPointLength(pixels: 5, pointScale: 2), 3)   // 2.5→3
    T.checkEq("outLen: 下限 1", RecordMath.outputPointLength(pixels: 1, pointScale: 10), 1)

    // MicSilenceTracker：連續靜音達 threshold 秒才警告,一有訊號立即清除
    var tracker = MicSilenceTracker()
    T.checkTrue("silence: t=0 靜音開始→尚未警告", !tracker.update(rms: 0.0001, now: 0, threshold: 2))
    T.checkTrue("silence: t=1 仍靜音<2s→不警告", !tracker.update(rms: 0.0001, now: 1, threshold: 2))
    T.checkTrue("silence: t=2 連續靜音達 2s→警告", tracker.update(rms: 0.0001, now: 2, threshold: 2))
    // 有訊號立即清除,silentSince 歸 nil
    T.checkTrue("silence: 有訊號→不警告", !tracker.update(rms: 0.05, now: 3, threshold: 2))
    T.checkTrue("silence: 有訊號後 silentSince 清除", tracker.silentSince == nil)
    // 重新靜音要重新累計 2s
    T.checkTrue("silence: 重新靜音 t=3→重新計時,不警告", !tracker.update(rms: 0.0001, now: 3, threshold: 2))
    T.checkTrue("silence: t=4 才 1s<2s→不警告", !tracker.update(rms: 0.0001, now: 4, threshold: 2))
    T.checkTrue("silence: t=5 達 2s→警告", tracker.update(rms: 0.0001, now: 5, threshold: 2))
}
