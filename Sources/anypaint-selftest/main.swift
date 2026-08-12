import CoreGraphics
import CoreImage      // QR 測試圖（CIQRCodeGenerator）
import Foundation
import AnypaintKit
import AppKit

// 純邏輯的自我測試。純 Command Line Tools 環境沒有 XCTest 執行器，
// 所以用可直接執行的執行檔跑斷言：swift run anypaint-selftest
// 任一失敗會印出並以非零狀態結束（方便日後接 CI）。

// 斷言工具移至 TestHarness.swift（T.*）；保留同名墊片讓既有測試零改動。
// .v6 下 top-level var 隱式 @MainActor（SE-0343），本檔中段 11 處測試 helper 都是
// nonisolated top-level 函式，直接對 @MainActor var 做 += 會報
// "main actor-isolated var 'failures' can not be mutated from a nonisolated context"。
// 用 nonisolated 標記這個 computed property shim（本身只是轉呼叫 T.failures，
// 真正的狀態已在 TestHarness.swift 用 nonisolated(unsafe) 處理過併發豁免），
// 讓 shim 本身不落地在 MainActor 隔離域，呼叫端維持原樣不必逐一改動。
nonisolated var failures: Int {
    get { T.failures }
    set { T.failures = newValue }
}

func check(_ name: String, _ got: CGRect, _ want: CGRect) { T.check(name, got, want) }
func checkEq<V: Equatable>(_ name: String, _ got: V, _ want: V) { T.checkEq(name, got, want) }
func checkTrue(_ name: String, _ cond: Bool) { T.checkTrue(name, cond) }

// 1) 座標翻轉 + Retina 縮放
check(
    "pixelCropRect 翻轉Y並乘scale",
    CoordinateUtils.pixelCropRect(
        selection: CGRect(x: 10, y: 20, width: 100, height: 50),
        displayPointSize: CGSize(width: 200, height: 100),
        scale: 2
    ),
    CGRect(x: 20, y: 60, width: 200, height: 100)
)

// 2) scale = 1，底邊貼齊
check(
    "pixelCropRect scale=1",
    CoordinateUtils.pixelCropRect(
        selection: CGRect(x: 0, y: 0, width: 50, height: 50),
        displayPointSize: CGSize(width: 100, height: 100),
        scale: 1
    ),
    CGRect(x: 0, y: 50, width: 50, height: 50)
)

// 3) 反向拖曳也要正規化成正的寬高
check(
    "rect(from:to:) 正規化負向拖曳",
    CoordinateUtils.rect(from: CGPoint(x: 30, y: 40), to: CGPoint(x: 10, y: 10)),
    CGRect(x: 10, y: 10, width: 20, height: 30)
)

// 4) 看門狗秒數正規化：0=關閉、非0最少60最多600（使用者規則）
checkEq("watchdog 正規化：0 = 關閉", AppSettings.normalizedWatchdogSeconds(0), 0)
checkEq("watchdog 正規化：負值視同關閉", AppSettings.normalizedWatchdogSeconds(-5), 0)
checkEq("watchdog 正規化：1–59 拉到 60", AppSettings.normalizedWatchdogSeconds(30), 60)
checkEq("watchdog 正規化：範圍內不變", AppSettings.normalizedWatchdogSeconds(120), 120)
checkEq("watchdog 正規化：上限 600", AppSettings.normalizedWatchdogSeconds(900), 600)

// 5) 標註幾何：點到線段距離
checkTrue("distance：點在線段上 = 0",
    AnnotationGeometry.distance(from: CGPoint(x: 5, y: 0),
                                toSegmentFrom: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 0)) < 0.001)
checkTrue("distance：垂直距離",
    abs(AnnotationGeometry.distance(from: CGPoint(x: 5, y: 3),
                                    toSegmentFrom: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 0)) - 3) < 0.001)
checkTrue("distance：超出端點 → 到端點的距離",
    abs(AnnotationGeometry.distance(from: CGPoint(x: 14, y: 3),
                                    toSegmentFrom: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 0)) - 5) < 0.001)
checkTrue("distance：零長線段（點）",
    abs(AnnotationGeometry.distance(from: CGPoint(x: 3, y: 4),
                                    toSegmentFrom: .zero, to: .zero) - 5) < 0.001)

// 6) 標註 hitTest / bounds / move
let style = AnnotationStyle(color: .red, lineWidth: 4)
let rectA = Annotation(shape: .rect(CGRect(x: 10, y: 10, width: 20, height: 20)), style: style)
checkTrue("rect hitTest：框內命中", rectA.hitTest(CGPoint(x: 15, y: 15), threshold: 8))
checkTrue("rect hitTest：外緣 threshold 內命中", rectA.hitTest(CGPoint(x: 35, y: 15), threshold: 8))
checkTrue("rect hitTest：遠處不命中", !rectA.hitTest(CGPoint(x: 60, y: 60), threshold: 8))

let lineA = Annotation(shape: .line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0)), style: style)
checkTrue("line hitTest：線附近命中（threshold+線寬/2）", lineA.hitTest(CGPoint(x: 50, y: 9), threshold: 8))
checkTrue("line hitTest：太遠不命中", !lineA.hitTest(CGPoint(x: 50, y: 11), threshold: 8))
checkEq("line bounds：端點正規化", lineA.bounds, CGRect(x: 0, y: 0, width: 100, height: 0))

var movedA = rectA
movedA.move(by: CGVector(dx: 5, dy: -3))
checkEq("move：矩形平移", movedA.bounds, CGRect(x: 15, y: 7, width: 20, height: 20))
checkEq("move：id 不變", movedA.id, rectA.id)

let counterA = Annotation(shape: .counter(center: CGPoint(x: 50, y: 50)), style: style)
checkTrue("counter hitTest：圓心命中", counterA.hitTest(CGPoint(x: 50, y: 50), threshold: 0))
checkTrue("counter bounds：以圓心為中心", counterA.bounds.midX == 50 && counterA.bounds.midY == 50)
checkEq("counter bounds：半徑=8+線寬×2（4pt→32）", counterA.bounds.width, 32)
checkEq("counter bounds：寬高一致", counterA.bounds.height, counterA.bounds.width)

let arrowA = Annotation(shape: .arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0)), style: style)
checkTrue("arrow hitTest：線附近命中", arrowA.hitTest(CGPoint(x: 50, y: 9), threshold: 8))
checkTrue("arrow hitTest：太遠不命中", !arrowA.hitTest(CGPoint(x: 50, y: 11), threshold: 8))
checkEq("arrow bounds：端點正規化", arrowA.bounds, CGRect(x: 0, y: 0, width: 100, height: 0))
var movedArrow = arrowA
movedArrow.move(by: CGVector(dx: 5, dy: -3))
checkEq("arrow move：端點平移", movedArrow.bounds, CGRect(x: 5, y: -3, width: 100, height: 0))

// 7) AnnotationDocument：快照 undo/redo、z-order、序號重編號
let doc = AnnotationDocument()
checkTrue("doc：初始為空", doc.isEmpty && !doc.canUndo && !doc.canRedo)

let a1 = Annotation(shape: .rect(CGRect(x: 0, y: 0, width: 10, height: 10)), style: style)
let a2 = Annotation(shape: .rect(CGRect(x: 20, y: 20, width: 10, height: 10)), style: style)
doc.add(a1)
doc.add(a2)
checkEq("doc：add 兩筆", doc.objects.count, 2)
checkTrue("doc：canUndo", doc.canUndo)

doc.undo()
checkEq("doc：undo 回一筆", doc.objects.count, 1)
checkTrue("doc：undo 後 canRedo", doc.canRedo)
doc.redo()
checkEq("doc：redo 回兩筆", doc.objects.count, 2)

doc.undo()
doc.add(a2)   // undo 後做新操作 → redo 歷史清空
checkTrue("doc：新操作清空 redo", !doc.canRedo)

// 拖曳語意：beginChange 一次 + 多次 updateWithoutSnapshot = 一步 undo
doc.beginChange()
doc.updateWithoutSnapshot(id: a1.id) { $0.move(by: CGVector(dx: 1, dy: 0)) }
doc.updateWithoutSnapshot(id: a1.id) { $0.move(by: CGVector(dx: 1, dy: 0)) }
checkEq("doc：拖曳後位置", doc.objects[0].bounds.minX, 2)
doc.undo()
checkEq("doc：整段拖曳一步復原", doc.objects[0].bounds.minX, 0)

// 熱圖形滾輪調粗細語意（spec 2026-07-22 修訂）：beginChange 一次 +
// 多次 updateWithoutSnapshot 改 lineWidth（模擬整段滾輪調整）→ undo 一步全回，
// 不可每格滾動都 push 快照。
let hotDoc = AnnotationDocument()
let hotA = Annotation(shape: .rect(CGRect(x: 0, y: 0, width: 10, height: 10)),
                      style: AnnotationStyle(color: .red, lineWidth: 4))
hotDoc.add(hotA)
hotDoc.beginChange()
hotDoc.updateWithoutSnapshot(id: hotA.id) { $0.style.lineWidth = 5 }
hotDoc.updateWithoutSnapshot(id: hotA.id) { $0.style.lineWidth = 6 }
hotDoc.updateWithoutSnapshot(id: hotA.id) { $0.style.lineWidth = 8 }
checkEq("熱圖形：多次滾輪調整後 lineWidth", hotDoc.objects[0].style.lineWidth, 8)
checkTrue("熱圖形：整段調整只算一步 undo", hotDoc.canUndo)
hotDoc.undo()
checkEq("熱圖形：一步 undo 全回到調整前", hotDoc.objects[0].style.lineWidth, 4)
// 注意：add(hotA) 本身也是一步 undo，所以這裡 undo 一次後 canUndo 仍為 true
// （還能再 undo 掉「新增」那一步）；這正是驗證「整段滾輪調整只多算一步」的方式。
checkTrue("熱圖形：undo 一次後仍可再 undo 掉新增那一步", hotDoc.canUndo)
hotDoc.undo()
checkTrue("熱圖形：兩步 undo 後document 清空（新增也復原）", hotDoc.isEmpty)
checkTrue("熱圖形：沒有更多步可退", !hotDoc.canUndo)

// z-order：陣列順序即 z-order，越後面越上層
let a3 = Annotation(shape: .rect(CGRect(x: 5, y: 5, width: 10, height: 10)), style: style)
doc.add(a3)
doc.bringToFront(id: a1.id)
checkEq("doc：bringToFront 移到最後", doc.objects.last?.id, a1.id)
doc.sendToBack(id: a1.id)
checkEq("doc：sendToBack 移到最前", doc.objects.first?.id, a1.id)
checkTrue("doc：z-order 可 undo", doc.canUndo)

// hitTest：由上往下（陣列尾端優先）
let top = doc.hitTest(at: CGPoint(x: 7, y: 7), threshold: 0)
checkEq("doc：hitTest 命中最上層", top?.id, doc.objects.last?.id)

// 選取狀態：undo 後清除
doc.selectedID = a1.id
doc.undo()
checkTrue("doc：undo 清除選取", doc.selectedID == nil)

// 序號重編號：編號＝「第幾個 counter」，渲染時算、不存死
let c1 = Annotation(shape: .counter(center: CGPoint(x: 0, y: 0)), style: style)
let c2 = Annotation(shape: .counter(center: CGPoint(x: 10, y: 0)), style: style)
let c3 = Annotation(shape: .counter(center: CGPoint(x: 20, y: 0)), style: style)
let cdoc = AnnotationDocument()
cdoc.add(c1)
cdoc.add(a1)   // 中間夾一個非 counter，不影響編號
cdoc.add(c2)
cdoc.add(c3)
checkEq("counter：第 1 號", cdoc.counterNumber(for: c1.id), 1)
checkEq("counter：第 2 號（跳過非 counter）", cdoc.counterNumber(for: c2.id), 2)
checkEq("counter：第 3 號", cdoc.counterNumber(for: c3.id), 3)
cdoc.remove(id: c2.id)
checkEq("counter：刪 2 號後 3 號變 2 號", cdoc.counterNumber(for: c3.id), 2)
cdoc.undo()
checkEq("counter：undo 恢復編號", cdoc.counterNumber(for: c3.id), 3)
checkTrue("counter：非 counter 無編號", cdoc.counterNumber(for: a1.id) == nil)

// 8) 渲染煙霧測試：離屏 40×40 bitmap 畫一個粗紅框，驗證左緣像素是紅的
func rendererSmokeTest() {
    let w = 40, h = 40
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let a = Annotation(shape: .rect(CGRect(x: 5, y: 5, width: 30, height: 30)),
                       style: AnnotationStyle(color: .red, lineWidth: 6))
    buf.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(
            data: raw.baseAddress, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            failures += 1
            print("❌ renderer 煙霧測試：CGContext 建立失敗")
            return
        }
        AnnotationRenderer.render([a], in: ctx)
    }
    // 取樣 (x=5, 中間列)：正好在左邊框線上。RGBA、列 0 在影像頂端。
    let idx = (20 * w + 5) * 4
    checkTrue("renderer：紅框像素（R 高 G 低 A 滿）",
              buf[idx] > 180 && buf[idx + 1] < 90 && buf[idx + 3] > 200)
    checkTrue("renderer：框中央是空的（沒被填滿）",
              buf[(20 * w + 20) * 4 + 3] == 0)
}
rendererSmokeTest()

// 9) 工具樣式記憶（UserDefaults round-trip，粗細改存 Double）＋ rawValue 往返
AnnotationStyleStore.reset(for: .rect)
checkEq("styleStore：沒存過＝紅色、lineWidth 4",
        AnnotationStyleStore.style(for: .rect),
        AnnotationStyle(color: .red, lineWidth: 4))
AnnotationStyleStore.save(AnnotationStyle(color: .blue, lineWidth: 6), for: .arrow)
checkEq("styleStore：save/load round-trip",
        AnnotationStyleStore.style(for: .arrow),
        AnnotationStyle(color: .blue, lineWidth: 6))
checkEq("styleStore：各工具互不影響",
        AnnotationStyleStore.style(for: .rect),
        AnnotationStyle(color: .red, lineWidth: 4))
checkEq("rawValue：color 往返", AnnotationColor(rawValue: AnnotationColor.green.rawValue), .green)

// 9a) lineWidth clamp（spec：1–24）
checkEq("AnnotationStyle：lineWidth clamp 下限 0→1", AnnotationStyle(color: .red, lineWidth: 0).lineWidth, 1)
checkEq("AnnotationStyle：lineWidth clamp 上限 30→24", AnnotationStyle(color: .red, lineWidth: 30).lineWidth, 24)
AnnotationStyleStore.save(AnnotationStyle(color: .red, lineWidth: 0), for: .line)
checkEq("styleStore：save 也 clamp 下限", AnnotationStyleStore.style(for: .line).lineWidth, 1)
AnnotationStyleStore.save(AnnotationStyle(color: .red, lineWidth: 30), for: .line)
checkEq("styleStore：save 也 clamp 上限", AnnotationStyleStore.style(for: .line).lineWidth, 24)
AnnotationStyleStore.reset(for: .line)

// 9b) 舊三檔字串鍵一次性遷移（spec：thin/medium/thick → 2/4/6）
AnnotationStyleStore.reset(for: .ellipse)
UserDefaults.standard.set("thick", forKey: "annotationStyle.ellipse.thickness")
checkEq("styleStore：舊字串鍵 thick 遷移為 lineWidth 6",
        AnnotationStyleStore.style(for: .ellipse).lineWidth, 6)
AnnotationStyleStore.reset(for: .ellipse)
UserDefaults.standard.set("thin", forKey: "annotationStyle.ellipse.thickness")
checkEq("styleStore：舊字串鍵 thin 遷移為 lineWidth 2",
        AnnotationStyleStore.style(for: .ellipse).lineWidth, 2)
AnnotationStyleStore.reset(for: .ellipse)
UserDefaults.standard.set("medium", forKey: "annotationStyle.ellipse.thickness")
checkEq("styleStore：舊字串鍵 medium 遷移為 lineWidth 4",
        AnnotationStyleStore.style(for: .ellipse).lineWidth, 4)
AnnotationStyleStore.reset(for: .ellipse)   // 清乾淨，避免影響其他測試/重跑

// 9c) 繞過 init 直接改欄位製造越界值 → save() 自身必須 clamp（防未來重構漏掉）
var bypassStyle = AnnotationStyleStore.style(for: .line)
bypassStyle.lineWidth = 999
AnnotationStyleStore.save(bypassStyle, for: .line)
checkEq("styleStore：save 對越界值自行 clamp", AnnotationStyleStore.style(for: .line).lineWidth, 24)
AnnotationStyleStore.reset(for: .line)

// 12) 文字標註：量測、bounds、hitTest、move（量測值依系統字型，斷言相對性質不釘死像素）
let textSize = AnnotationGeometry.measureText("測試文字", fontSize: 20)
checkTrue("text 量測：寬度為正", textSize.width > 0)
checkTrue("text 量測：高度合理（>字級一半）", textSize.height > 10)
checkTrue("text 量測：空字串寬 0", AnnotationGeometry.measureText("", fontSize: 20).width == 0)

let textA = Annotation(shape: .text(origin: CGPoint(x: 10, y: 10), string: "測試文字"),
                       style: AnnotationStyle(color: .red, lineWidth: 4))
checkEq("text 字級規則：12+4×2", textA.textFontSize, 20)
checkTrue("text bounds：origin 在左下", textA.bounds.origin == CGPoint(x: 10, y: 10))
checkTrue("text bounds：尺寸＝量測值", textA.bounds.size == AnnotationGeometry.measureText("測試文字", fontSize: 20))
checkTrue("text hitTest：中心命中", textA.hitTest(CGPoint(x: textA.bounds.midX, y: textA.bounds.midY), threshold: 0))
checkTrue("text hitTest：遠處不中", !textA.hitTest(CGPoint(x: 500, y: 500), threshold: 8))
var movedText = textA
movedText.move(by: CGVector(dx: 5, dy: -3))
checkTrue("text move：origin 平移", movedText.bounds.origin == CGPoint(x: 15, y: 7))

// 10) 合成匯出：白底 + 紅框標註 → 像素驗證（「所見即所存」的離屏版）
func compositeSmokeTest() {
    func solidWhite(w: Int, h: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
    func rgbaBuffer(of img: CGImage) -> [UInt8]? {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }
    guard let source = solidWhite(w: 20, h: 20) else {
        failures += 1; print("❌ composite：白底建立失敗"); return
    }
    // 選取框 (0,0,10,10) 點、scale 2 → 輸出 20×20 像素。
    // 標註：view 座標 rect(2,2,4,4)、中筆（4pt→8px 寬 stroke）紅色。
    let a = Annotation(shape: .rect(CGRect(x: 2, y: 2, width: 4, height: 4)),
                       style: AnnotationStyle(color: .red, lineWidth: 4))
    guard let out = AnnotationRenderer.composite(
            objects: [a], overCropped: source,
            selection: CGRect(x: 0, y: 0, width: 10, height: 10), scale: 2),
          let buf = rgbaBuffer(of: out) else {
        failures += 1; print("❌ composite：合成失敗"); return
    }
    checkEq("composite：輸出尺寸同裁切圖", out.width, 20)
    // 左邊框線：view x=2 → 像素欄 4；view y=4 → CG y=8 → 記憶體列 20-1-8=11
    let redIdx = (11 * 20 + 4) * 4
    checkTrue("composite：標註像素為紅", buf[redIdx] > 180 && buf[redIdx + 1] < 90)
    // 框外（欄 18、列 1）離所有 stroke 帶 ≥2px，仍是白底
    let whiteIdx = (1 * 20 + 18) * 4
    checkTrue("composite：標註外仍是白底",
              buf[whiteIdx] > 200 && buf[whiteIdx + 1] > 200 && buf[whiteIdx + 2] > 200)
}
compositeSmokeTest()

// 10b) 合成匯出：非零原點 selection——驗證 translate 的符號與順序
//（原點 (0,0) 時 translate 是 no-op，錯了也測不出來；這裡補真實情境）
func compositeOffsetTest() {
    func solid(w: Int, h: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
    func rgba(of img: CGImage) -> [UInt8]? {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }
    guard let source = solid(w: 20, h: 20) else {
        failures += 1; print("❌ composite offset：白底建立失敗"); return
    }
    // selection 原點 (30,20)：標註畫在絕對 view 座標 (32,22,4,4)，相對框內位置＝(2,2)。
    // 若 translate 符號寫反、或 scaleBy/translateBy 順序寫反（殘差 selMin×(scale−1)=(30,20)px，
    // 遠大於框線帶寬），標註都會整個偏出 20×20 畫布 → 紅取樣必失敗。
    let a = Annotation(shape: .rect(CGRect(x: 32, y: 22, width: 4, height: 4)),
                       style: AnnotationStyle(color: .red, lineWidth: 4))
    guard let out = AnnotationRenderer.composite(
            objects: [a], overCropped: source,
            selection: CGRect(x: 30, y: 20, width: 10, height: 10), scale: 2),
          let buf = rgba(of: out) else {
        failures += 1; print("❌ composite offset：合成失敗"); return
    }
    let redIdx = (11 * 20 + 4) * 4
    checkTrue("composite offset：非零原點標註像素為紅", buf[redIdx] > 180 && buf[redIdx + 1] < 90)
    let whiteIdx = (1 * 20 + 18) * 4
    checkTrue("composite offset：非零原點框外仍白",
              buf[whiteIdx] > 200 && buf[whiteIdx + 1] > 200 && buf[whiteIdx + 2] > 200)
}
compositeOffsetTest()

// 13) 文字渲染像素：用「█」（實心塊字）保證確定性覆蓋
func textRenderSmokeTest() {
    let w = 60, h = 40
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let a = Annotation(shape: .text(origin: CGPoint(x: 5, y: 5), string: "█"),
                       style: AnnotationStyle(color: .red, lineWidth: 4))   // 字級 20
    buf.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(
            data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        AnnotationRenderer.render([a], in: ctx)
    }
    // 取樣文字框中心（bounds 由量測而來，中心必在 █ 的實心區）
    let cx = Int(a.bounds.midX), cyTop = h - 1 - Int(a.bounds.midY)
    let idx = (cyTop * w + cx) * 4
    checkTrue("text 渲染：█ 中心為紅", buf[idx] > 150 && buf[idx + 3] > 150)
}
textRenderSmokeTest()

// 14) 序號渲染像素：圓身取樣＋counterNumbers 查表 smoke
func counterRenderSmokeTest() {
    let w = 60, h = 60
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let a = Annotation(shape: .counter(center: CGPoint(x: 30, y: 30)),
                       style: AnnotationStyle(color: .blue, lineWidth: 4))   // 半徑 16
    buf.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(
            data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        AnnotationRenderer.render([a], in: ctx, counterNumbers: [a.id: 3])
    }
    // 圓身（中心右偏 10px、避開數字）＝藍；圓外（角落）＝空
    let bodyIdx = ((h - 1 - 30) * w + 40) * 4
    checkTrue("counter 渲染：圓身為藍", buf[bodyIdx + 2] > 150 && buf[bodyIdx] < 90)
    let outIdx = (2 * w + 2) * 4
    checkTrue("counter 渲染：圓外空白", buf[outIdx + 3] == 0)
}
counterRenderSmokeTest()

// 15) composite 帶 counterNumbers 編譯／執行 smoke（簽名回歸防護）
func compositeCounterSmokeTest() {
    guard let src = { () -> CGImage? in
        guard let ctx = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        return ctx.makeImage()
    }() else { failures += 1; print("❌ composite counter：白底失敗"); return }
    let c = Annotation(shape: .counter(center: CGPoint(x: 5, y: 5)),
                       style: AnnotationStyle(color: .red, lineWidth: 1))
    let out = AnnotationRenderer.composite(objects: [c], overCropped: src,
                                           selection: CGRect(x: 0, y: 0, width: 10, height: 10),
                                           scale: 2, counterNumbers: [c.id: 1])
    checkTrue("composite：counterNumbers 參數可用且非 nil", out != nil)
}
compositeCounterSmokeTest()

// 16) 畫筆/螢光筆/馬賽克：平滑路徑、bounds、hitTest、move
checkTrue("smoothedPath：<2 點回 nil", AnnotationGeometry.smoothedPath(points: [CGPoint(x: 1, y: 1)]) == nil)
let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 0)]
if let sp = AnnotationGeometry.smoothedPath(points: pts) {
    checkTrue("smoothedPath：含起點", sp.contains(CGPoint(x: 0, y: 0), using: .winding, transform: .identity)
              || sp.boundingBox.insetBy(dx: -0.1, dy: -0.1).contains(CGPoint(x: 0, y: 0)))
    checkTrue("smoothedPath：boundingBox 涵蓋所有點（外擴避開 max 邊排他）",
              sp.boundingBox.insetBy(dx: -0.1, dy: -0.1).contains(CGPoint(x: 20, y: 0)))
} else { failures += 1; print("❌ smoothedPath：3 點應非 nil") }

let penA = Annotation(shape: .freehand(points: pts), style: AnnotationStyle(color: .red, lineWidth: 4))
checkTrue("freehand bounds：涵蓋點集", penA.bounds.contains(CGPoint(x: 10, y: 10)))
checkTrue("freehand hitTest：線上命中", penA.hitTest(CGPoint(x: 10, y: 10), threshold: 8))
checkTrue("freehand hitTest：遠處不中", !penA.hitTest(CGPoint(x: 10, y: 60), threshold: 8))
var movedPen = penA
movedPen.move(by: CGVector(dx: 5, dy: 5))
checkTrue("freehand move：全點平移", movedPen.bounds.contains(CGPoint(x: 15, y: 15)) && !movedPen.bounds.contains(CGPoint(x: -1, y: -1)))

let hlA = Annotation(shape: .highlighter(points: pts), style: AnnotationStyle(color: .yellow, lineWidth: 4))
checkEq("highlighter 有效寬＝×2", hlA.effectiveStrokeWidth, 8)
checkEq("freehand 有效寬＝原值", penA.effectiveStrokeWidth, 4)

let pxA = Annotation(shape: .pixelate(rect: CGRect(x: 5, y: 5, width: 20, height: 10)), style: AnnotationStyle(color: .red, lineWidth: 4))
checkEq("pixelate bounds＝rect", pxA.bounds, CGRect(x: 5, y: 5, width: 20, height: 10))
checkEq("pixelate 格子＝max(4,lw×2)", pxA.pixelateBlockSize, 8)
checkTrue("pixelate hitTest：框內中", pxA.hitTest(CGPoint(x: 10, y: 10), threshold: 0))
var movedPx = pxA
movedPx.move(by: CGVector(dx: -5, dy: -5))
checkEq("pixelate move", movedPx.bounds.origin, CGPoint.zero)

// 17) 螢光筆渲染：multiply 半透明——白底上偏原色、不全遮
func highlighterRenderSmokeTest() {
    let w = 40, h = 40
    var buf = [UInt8](repeating: 255, count: w * h * 4)   // 白底（先填滿 255）
    let a = Annotation(shape: .highlighter(points: [CGPoint(x: 5, y: 20), CGPoint(x: 35, y: 20)]),
                       style: AnnotationStyle(color: .red, lineWidth: 4))   // 有效寬 8
    buf.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(
            data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        AnnotationRenderer.render([a], in: ctx)
    }
    let idx = ((h - 1 - 20) * w + 20) * 4   // 線中央
    checkTrue("highlighter：紅通道仍高", buf[idx] > 200)
    checkTrue("highlighter：綠通道被壓但未歸零（半透明 multiply）", buf[idx + 1] > 100 && buf[idx + 1] < 240)
}
highlighterRenderSmokeTest()

// 18) 畫筆渲染：平滑筆跡有像素
func freehandRenderSmokeTest() {
    let w = 40, h = 40
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let a = Annotation(shape: .freehand(points: [CGPoint(x: 5, y: 20), CGPoint(x: 20, y: 25), CGPoint(x: 35, y: 20)]),
                       style: AnnotationStyle(color: .blue, lineWidth: 4))
    buf.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(
            data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        AnnotationRenderer.render([a], in: ctx)
    }
    let idx = ((h - 1 - 20) * w + 5) * 4   // 起點附近
    checkTrue("freehand：起點附近為藍", buf[idx + 2] > 150)
}
freehandRenderSmokeTest()

// 19) 馬賽克渲染：紅色底圖 → 馬賽克區仍為紅（非破壞、取樣自 provider）；無 provider＝灰佔位不 crash
func pixelateRenderSmokeTest() {
    func solidRed(w: Int, h: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.13, blue: 0.16, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
    let w = 40, h = 40
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let a = Annotation(shape: .pixelate(rect: CGRect(x: 8, y: 8, width: 24, height: 24)),
                       style: AnnotationStyle(color: .red, lineWidth: 4))   // 格子 8pt
    buf.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(
            data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        AnnotationRenderer.render([a], in: ctx,
                                  sourceProvider: { rect in
                                      solidRed(w: Int(rect.width), h: Int(rect.height))
                                          .map { (image: $0, drawRect: rect) }
                                  })
    }
    let idx = ((h - 1 - 20) * w + 20) * 4
    checkTrue("pixelate：取樣紅底 → 馬賽克區為紅", buf[idx] > 180 && buf[idx + 1] < 90)
    // 無 provider：不 crash、畫灰佔位
    var buf2 = [UInt8](repeating: 0, count: w * h * 4)
    buf2.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(
            data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        AnnotationRenderer.render([a], in: ctx)
    }
    let idx2 = ((h - 1 - 20) * w + 20) * 4
    checkTrue("pixelate：無 provider 畫灰佔位", buf2[idx2 + 3] > 0)
}
pixelateRenderSmokeTest()

// 20) 縮放幾何：從 startBounds 映射到 newBounds
var scRect = Annotation(shape: .rect(CGRect(x: 10, y: 10, width: 20, height: 20)),
                        style: AnnotationStyle(color: .red, lineWidth: 4))
scRect.scaled(from: CGRect(x: 10, y: 10, width: 20, height: 20),
              to: CGRect(x: 10, y: 10, width: 40, height: 20))
checkEq("scaled：rect 寬倍增", scRect.bounds, CGRect(x: 10, y: 10, width: 40, height: 20))

var scLine = Annotation(shape: .line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 10)),
                        style: AnnotationStyle(color: .red, lineWidth: 4))
scLine.scaled(from: CGRect(x: 0, y: 0, width: 10, height: 10),
              to: CGRect(x: 0, y: 0, width: 20, height: 10))
if case .line(let f, let t) = scLine.shape {
    checkEq("scaled：line 端點比例", t, CGPoint(x: 20, y: 10))
    checkEq("scaled：line 起點不動", f, CGPoint.zero)
} else { failures += 1; print("❌ scaled line：型別跑掉") }

var scText = Annotation(shape: .text(origin: CGPoint(x: 5, y: 5), string: "x"),
                        style: AnnotationStyle(color: .red, lineWidth: 4))
let beforeText = scText.bounds
scText.scaled(from: beforeText, to: beforeText.insetBy(dx: -10, dy: -10))
checkEq("scaled：text 不可縮放＝no-op", scText.bounds, beforeText)
checkTrue("isCornerResizable：rect true / text false",
          scRect.isCornerResizable && !scText.isCornerResizable)

var scPen = Annotation(shape: .freehand(points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 0)]),
                       style: AnnotationStyle(color: .red, lineWidth: 4))
scPen.scaled(from: scPen.bounds, to: scPen.bounds.offsetBy(dx: 10, dy: 0))
if case .freehand(let pts) = scPen.shape {
    checkEq("scaled：freehand 全點平移（同尺寸映射）", pts[0], CGPoint(x: 10, y: 0))
} else { failures += 1; print("❌ scaled freehand：型別跑掉") }

// 20b) 測量工具：讀數選擇（純函式）＋對角線＋pixelScale 隨標註走
// 座標系是 view 座標（左下原點、y 向上）——dy > 0 是往上，決定對角線箭頭方向。
// 讀數一律像素。非 Retina（scale 1）：點＝像素。
func mLines(_ fx: CGFloat, _ fy: CGFloat, _ tx: CGFloat, _ ty: CGFloat,
            scale: CGFloat = 1) -> [String] {
    AnnotationGeometry.measurementLines(from: CGPoint(x: fx, y: fy),
                                        to: CGPoint(x: tx, y: ty), pixelScale: scale)
}

checkEq("測量：兩維都夠大 → 尺寸＋對角線兩行",
        mLines(0, 0, 248, 96), ["248 × 96 px", "↗ 266 px"])
checkEq("測量：細長橫條 → 只給水平長度（單行）",
        mLines(0, 0, 160, 2), ["160 px"])
checkEq("測量：細長直條 → 只給垂直長度（單行）",
        mLines(0, 0, 3, 96), ["96 px"])
checkEq("測量：兩維都小（剛開始拖）→ 只給尺寸，對角線無意義",
        mLines(0, 0, 3, 5), ["3 × 5 px"])
// Retina：點 × 2 = 像素。這是整個測量功能的核心換算（單位錯了數字就全錯）。
checkEq("測量：Retina 點→像素 ×2（含對角線）",
        mLines(0, 0, 124, 48, scale: 2), ["248 × 96 px", "↗ 266 px"])
// 細長判定用像素：3 點高在 Retina 上是 6px（< 8）→ 仍算細長；scale 1 時 3px 也算細長。
checkEq("測量：細長門檻按像素判定（Retina 3 點 = 6px 仍算細長）",
        mLines(0, 0, 80, 3, scale: 2), ["160 px"])
// 5 點高在 Retina 上是 10px（≥ 8）→ 不算細長，給兩維＋對角線
checkEq("測量：Retina 5 點 = 10px 不算細長",
        mLines(0, 0, 80, 5, scale: 2), ["160 × 10 px", "↗ 160 px"])
// 3-4-5 直角三角形：對角線必須正好 5 倍（驗算術而非只驗格式）
checkEq("測量：對角線＝hypot（3-4-5 驗算）",
        mLines(0, 0, 30, 40), ["30 × 40 px", "↗ 50 px"])

// 四個方向的箭頭符號（y 向上：dy>0＝往上）
checkEq("測量：右上＝↗", mLines(0, 0, 30, 40)[1], "↗ 50 px")
checkEq("測量：右下＝↘", mLines(0, 40, 30, 0)[1], "↘ 50 px")
checkEq("測量：左上＝↖", mLines(30, 0, 0, 40)[1], "↖ 50 px")
checkEq("測量：左下＝↙", mLines(30, 40, 0, 0)[1], "↙ 50 px")
// 反向拖曳的尺寸讀數不受方向影響（只有箭頭方向不同）
checkEq("測量：反向拖曳尺寸相同", mLines(30, 40, 0, 0)[0], mLines(0, 0, 30, 40)[0])

// pixelScale 綁在 shape 上：平移與縮放都不能改動它，否則讀數會在操作後失真。
var mAnn = Annotation(shape: .measure(from: CGPoint(x: 10, y: 10),
                                      to: CGPoint(x: 110, y: 50), pixelScale: 2),
                      style: AnnotationStyle(color: .red, lineWidth: 4))
checkEq("測量：bounds＝端點正規化矩形", mAnn.bounds, CGRect(x: 10, y: 10, width: 100, height: 40))
checkTrue("測量：可用四角 handle 縮放", mAnn.isCornerResizable)
checkTrue("測量：面積類命中測試", mAnn.hitTest(CGPoint(x: 60, y: 30)))
mAnn.move(by: CGVector(dx: 5, dy: -5))
if case .measure(let a, let b, let sc) = mAnn.shape {
    checkEq("測量：平移後起點位移", a, CGPoint(x: 15, y: 5))
    checkEq("測量：平移後終點位移", b, CGPoint(x: 115, y: 45))
    checkEq("測量：平移不改 pixelScale", sc, 2)
} else { failures += 1; print("❌ 測量 move：型別跑掉") }
let mBefore = mAnn.bounds
mAnn.scaled(from: mBefore, to: CGRect(x: mBefore.minX, y: mBefore.minY,
                                      width: mBefore.width * 2, height: mBefore.height))
if case .measure(let a, let b, let sc) = mAnn.shape {
    checkEq("測量：縮放後寬變兩倍", abs(b.x - a.x), 200)
    checkEq("測量：縮放不改 pixelScale", sc, 2)
    checkEq("測量：縮放後讀數＝新尺寸",
            AnnotationGeometry.measurementLines(from: a, to: b, pixelScale: sc)[0],
            "400 × 80 px")
} else { failures += 1; print("❌ 測量 scaled：型別跑掉") }

// 21) clearRedo
let rdoc = AnnotationDocument()
rdoc.add(Annotation(shape: .rect(CGRect(x: 0, y: 0, width: 5, height: 5)),
                    style: AnnotationStyle(color: .red, lineWidth: 4)))
rdoc.undo()
checkTrue("clearRedo 前：canRedo", rdoc.canRedo)
rdoc.clearRedo()
checkTrue("clearRedo 後：redo 清空", !rdoc.canRedo)

// 22) freehand bounds 含控制點外插（L 形轉角案例——舊點集 bbox 會低估）
let lPts = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 10), CGPoint(x: 100, y: 10), CGPoint(x: 100, y: 0)]
let lPen = Annotation(shape: .freehand(points: lPts), style: AnnotationStyle(color: .red, lineWidth: 1))
checkTrue("freehand bounds：涵蓋 Catmull-Rom 外插（y>10 的 overshoot）", lPen.bounds.maxY > 10.5)

// 23) 馬賽克 clamp：矩形超出底圖 → 只畫交集、不拉伸（上紅下藍底圖驗證取樣方位）
func pixelateClampAndOrientationTest() {
    // 上半紅、下半藍的底圖 provider（view 座標 y-up：上半＝y 大的那半）
    func twoTone(rect: CGRect) -> CGImage? {
        let w = max(1, Int(rect.width)), h = max(1, Int(rect.height))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 2))              // CG 下半＝藍
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: h / 2, width: w, height: h - h / 2))      // CG 上半＝紅
        return ctx.makeImage()
    }
    let w = 40, h = 40
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let a = Annotation(shape: .pixelate(rect: CGRect(x: 4, y: 4, width: 32, height: 32)),
                       style: AnnotationStyle(color: .red, lineWidth: 2))   // 格 4pt
    buf.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        AnnotationRenderer.render([a], in: ctx, sourceProvider: { rect in
            twoTone(rect: rect).map { (image: $0, drawRect: rect) }
        })
    }
    // 馬賽克區內：上半（CG y 高＝記憶體列小）應偏紅、下半偏藍——取樣方位正確
    let topIdx = ((h - 1 - 30) * w + 20) * 4    // view y=30（上半）
    let botIdx = ((h - 1 - 10) * w + 20) * 4    // view y=10（下半）
    checkTrue("pixelate 方位：上半取樣紅", buf[topIdx] > 150 && buf[topIdx + 2] < 100)
    checkTrue("pixelate 方位：下半取樣藍", buf[botIdx + 2] > 150 && buf[botIdx] < 100)
}
pixelateClampAndOrientationTest()

// 23b) clamp 回歸：provider 回傳「比 rect 小的交集」→ 內容只畫在交集內、不拉伸鋪滿
func pixelateClampRegressionTest() {
    func solidRed(w: Int, h: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.13, blue: 0.16, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
    let w = 40, h = 40
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let a = Annotation(shape: .pixelate(rect: CGRect(x: 4, y: 4, width: 32, height: 32)),
                       style: AnnotationStyle(color: .red, lineWidth: 2))
    buf.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // 模擬 clamp：交集只有左半（x 4..20），如同矩形右半超出底圖
        AnnotationRenderer.render([a], in: ctx, sourceProvider: { _ in
            solidRed(w: 16, h: 32).map { (image: $0, drawRect: CGRect(x: 4, y: 4, width: 16, height: 32)) }
        })
    }
    let insideIdx = ((h - 1 - 20) * w + 10) * 4    // 交集內（欄 10）
    let outsideIdx = ((h - 1 - 20) * w + 30) * 4   // rect 內、交集外（欄 30）——不得被拉伸畫到
    checkTrue("pixelate clamp：交集內有內容", buf[insideIdx] > 150)
    checkTrue("pixelate clamp：交集外無內容（不拉伸）", buf[outsideIdx + 3] == 0)
}
pixelateClampRegressionTest()

// 24) 字級公式共用
checkEq("AnnotationStyle.textFontSize", AnnotationStyle(color: .red, lineWidth: 4).textFontSize, 20)

// 25) 序號數字對比色：白/黃圈配黑字、紅/黑圈配白字（白圈白字＝白球 bug 回歸）
checkTrue("contrast：白圈黑字", AnnotationColor.white.isLight)
checkTrue("contrast：黃圈黑字", AnnotationColor.yellow.isLight)
checkTrue("contrast：紅圈白字", !AnnotationColor.red.isLight)
checkTrue("contrast：黑圈白字", !AnnotationColor.black.isLight)

// 26) 截圖完直接貼：view 座標 → 全域框（overlay 視窗蓋滿螢幕，view 座標 == 視窗座標）
check(
    "globalRect 主螢幕原點(0,0)＝原樣",
    CoordinateUtils.globalRect(selection: CGRect(x: 100, y: 50, width: 300, height: 200),
                               windowOrigin: .zero),
    CGRect(x: 100, y: 50, width: 300, height: 200)
)
check(
    "globalRect 次螢幕負原點平移",
    CoordinateUtils.globalRect(selection: CGRect(x: 10, y: 20, width: 40, height: 30),
                               windowOrigin: CGPoint(x: -1920, y: -180)),
    CGRect(x: -1910, y: -160, width: 40, height: 30)
)
check(
    "globalRect 右側次螢幕正原點平移",
    CoordinateUtils.globalRect(selection: CGRect(x: 5, y: 8, width: 60, height: 40),
                               windowOrigin: CGPoint(x: 1440, y: 90)),
    CGRect(x: 1445, y: 98, width: 60, height: 40)
)
check(
    "centeredRect 以中心點放置",
    CoordinateUtils.centeredRect(at: CGPoint(x: 100, y: 100), size: CGSize(width: 40, height: 20)),
    CGRect(x: 80, y: 90, width: 40, height: 20)
)

// 27) 取色器：ColorSampler（RGBA 與 BGRA 兩種 byte order 的來源都要取對）
func makeSamplerImage(bitmapInfo: UInt32, bytes: [UInt8]) -> CGImage? {
    var data = bytes
    return data.withUnsafeMutableBytes { buf -> CGImage? in
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: buf.baseAddress, width: 2, height: 2,
                                  bitsPerComponent: 8, bytesPerRow: 8, space: space,
                                  bitmapInfo: bitmapInfo) else { return nil }
        return ctx.makeImage()
    }
}
// 2×2 測試圖（記憶體 row 0＝影像最上排）：上排 紅、綠；下排 藍、白
let rgbaBytes: [UInt8] = [
    255, 0, 0, 255,   0, 255, 0, 255,
    0, 0, 255, 255,   255, 255, 255, 255,
]
let bgraBytes: [UInt8] = [
    0, 0, 255, 255,   0, 255, 0, 255,
    255, 0, 0, 255,   255, 255, 255, 255,
]
let rgbaImg = makeSamplerImage(bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
                               bytes: rgbaBytes)
let bgraImg = makeSamplerImage(
    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
    bytes: bgraBytes)
func hexAt(_ img: CGImage?, _ x: Int, _ y: Int) -> String? {
    guard let img, let rgb = ColorSampler.sampleRGB(image: img, x: x, y: y) else { return nil }
    return ColorSampler.hexString(r: rgb.r, g: rgb.g, b: rgb.b)
}
checkEq("sampleRGB RGBA 紅(0,0)", hexAt(rgbaImg, 0, 0), "#FF0000")
checkEq("sampleRGB RGBA 綠(1,0)", hexAt(rgbaImg, 1, 0), "#00FF00")
checkEq("sampleRGB RGBA 藍(0,1)", hexAt(rgbaImg, 0, 1), "#0000FF")
checkEq("sampleRGB BGRA 紅(0,0)", hexAt(bgraImg, 0, 0), "#FF0000")
checkEq("sampleRGB BGRA 白(1,1)", hexAt(bgraImg, 1, 1), "#FFFFFF")
checkTrue("sampleRGB 越界 x=-1 nil", rgbaImg.flatMap { ColorSampler.sampleRGB(image: $0, x: -1, y: 0) } == nil)
checkTrue("sampleRGB 越界 x=2 nil", rgbaImg.flatMap { ColorSampler.sampleRGB(image: $0, x: 2, y: 0) } == nil)
checkTrue("sampleRGB 越界 y=2 nil", rgbaImg.flatMap { ColorSampler.sampleRGB(image: $0, x: 0, y: 2) } == nil)
checkTrue("sampleRGB 越界 y=-1 nil", rgbaImg.flatMap { ColorSampler.sampleRGB(image: $0, x: 0, y: -1) } == nil)
checkEq("hexString 一般值大寫", ColorSampler.hexString(r: 58, g: 111, b: 242), "#3A6FF2")
checkEq("rgbString 一般值", ColorSampler.rgbString(r: 58, g: 111, b: 242), "rgb(58, 111, 242)")
checkEq("rgbString 端點值", ColorSampler.rgbString(r: 0, g: 255, b: 0), "rgb(0, 255, 0)")

// 28) 存檔：CaptureSaver
let saveDate = Calendar.current.date(from: DateComponents(
    year: 2026, month: 7, day: 22, hour: 21, minute: 30, second: 45))!
checkEq("filename 固定規則", CaptureSaver.filename(for: saveDate),
        "anypaint 2026-07-22 21.30.45.png")

let saveDir = URL(fileURLWithPath: "/tmp/x")
checkEq("uniquedURL 無碰撞原樣",
        CaptureSaver.uniquedURL(directory: saveDir, filename: "a.png", exists: { _ in false }).path,
        "/tmp/x/a.png")
checkEq("uniquedURL 碰撞加 -2",
        CaptureSaver.uniquedURL(directory: saveDir, filename: "a.png",
                                exists: { $0.path == "/tmp/x/a.png" }).path,
        "/tmp/x/a-2.png")
checkEq("uniquedURL 連續碰撞加 -3",
        CaptureSaver.uniquedURL(directory: saveDir, filename: "a.png",
                                exists: { $0.path == "/tmp/x/a.png" || $0.path == "/tmp/x/a-2.png" }).path,
        "/tmp/x/a-3.png")

// writePNG roundtrip：寫進「不存在的子層」驗證自動建目錄，讀回驗尺寸，結束清理
let saveTmpRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("anypaint-selftest-\(ProcessInfo.processInfo.processIdentifier)")
let saveTarget = saveTmpRoot.appendingPathComponent("nested/dir/out.png")
var savePixel: [UInt8] = [255, 0, 0, 255]
let saveImg: NSImage? = savePixel.withUnsafeMutableBytes { buf in
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1,
                              bitsPerComponent: 8, bytesPerRow: 4, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let cg = ctx.makeImage() else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: 1, height: 1))
}
do {
    guard let saveImg else { throw CocoaError(.fileWriteUnknown) }
    try CaptureSaver.writePNG(image: saveImg, to: saveTarget)
    checkTrue("writePNG 自動建目錄並寫檔", FileManager.default.fileExists(atPath: saveTarget.path))
    let readBack = NSImage(contentsOf: saveTarget)
    checkEq("writePNG 讀回尺寸", readBack?.representations.first.map { "\($0.pixelsWide)x\($0.pixelsHigh)" }, "1x1")
} catch {
    failures += 1
    print("❌ writePNG roundtrip throw: \(error)")
}
try? FileManager.default.removeItem(at: saveTmpRoot)

// 29) 視窗偵測：WindowDetector
// convert：CG 全域（左上原點、主螢幕基準）→ AppKit 全域（左下原點）。
// 主螢幕 1080 高：CG y=100、高 200 的視窗 → AppKit y = 1080 - (100+200) = 780
check("convert 主螢幕內視窗",
      WindowDetector.convert(cgBounds: CGRect(x: 50, y: 100, width: 300, height: 200),
                             primaryHeight: 1080),
      CGRect(x: 50, y: 780, width: 300, height: 200))
// 次螢幕在主螢幕上方：CG y 為負 → AppKit y > primaryHeight
check("convert 上方次螢幕（CG 負 y）",
      WindowDetector.convert(cgBounds: CGRect(x: 0, y: -500, width: 400, height: 300),
                             primaryHeight: 1080),
      CGRect(x: 0, y: 1280, width: 400, height: 300))
// 次螢幕在主螢幕下方：CG y 超過 primaryHeight → AppKit y 為負
check("convert 下方次螢幕（AppKit 負 y）",
      WindowDetector.convert(cgBounds: CGRect(x: 100, y: 1200, width: 200, height: 100),
                             primaryHeight: 1080),
      CGRect(x: 100, y: -220, width: 200, height: 100))

// hitTest：陣列序＝前→後，重疊取前者
let wdFront = WindowInfo(frameGlobal: CGRect(x: 0, y: 0, width: 100, height: 100))
let wdBack = WindowInfo(frameGlobal: CGRect(x: 50, y: 50, width: 200, height: 200))
check("hitTest 重疊取最前",
      WindowDetector.hitTest(point: CGPoint(x: 60, y: 60), windows: [wdFront, wdBack]) ?? .zero,
      wdFront.frameGlobal)
check("hitTest 只命中後者",
      WindowDetector.hitTest(point: CGPoint(x: 150, y: 150), windows: [wdFront, wdBack]) ?? .zero,
      wdBack.frameGlobal)
checkTrue("hitTest 無命中 nil", WindowDetector.hitTest(point: CGPoint(x: 500, y: 500),
                                                    windows: [wdFront, wdBack]) == nil)

// makeWindowList：過濾 layer != 0 與面積 ≤ 1、保序、座標已轉 AppKit
let wdRaw: [[String: Any]] = [
    [kCGWindowLayer as String: 0,
     kCGWindowBounds as String: CGRect(x: 0, y: 100, width: 300, height: 200).dictionaryRepresentation],
    [kCGWindowLayer as String: 25,   // 選單列類 → 濾掉
     kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 500, height: 24).dictionaryRepresentation],
    [kCGWindowLayer as String: 0,    // 面積 ≤ 1 → 濾掉
     kCGWindowBounds as String: CGRect(x: 10, y: 10, width: 1, height: 1).dictionaryRepresentation],
    [kCGWindowLayer as String: 0,
     kCGWindowBounds as String: CGRect(x: 400, y: 300, width: 100, height: 100).dictionaryRepresentation],
]
let wdList = WindowDetector.makeWindowList(raw: wdRaw, primaryHeight: 1080)
checkEq("makeWindowList 過濾後數量", wdList.count, 2)
check("makeWindowList 保序＋座標轉換[0]", wdList.first?.frameGlobal ?? .zero,
      CGRect(x: 0, y: 780, width: 300, height: 200))
check("makeWindowList 保序＋座標轉換[1]", wdList.last?.frameGlobal ?? .zero,
      CGRect(x: 400, y: 680, width: 100, height: 100))

check("hitTest min 邊含點", WindowDetector.hitTest(point: CGPoint(x: 0, y: 0),
                                                windows: [wdFront]) ?? .zero,
      wdFront.frameGlobal)
checkTrue("hitTest max 邊排他", WindowDetector.hitTest(point: CGPoint(x: 100, y: 100),
                                                    windows: [wdFront]) == nil)
let wdAlphaRaw: [[String: Any]] = [
    [kCGWindowLayer as String: 0, kCGWindowAlpha as String: 0.0,
     kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 100, height: 100).dictionaryRepresentation],
    [kCGWindowLayer as String: 0, kCGWindowAlpha as String: 0.5,
     kCGWindowBounds as String: CGRect(x: 200, y: 0, width: 100, height: 100).dictionaryRepresentation],
]
checkEq("makeWindowList 濾掉 alpha=0", WindowDetector.makeWindowList(raw: wdAlphaRaw, primaryHeight: 1080).count, 1)

let wdLevelRaw: [[String: Any]] = [
    [kCGWindowLayer as String: 3,   // 置頂（floating，自家貼圖層級）→ 納入
     kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 100, height: 100).dictionaryRepresentation],
    [kCGWindowLayer as String: 20,  // Dock 層 → 濾掉
     kCGWindowBounds as String: CGRect(x: 0, y: 200, width: 100, height: 100).dictionaryRepresentation],
]
checkEq("makeWindowList 納入置頂層/濾掉 Dock 層",
        WindowDetector.makeWindowList(raw: wdLevelRaw, primaryHeight: 1080).count, 1)

// 30) 檔名樣板：FilenameTemplate
let ftTZ = TimeZone(identifier: "Asia/Taipei")!   // +0800；固定時區讓測試跨機器穩定
var ftCal = Calendar(identifier: .gregorian)
ftCal.timeZone = ftTZ
let ftBase = ftCal.date(from: DateComponents(year: 2026, month: 7, day: 5,
                                             hour: 8, minute: 4, second: 9))!
// +7ms 用 epoch 加法：DateComponents.nanosecond 有浮點誤差（7ms 會變 6999999…ns）
let ftDate = Date(timeIntervalSince1970: ftBase.timeIntervalSince1970 + 0.007)
let ftVars = ["os": "macOS 15.5", "computername": "MyMac", "username": "anson",
              "title": "報告: 第1章/序"]

func ft(_ t: String) -> String {
    FilenameTemplate.expand(t, date: ftDate, vars: ftVars, timeZone: ftTZ)
}

// 2026-07-05 是星期日；單位數值同時驗 padding 與最長優先（"dd" 不被拆成 "d"+"d"）
checkEq("expand 日/星期 token", ft("$d dd ddd dddd$"), "5 05 Sun Sunday")
checkEq("expand 月 token", ft("$M MM MMM MMMM$"), "7 07 Jul July")
checkEq("expand 年時分秒 token", ft("$yy yyyy H HH m mm s ss$"), "26 2026 8 08 4 04 9 09")
checkEq("expand 毫秒/時區 token", ft("$z zzz t$"), "7 007 +0800")
checkEq("expand 預設樣板整串", ft(FilenameTemplate.defaultName),
        "anypaint 2026-07-05 08.04.09.png")
checkEq("expand 變數＋title 斜線與冒號清洗",
        ft("%username%-%title%.png"), "anson-報告- 第1章-序.png")
checkEq("expand title:N 截長", ft("%title:2%"), "報告")
checkEq("expand 未知變數原樣保留", ft("%foo%x"), "%foo%x")
checkEq("expand 非法字元清洗（樣板字面）", ft("a|b:c*d?e<f>g"), "a-b-c-d-e-f-g")
checkEq("expand 字面 / 保留為目錄分隔", ft("~/Pictures/$yyyy$/a.png"), "~/Pictures/2026/a.png")
checkEq("expand os 變數", ft("%os%"), "macOS 15.5")
checkEq("expand computername 變數", ft("%computername%"), "MyMac")
checkEq("expand 未配對 $ 字面保留", ft("50$ off"), "50$ off")
checkTrue("hasPNGExtension 大小寫不拘",
          FilenameTemplate.hasPNGExtension("A.PNG")
          && FilenameTemplate.hasPNGExtension("a.png")
          && !FilenameTemplate.hasPNGExtension("a.jpg"))
checkEq("ensuringPNGExtension 補副檔名", FilenameTemplate.ensuringPNGExtension("shot"), "shot.png")
checkEq("ensuringPNGExtension 已有不重複", FilenameTemplate.ensuringPNGExtension("shot.PNG"), "shot.PNG")
checkEq("ensuringMeaningfulFilename 空檔名 fallback",
        FilenameTemplate.ensuringMeaningfulFilename("/d/---.png", fallbackName: "f.png"), "/d/f.png")
checkEq("ensuringMeaningfulFilename 正常保留",
        FilenameTemplate.ensuringMeaningfulFilename("/d/a.png", fallbackName: "f.png"), "/d/a.png")
checkEq("ensuringMeaningfulFilename 純檔名 fallback",
        FilenameTemplate.ensuringMeaningfulFilename(".png", fallbackName: "f.png"), "f.png")
checkEq("ensuringMeaningfulFilename mp4 空檔名 fallback",
        FilenameTemplate.ensuringMeaningfulFilename("/d/---.mp4", fallbackName: "f.mp4", ext: "mp4"), "/d/f.mp4")
checkEq("ensuringMeaningfulFilename mp4 正常保留",
        FilenameTemplate.ensuringMeaningfulFilename("/d/a.mp4", fallbackName: "f.mp4", ext: "mp4"), "/d/a.mp4")
checkEq("ensuringMeaningfulFilename gif 空白+點 fallback",
        FilenameTemplate.ensuringMeaningfulFilename("    .gif", fallbackName: "a.gif", ext: "gif"), "a.gif")
checkEq("ensuringMeaningfulFilename gif 內容+點 保留",
        FilenameTemplate.ensuringMeaningfulFilename("/d/ ab .gif", fallbackName: "x.gif", ext: "gif"), "/d/ ab .gif")

// 31) 輸出設定：quickSave 遷移純函式＋CaptureVars.frontWindowTitle
checkEq("quickSave 遷移：新鍵已設用新值",
        AppSettings.resolvedQuickSaveTemplate(stored: "/x/a $d$.png", legacyDirectory: "/old"),
        "/x/a $d$.png")
checkEq("quickSave 遷移：未設→舊資料夾+預設檔名",
        AppSettings.resolvedQuickSaveTemplate(stored: nil, legacyDirectory: "/Users/a/Desktop"),
        "/Users/a/Desktop/" + FilenameTemplate.defaultName)
checkEq("quickSave 遷移：空字串視同未設",
        AppSettings.resolvedQuickSaveTemplate(stored: "", legacyDirectory: "/d"),
        "/d/" + FilenameTemplate.defaultName)

// 「存檔並開啟」的 App 解析：nil＝退回系統預設（不是失敗）
let fakeApp = URL(fileURLWithPath: "/Applications/Fake.app")
let resolver: (String) -> URL? = { $0 == "com.example.fake" ? fakeApp : nil }
checkTrue("openWith 未指定 → 系統預設",
      AppSettings.resolveOpenWithApp(stored: "", resolve: resolver) == nil)
checkTrue("openWith 只有空白 → 系統預設",
      AppSettings.resolveOpenWithApp(stored: "   ", resolve: resolver) == nil)
checkTrue("openWith 指定且找得到 → 用該 App",
      AppSettings.resolveOpenWithApp(stored: "com.example.fake", resolve: resolver) == fakeApp)
checkTrue("openWith 前後空白會 trim",
      AppSettings.resolveOpenWithApp(stored: " com.example.fake ", resolve: resolver) == fakeApp)
checkTrue("openWith 指定但 App 已不存在 → 退回系統預設（不失敗）",
      AppSettings.resolveOpenWithApp(stored: "com.example.deleted", resolve: resolver) == nil)

let cvRaw: [[String: Any]] = [
    [kCGWindowLayer as String: 5, kCGWindowName as String: "置頂輔助"],   // 非 layer-0 → 跳過
    [kCGWindowLayer as String: 0, kCGWindowName as String: "文件A"],
    [kCGWindowLayer as String: 0, kCGWindowName as String: "文件B"],
]
checkEq("frontWindowTitle 取最前 layer-0 標題",
        CaptureVars.frontWindowTitle(raw: cvRaw), "文件A")
checkTrue("frontWindowTitle 最前視窗無名→nil（degrade 交呼叫端）",
          CaptureVars.frontWindowTitle(raw: [[kCGWindowLayer as String: 0]]) == nil)
checkTrue("frontWindowTitle 空清單→nil", CaptureVars.frontWindowTitle(raw: []) == nil)

// 32) 貼圖幾何：縮圖尺寸與中心錨定 resize
checkEq("thumbnailSize 橫圖長邊縮到 120",
        CoordinateUtils.thumbnailSize(for: CGSize(width: 600, height: 300), maxEdge: 120),
        CGSize(width: 120, height: 60))
checkEq("thumbnailSize 直圖長邊縮到 120",
        CoordinateUtils.thumbnailSize(for: CGSize(width: 200, height: 800), maxEdge: 120),
        CGSize(width: 30, height: 120))
checkEq("thumbnailSize 正方形",
        CoordinateUtils.thumbnailSize(for: CGSize(width: 500, height: 500), maxEdge: 120),
        CGSize(width: 120, height: 120))
checkEq("thumbnailSize 已小於上限回原尺寸",
        CoordinateUtils.thumbnailSize(for: CGSize(width: 100, height: 80), maxEdge: 120),
        CGSize(width: 100, height: 80))
checkEq("thumbnailSize 零尺寸不 NaN",
        CoordinateUtils.thumbnailSize(for: .zero, maxEdge: 120), .zero)
check("rectResized 中心不動（放大）",
      CoordinateUtils.rectResized(CGRect(x: 100, y: 100, width: 200, height: 100),
                                  to: CGSize(width: 400, height: 200)),
      CGRect(x: 0, y: 50, width: 400, height: 200))
check("rectResized 中心不動（縮小）",
      CoordinateUtils.rectResized(CGRect(x: 0, y: 0, width: 100, height: 100),
                                  to: CGSize(width: 50, height: 50)),
      CGRect(x: 25, y: 25, width: 50, height: 50))

// 33) OCR：TextRecognizer（Vision headless 可跑真辨識——無 bundle 依賴，已查證）
checkEq("joinedText 多行", TextRecognizer.joinedText(["a", "b"]), "a\nb")
checkEq("joinedText 空陣列", TextRecognizer.joinedText([]), "")

// 真 OCR e2e：CoreText 畫「HELLO 123」進白底 bitmap 實際辨識。
// 英數的系統字型渲染跨機器穩定；中文渲染變數多，交手動驗收。
// 一定要用 recognizeSync——async 版回呼派 main queue，selftest 主緒等待會死鎖。
func makeOCRTestImage(_ text: String) -> CGImage? {
    let W = 400, H = 100
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    let attr = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: 48, weight: .bold),
        .foregroundColor: NSColor.black,
    ])
    ctx.textPosition = CGPoint(x: 20, y: 30)
    CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
    return ctx.makeImage()
}
if let ocrImg = makeOCRTestImage("HELLO 123") {
    do {
        let ocrLines = try TextRecognizer.recognizeSync(cgImage: ocrImg)
        let ocrJoined = TextRecognizer.joinedText(ocrLines)
        checkTrue("OCR e2e 辨識出 HELLO", ocrJoined.contains("HELLO"))
        checkTrue("OCR e2e 辨識出 123", ocrJoined.contains("123"))
    } catch {
        failures += 1
        print("❌ OCR e2e throw: \(error)")
    }
} else {
    failures += 1
    print("❌ OCR e2e 無法建測試圖")
}

// 33b) QR／條碼辨識與「條碼優先於文字」
// CIQRCodeGenerator 產生真 QR 進去實際辨識（同 OCR e2e 的紀律：真跑，不是 mock）。
func makeQRTestImage(_ payload: String, withCaption caption: String?) -> CGImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(payload.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let small = filter.outputImage else { return nil }
    // QR 原始輸出很小（每模組 1px），放大到 Vision 辨得出來的尺寸。
    let qr = small.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    let ciCtx = CIContext()
    guard let qrCG = ciCtx.createCGImage(qr, from: qr.extent) else { return nil }
    guard let caption else { return qrCG }

    // 把 QR 畫在上半、說明文字畫在下半——模擬「QR 底下印著說明文字」的真實情境，
    // 用來驗證條碼優先於文字（若以文字為先，這種圖就永遠拿不到 QR 內容）。
    let W = Int(qr.extent.width), H = Int(qr.extent.height) + 60
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.draw(qrCG, in: CGRect(x: 0, y: 60, width: qr.extent.width, height: qr.extent.height))
    let attr = NSAttributedString(string: caption, attributes: [
        .font: NSFont.systemFont(ofSize: 28, weight: .bold),
        .foregroundColor: NSColor.black,
    ])
    ctx.textPosition = CGPoint(x: 8, y: 18)
    CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
    return ctx.makeImage()
}

checkEq("Recognition.joined：條碼多筆換行相接",
        TextRecognizer.Recognition.barcode(["a", "b"]).joined, "a\nb")
checkEq("Recognition.joined：文字走 joinedText",
        TextRecognizer.Recognition.text(["x", "y"]).joined, "x\ny")
checkEq("Recognition.joined：empty 是空字串",
        TextRecognizer.Recognition.empty.joined, "")

if let qrOnly = makeQRTestImage("https://example.com/anypaint", withCaption: nil) {
    do {
        let r = try TextRecognizer.recognizeContentSync(cgImage: qrOnly)
        if case .barcode(let codes) = r {
            checkTrue("QR e2e 辨識出 payload", codes.contains("https://example.com/anypaint"))
        } else {
            failures += 1
            print("❌ QR e2e 期望 .barcode，實得 \(r)")
        }
    } catch {
        failures += 1
        print("❌ QR e2e throw: \(error)")
    }
} else {
    failures += 1
    print("❌ QR e2e 無法建測試圖")
}

// QR＋說明文字同在一張圖：必須回 .barcode（條碼優先，設計決定）
if let qrWithText = makeQRTestImage("SCAN-ME-42", withCaption: "SCAN HERE") {
    do {
        let r = try TextRecognizer.recognizeContentSync(cgImage: qrWithText)
        if case .barcode(let codes) = r {
            checkTrue("QR＋文字同框時條碼優先", codes.contains("SCAN-ME-42"))
        } else {
            failures += 1
            print("❌ 條碼優先 期望 .barcode，實得 \(r)")
        }
    } catch {
        failures += 1
        print("❌ 條碼優先 throw: \(error)")
    }
} else {
    failures += 1
    print("❌ 條碼優先 無法建測試圖")
}

// 純文字圖（無條碼）必須回 .text，不能被條碼路徑吃掉
if let textOnly = makeOCRTestImage("HELLO 123") {
    do {
        let r = try TextRecognizer.recognizeContentSync(cgImage: textOnly)
        if case .text(let lines) = r {
            checkTrue("純文字圖回 .text", TextRecognizer.joinedText(lines).contains("HELLO"))
        } else {
            failures += 1
            print("❌ 純文字圖 期望 .text，實得 \(r)")
        }
    } catch {
        failures += 1
        print("❌ 純文字圖 throw: \(error)")
    }
}

// 空白圖：兩種都偵測不到 → .empty
if let space = CGColorSpace(name: CGColorSpace.sRGB),
   let blankCtx = CGContext(data: nil, width: 200, height: 120, bitsPerComponent: 8,
                            bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
    blankCtx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    blankCtx.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
    if let blank = blankCtx.makeImage() {
        do {
            checkEq("空白圖回 .empty",
                    try TextRecognizer.recognizeContentSync(cgImage: blank), .empty)
        } catch {
            failures += 1
            print("❌ 空白圖 throw: \(error)")
        }
    }
}

// 34) OCR 結果窗定位：右側優先→左側→fallback，clamp 進螢幕
let srScreen = CGRect(x: 0, y: 0, width: 1000, height: 800)
check("sideRect 右側夠位＝貼右、頂對齊",
      CoordinateUtils.sideRect(beside: CGRect(x: 100, y: 300, width: 200, height: 150),
                               size: CGSize(width: 320, height: 240), in: srScreen),
      CGRect(x: 308, y: 210, width: 320, height: 240))
check("sideRect 右側不夠換左側",
      CoordinateUtils.sideRect(beside: CGRect(x: 700, y: 300, width: 250, height: 150),
                               size: CGSize(width: 320, height: 240), in: srScreen),
      CGRect(x: 372, y: 210, width: 320, height: 240))
check("sideRect 兩側都不夠＝疊 anchor 內緣",
      CoordinateUtils.sideRect(beside: CGRect(x: 100, y: 300, width: 850, height: 150),
                               size: CGSize(width: 320, height: 240), in: srScreen),
      CGRect(x: 100, y: 210, width: 320, height: 240))
check("sideRect 底部超界 clamp",
      CoordinateUtils.sideRect(beside: CGRect(x: 100, y: -100, width: 200, height: 150),
                               size: CGSize(width: 320, height: 240), in: srScreen),
      CGRect(x: 308, y: 0, width: 320, height: 240))

runScrollCaptureTests()

// 35) RecordMath：GIF delay 累計捨入（gifski src/lib.rs 同法——逐格天真捨入會累積漂移）
do {
    // 12fps、10 秒：120 格，每格 1/12s=8.33cs。天真捨入(8cs)總長只有 9.6s（漂 4%）；
    // 累計捨入的總和必須落在 1000±1 cs。
    let times = (0..<120).map { Double($0) / 12.0 }
    let delays = RecordMath.gifDelaysCentiseconds(frameStartTimes: times, duration: 10.0)
    checkEq("gifDelays 格數", delays.count, 120)
    let total = delays.reduce(0, +)
    checkTrue("gifDelays 總長不漂移（\(total)cs）", abs(total - 1000) <= 1)
    checkTrue("gifDelays 每格 ≥ 2cs", delays.allSatisfy { $0 >= 2 })
    // 均勻 12fps 下 delay 只會是 8 或 9 交錯，不會出現離群值
    checkTrue("gifDelays 值域 8...9", delays.allSatisfy { (8...9).contains($0) })
}
do {
    // 不均勻（VFR）輸入：0, 0.5, 3.0 三格、總長 5s → delay = 50, 250, 200 cs
    let delays = RecordMath.gifDelaysCentiseconds(frameStartTimes: [0, 0.5, 3.0], duration: 5.0)
    checkEq("gifDelays VFR", delays, [50, 250, 200])
}

// 36) RecordMath：sample-and-hold 網格映射（VFR 大空洞天然消化）
do {
    // 來源：0s 與 3s 兩格（中間 3 秒靜止＝SCK 不供格）；4 秒 @2fps → 8 個目標格
    // 目標時刻 0,0.5,1,1.5,2,2.5,3,3.5 → 前 6 個用格0、後 2 個用格1
    let idx = RecordMath.sampleHoldIndices(sourceTimes: [0, 3.0], duration: 4.0, fps: 2)
    checkEq("sampleHold VFR 空洞", idx, [0, 0, 0, 0, 0, 0, 1, 1])
}
do {
    // 目標時刻早於第一格 PTS（首格晚到）→ 用第一格（index 0），不可回傳 -1
    let idx = RecordMath.sampleHoldIndices(sourceTimes: [0.4, 0.5], duration: 1.0, fps: 2)
    checkEq("sampleHold 首格晚到", idx, [0, 1])
}
do {
    // 極短片：至少 2 個目標格（GIF 最少兩格才有動畫意義）
    let idx = RecordMath.sampleHoldIndices(sourceTimes: [0], duration: 0.05, fps: 12)
    checkEq("sampleHold 極短片下限", idx.count, 2)
}
do {
    // 空來源（0 格捕捉）→ 回空結果，不 crash
    let idx = RecordMath.sampleHoldIndices(sourceTimes: [], duration: 1.0, fps: 12)
    checkEq("sampleHold 空來源回空", idx, [])
}

// 37) RecordMath：尾格補齊判斷（Cap 的 0.5s 門檻）
checkTrue("needsTailFrame 過期", RecordMath.needsTailFrame(lastPTSSeconds: 10.0, nowSeconds: 10.6))
checkTrue("needsTailFrame 未過期", !RecordMath.needsTailFrame(lastPTSSeconds: 10.0, nowSeconds: 10.4))

// 38) RecordMath：HUD 時鐘文字（正數 mm:ss；限時=倒數且不出現負值）
checkEq("hudClock 正數", RecordMath.hudClockText(elapsedSeconds: 65, limitSeconds: nil), "01:05")
checkEq("hudClock 倒數", RecordMath.hudClockText(elapsedSeconds: 3, limitSeconds: 10), "00:07")
checkEq("hudClock 倒數不出現負值", RecordMath.hudClockText(elapsedSeconds: 12, limitSeconds: 10), "00:00")

// 39) FilenameTemplate.ensuringExtension（動畫截圖 mp4/gif 命名共用）
checkEq("ensuringExtension 補 mp4", FilenameTemplate.ensuringExtension("a", ext: "mp4"), "a.mp4")
checkEq("ensuringExtension 已有（大小寫不拘）", FilenameTemplate.ensuringExtension("a.MP4", ext: "mp4"), "a.MP4")
checkEq("ensuringExtension gif", FilenameTemplate.ensuringExtension("b.png", ext: "gif"), "b.png.gif")
checkEq("ensuringPNGExtension 行為不變", FilenameTemplate.ensuringPNGExtension("c"), "c.png")

// 40) 動畫截圖 GIF fps 正規化
checkEq("gifFps 正規化 命中", AppSettings.normalizedRecordGifFps(12), 12)
checkEq("gifFps 正規化 平手取小", AppSettings.normalizedRecordGifFps(11), 10)
checkEq("gifFps 正規化 就近", AppSettings.normalizedRecordGifFps(13), 12)
checkEq("gifFps 正規化 下界", AppSettings.normalizedRecordGifFps(7), 8)
checkEq("gifFps 正規化 上界", AppSettings.normalizedRecordGifFps(99), 20)
checkEq("gifFps 正規化 零", AppSettings.normalizedRecordGifFps(0), 8)

// 41) RecordMath：APNG delay（秒，無 cs 捨入——與 GIF 累計捨入是兩套規則，見設計文件 §1.5）
do {
    let d = RecordMath.apngDelaysSeconds(frameStartTimes: [0, 0.5, 3.0], duration: 5.0)
    checkEq("apngDelays VFR", d, [0.5, 2.5, 2.0])
}
do {
    let times = (0..<120).map { Double($0) / 12.0 }
    let d = RecordMath.apngDelaysSeconds(frameStartTimes: times, duration: 10.0)
    checkTrue("apngDelays 總和=時長", abs(d.reduce(0, +) - 10.0) < 1e-9)
    checkEq("apngDelays 格數", d.count, 120)
}
checkEq("apngDelays 空輸入", RecordMath.apngDelaysSeconds(frameStartTimes: [], duration: 1.0), [Double]())

// 42) GifskiEngine.detect（注入 isExecutable stub，設計文件 §1.7；候選順序＝優先序：homebrew 優先）
checkEq("gifski detect homebrew優先",
        GifskiEngine.detect(isExecutable: { _ in true }),
        "/opt/homebrew/bin/gifski")
checkEq("gifski detect 只有usr/local",
        GifskiEngine.detect(isExecutable: { $0 == "/usr/local/bin/gifski" }),
        "/usr/local/bin/gifski")
checkEq("gifski detect 都沒有回nil",
        GifskiEngine.detect(isExecutable: { _ in false }),
        nil)

// 43) GifskiEngine.arguments（純函式：引數順序＋frames 逐一列舉，設計文件 §1.7）
// --width 必傳：實測 gifski 預設把輸出限縮在約 800x600（gifski -h 記載＋實機驗證過，見
// GifskiEngine.arguments 文件註解），不顯式帶寬度會讓超過門檻的擷取畫面被悄悄縮小。
checkEq("gifski arguments 引數順序與frames展開",
        GifskiEngine.arguments(fps: 12, quality: 90, width: 978, output: "/tmp/out.gif",
                               frames: ["/tmp/f/frame-0001.png", "/tmp/f/frame-0002.png"]),
        ["--fps", "12", "--quality", "90", "--width", "978", "-o", "/tmp/out.gif",
         "/tmp/f/frame-0001.png", "/tmp/f/frame-0002.png"])
checkEq("gifski arguments 空frames",
        GifskiEngine.arguments(fps: 8, quality: 90, width: 640, output: "/tmp/out.gif", frames: []),
        ["--fps", "8", "--quality", "90", "--width", "640", "-o", "/tmp/out.gif"])

// 44) Img2webpEngine.detect（注入 isExecutable stub，設計文件 §1.7b；候選順序＝優先序：
// homebrew 優先，同 GifskiEngine.detect 的道理）
checkEq("img2webp detect homebrew優先",
        Img2webpEngine.detect(isExecutable: { _ in true }),
        "/opt/homebrew/bin/img2webp")
checkEq("img2webp detect 只有usr/local",
        Img2webpEngine.detect(isExecutable: { $0 == "/usr/local/bin/img2webp" }),
        "/usr/local/bin/img2webp")
checkEq("img2webp detect 都沒有回nil",
        Img2webpEngine.detect(isExecutable: { _ in false }),
        nil)

// 45) Img2webpEngine.arguments（純函式：等長 delay 摺疊成單一 -d、-loop 0、-o 置尾，
// 設計文件 §1.7b）
checkEq("img2webp arguments 等長delay摺疊成單一-d",
        Img2webpEngine.arguments(delaysMs: [83, 83, 83],
                                 frames: ["/tmp/f/frame-0000.png", "/tmp/f/frame-0001.png",
                                          "/tmp/f/frame-0002.png"],
                                 output: "/tmp/out.webp"),
        ["-loop", "0", "-d", "83",
         "/tmp/f/frame-0000.png", "/tmp/f/frame-0001.png", "/tmp/f/frame-0002.png",
         "-o", "/tmp/out.webp"])
checkEq("img2webp arguments 空frames",
        Img2webpEngine.arguments(delaysMs: [], frames: [], output: "/tmp/out.webp"),
        ["-loop", "0", "-o", "/tmp/out.webp"])

overlayKeyBindingResolveTests()
overlayKeyBindingCodableNormalizationTests()
overlayKeyBindingConflictTests()
overlayKeyBindingStoreTests()
overlayModifiersFromEventTests()
overlayKeyDisplayStringTests()
pasteboardPayloadTests()
pasteboardRoundTripTests()
recordOptionsTests()
makeStreamConfigurationTests()
uitestProtocolTests()
goertzelTests()
recordAudioTracksEndToEndTests()
audioInputDeviceTests()

T.finish()
