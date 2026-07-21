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

print("---")
if failures == 0 {
    print("全部通過 🎉")
} else {
    print("\(failures) 項失敗")
    exit(1)
}
