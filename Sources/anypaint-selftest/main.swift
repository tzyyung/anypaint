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

print("---")
if failures == 0 {
    print("全部通過 🎉")
} else {
    print("\(failures) 項失敗")
    exit(1)
}
