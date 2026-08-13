import AnypaintKit
import CoreGraphics

/// Pin 視窗尺寸/透明度、剪貼簿點尺寸、設定頁 nearestOption——原內嵌在 UI 的純數學,抽出後可測。
nonisolated func pinSettingsGeomTests() {
    // zoomedWindowSize：deltaY>0 放大、有寬下限、依 aspect 維持比例
    let z = CoordinateUtils.zoomedWindowSize(currentWidth: 200, deltaY: 100, aspect: 2)
    T.checkEq("zoom: 放大 factor=1+100*0.005=1.5 → 300", z.width, 300)
    T.checkEq("zoom: 高=寬/aspect", z.height, 150)
    let zMin = CoordinateUtils.zoomedWindowSize(currentWidth: 50, deltaY: -9999, aspect: 1)
    T.checkEq("zoom: 縮到下限 40", zMin.width, 40)

    // clampedAlpha：[0.1, 1.0]
    T.checkEq("alpha: 正常加", CoordinateUtils.clampedAlpha(current: 0.5, delta: 0.2), 0.7)
    T.checkEq("alpha: 上限 1.0", CoordinateUtils.clampedAlpha(current: 0.95, delta: 0.5), 1.0)
    T.checkEq("alpha: 下限 0.1", CoordinateUtils.clampedAlpha(current: 0.2, delta: -0.5), 0.1)

    // cappedSize：未超過原樣;超過等比縮
    let small = CGSize(width: 100, height: 80)
    T.checkEq("capped: 未超過原樣", CoordinateUtils.cappedSize(small, maxWidth: 200, maxHeight: 200), small)
    // 400×200 超過 max 200×200：min(200/400, 200/200)=0.5 → 200×100
    T.checkEq("capped: 超寬等比縮",
              CoordinateUtils.cappedSize(CGSize(width: 400, height: 200), maxWidth: 200, maxHeight: 200),
              CGSize(width: 200, height: 100))
    T.checkEq("capped: 0 尺寸不動", CoordinateUtils.cappedSize(.zero, maxWidth: 100, maxHeight: 100), CGSize.zero)

    // pointSize：像素 / scale（Retina）
    T.checkEq("pointSize: 2880×1864 @2x → 1440×932",
              CoordinateUtils.pointSize(pixelWidth: 2880, pixelHeight: 1864, scale: 2),
              CGSize(width: 1440, height: 932))
    T.checkEq("pointSize: scale1 原樣",
              CoordinateUtils.pointSize(pixelWidth: 100, pixelHeight: 50, scale: 1),
              CGSize(width: 100, height: 50))

    // nearestOption：Double（看門狗秒數）與 Int（長圖高度）
    T.checkEq("nearest: Double 選最近", AppSettings.nearestOption([0.0, 60, 300, 600], to: 250.0), 300)
    T.checkEq("nearest: Double 精確命中", AppSettings.nearestOption([0.0, 60, 300], to: 60.0), 60)
    T.checkEq("nearest: Int 選最近", AppSettings.nearestOption([10000, 30000, 50000], to: 25000), 30000)
    T.checkTrue("nearest: 空清單→nil", AppSettings.nearestOption([Int](), to: 5) == nil)
}
