import AnypaintKit
import CoreGraphics

/// GuidanceMessage.displayText/tone（原內嵌在 ScrollHUD 的 text/tone，抽回 model 後可測）
/// + SelectionGeometry.hudOrigin（ScrollHUD/RecordHUD 共用定位）。
nonisolated func scrollGuidanceDisplayTests() {
    // displayText：逐字（spec §10）＋帶參數
    T.checkEq("guidance text: progress 帶 px", GuidanceMessage.progress(px: 1234).displayText, "已拼接 1234 px")
    T.checkEq("guidance text: slowDown", GuidanceMessage.slowDown.displayText, "捲慢一點，重疊區太少")
    T.checkEq("guidance text: selectionTooSmall", GuidanceMessage.selectionTooSmall.displayText, "選區高度不足，拉高一點才能開始")
    // 全 case 都有非空文案（新增 case 忘了補會 crash/空——這裡巡不到 associated value 的全部，
    // 但列舉常見無參數者確保非空）
    let cases: [GuidanceMessage] = [.slowDown, .gapNotStitched, .mouseOutside, .selectionTooSmall,
        .backscrollTrimming, .backscrollAtOrigin, .hardToMatch, .bottomProbing, .deadReckoning,
        .confirmBottomByBackscroll, .progress(px: 0)]
    T.checkTrue("guidance text: 全列舉非空", cases.allSatisfy { !$0.displayText.isEmpty })

    // tone：警告黃 / 錯誤紅 / 中性
    T.checkEq("guidance tone: slowDown=warning", GuidanceMessage.slowDown.tone, .warning)
    T.checkEq("guidance tone: hardToMatch=warning", GuidanceMessage.hardToMatch.tone, .warning)
    T.checkEq("guidance tone: gapNotStitched=error", GuidanceMessage.gapNotStitched.tone, .error)
    T.checkEq("guidance tone: progress=neutral", GuidanceMessage.progress(px: 5).tone, .neutral)
    T.checkEq("guidance tone: mouseOutside=neutral（提醒級非警告）", GuidanceMessage.mouseOutside.tone, .neutral)

    // SelectionGeometry.hudOrigin
    let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let panel = CGSize(width: 340, height: 56)
    // 選區在畫面中央,下方有空間 → HUD 在選區下緣外 12pt、水平置中
    let sel = CGRect(x: 400, y: 400, width: 200, height: 100)   // midX500, minY400
    let o1 = SelectionGeometry.hudOrigin(selection: sel, panelSize: panel, visibleFrame: visible)
    T.checkEq("hudOrigin: 水平置中", o1.x, 500 - 170)
    T.checkEq("hudOrigin: 選區下緣外 12", o1.y, 400 - 56 - 12)
    // 選區貼近底部（下方放不下）→ 翻到上緣外
    let selLow = CGRect(x: 400, y: 5, width: 200, height: 100)   // minY5 maxY105
    let o2 = SelectionGeometry.hudOrigin(selection: selLow, panelSize: panel, visibleFrame: visible)
    T.checkEq("hudOrigin: 下方放不下→翻到上緣外", o2.y, 105 + 12)
    // 貼左邊選區 → 水平 clamp 不出畫面
    let selLeft = CGRect(x: 0, y: 400, width: 40, height: 100)   // midX20
    let o3 = SelectionGeometry.hudOrigin(selection: selLeft, panelSize: panel, visibleFrame: visible)
    T.checkTrue("hudOrigin: 貼邊 clamp 不出左界", o3.x >= 0)
    // 貼滿可視高度的選區（上下都放不下）→ 垂直 clamp 進可視區,控制列不跑出畫面（審查 #5）
    let selTall = CGRect(x: 400, y: 5, width: 200, height: 790)   // minY5 maxY795,幾乎滿高
    let o4 = SelectionGeometry.hudOrigin(selection: selTall, panelSize: panel, visibleFrame: visible)
    T.checkTrue("hudOrigin: 貼滿高選區→垂直 clamp 進可視區", o4.y >= 0 && o4.y + panel.height <= 800)

    // ScrollStitchOutcome.isWaiting
    T.checkTrue("isWaiting: waitingForMotion", ScrollStitchOutcome.waitingForMotion.isWaiting)
    T.checkTrue("isWaiting: awaitingOverlap", ScrollStitchOutcome.awaitingOverlap(pendingDy: 5).isWaiting)
    T.checkTrue("isWaiting: appended 不是等待", !ScrollStitchOutcome.appended(dy: 10, totalHeight: 100).isWaiting)
    T.checkTrue("isWaiting: rejected 不是等待", !ScrollStitchOutcome.rejected(consecutiveFailures: 3).isWaiting)

    // ScrollCoords.meetsMinPixelHeight（原 enterArmed 內嵌:點→像素換算再比 320）
    // Retina scale 2：160pt=320px 剛好過；159pt=318px 不過（而非誤用點比 320 把門檻抬成 640px）
    T.checkTrue("minHeight: Retina 160pt=320px 過", ScrollCoords.meetsMinPixelHeight(heightPoints: 160, scale: 2))
    T.checkTrue("minHeight: Retina 159pt=318px 不過", !ScrollCoords.meetsMinPixelHeight(heightPoints: 159, scale: 2))
    // 300pt 合格選區（600px）在 Retina 下必過——回歸「600px 被誤擋」的 bug
    T.checkTrue("minHeight: 300pt(600px) 過（回歸）", ScrollCoords.meetsMinPixelHeight(heightPoints: 300, scale: 2))
    // 非 Retina scale 1：320pt=320px 過
    T.checkTrue("minHeight: scale1 320pt 過", ScrollCoords.meetsMinPixelHeight(heightPoints: 320, scale: 1))
    T.checkTrue("minHeight: scale1 319pt 不過", !ScrollCoords.meetsMinPixelHeight(heightPoints: 319, scale: 1))

    // ScrollSelfCheckMath.parseDouble
    T.checkEq("parseArg: 命中", ScrollSelfCheckMath.parseDouble(["x", "--step=24.5"], prefix: "--step="), 24.5)
    T.checkTrue("parseArg: 找不到→nil", ScrollSelfCheckMath.parseDouble(["x"], prefix: "--step=") == nil)
    T.checkTrue("parseArg: 非數字→nil", ScrollSelfCheckMath.parseDouble(["--step=abc"], prefix: "--step=") == nil)

    // ScrollSelfCheckMath.verdict：達成率 0.9~1.1 且 appended>1 才 PASS
    // base 100 + 40 步 ×24 ×2 = 2020;實得 2020 → ratio 1.0 → PASS
    let vOK = ScrollSelfCheckMath.verdict(firstFrameHeight: 100, totalSteps: 40, stepPoints: 24, scale: 2,
                                          actualHeight: 2020, appendedFrameCount: 40)
    T.checkEq("verdict: 預期高", vOK.expected, 2020)
    T.checkTrue("verdict: 達成率 100% → PASS", vOK.pass)
    // 拼太多（203%）→ FAIL（上限也卡）
    let vOver = ScrollSelfCheckMath.verdict(firstFrameHeight: 100, totalSteps: 40, stepPoints: 24, scale: 2,
                                            actualHeight: 4100, appendedFrameCount: 40)
    T.checkTrue("verdict: 拼太多→FAIL", !vOver.pass)
    // 拼太少（45%）→ FAIL
    let vUnder = ScrollSelfCheckMath.verdict(firstFrameHeight: 100, totalSteps: 40, stepPoints: 24, scale: 2,
                                             actualHeight: 900, appendedFrameCount: 40)
    T.checkTrue("verdict: 拼太少→FAIL", !vUnder.pass)
    // appended≤1 → FAIL（就算高度剛好）
    let vNoAppend = ScrollSelfCheckMath.verdict(firstFrameHeight: 100, totalSteps: 40, stepPoints: 24, scale: 2,
                                                actualHeight: 2020, appendedFrameCount: 1)
    T.checkTrue("verdict: 沒真的拼→FAIL", !vNoAppend.pass)

    // ScrollCoords.sampledMeanFirstChannel
    T.checkEq("meanLuma: 空 buffer→-1", ScrollCoords.sampledMeanFirstChannel([]), -1)
    // 全 200 的 buffer → 抽樣平均 ≈200（分母 count/stride 與實際取樣數差 1,原演算法固有,±1 內）
    T.checkTrue("meanLuma: 定值 ≈200",
                abs(ScrollCoords.sampledMeanFirstChannel([UInt8](repeating: 200, count: 4000), stridePixels: 1) - 200) <= 1)
    T.checkEq("meanLuma: 全 0 → 0", ScrollCoords.sampledMeanFirstChannel([UInt8](repeating: 0, count: 800), stridePixels: 1), 0)
}
