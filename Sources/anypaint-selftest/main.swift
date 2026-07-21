import CoreGraphics
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
let style = AnnotationStyle(color: .red, thickness: .medium)
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
checkEq("counter bounds：半徑=8+線寬×2（medium→32）", counterA.bounds.width, 32)
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

print("---")
if failures == 0 {
    print("全部通過 🎉")
} else {
    print("\(failures) 項失敗")
    exit(1)
}
