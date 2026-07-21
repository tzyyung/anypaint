import CoreGraphics
import Foundation
import AnypaintKit

// 純邏輯的自我測試。純 Command Line Tools 環境沒有 XCTest 執行器，
// 所以用可直接執行的執行檔跑斷言：swift run anypaint-selftest
// 任一失敗會印出並以非零狀態結束（方便日後接 CI）。

var failures = 0

func check(_ name: String, _ got: CGRect, _ want: CGRect) {
    if got == want {
        print("✅ \(name)")
    } else {
        failures += 1
        print("❌ \(name)\n   got : \(got)\n   want: \(want)")
    }
}

func checkEq<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    if got == want {
        print("✅ \(name)")
    } else {
        failures += 1
        print("❌ \(name)\n   got : \(got)\n   want: \(want)")
    }
}

func checkTrue(_ name: String, _ cond: Bool) {
    if cond {
        print("✅ \(name)")
    } else {
        failures += 1
        print("❌ \(name)")
    }
}

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

print("---")
if failures == 0 {
    print("全部通過 🎉")
} else {
    print("\(failures) 項失敗")
    exit(1)
}
