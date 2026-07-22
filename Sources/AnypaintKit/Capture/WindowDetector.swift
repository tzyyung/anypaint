import CoreGraphics
import Foundation

/// 截圖當下凍結的一個螢幕視窗。
public struct WindowInfo: Equatable {
    /// AppKit 全域座標（點、左下原點）。
    public let frameGlobal: CGRect

    public init(frameGlobal: CGRect) {
        self.frameGlobal = frameGlobal
    }
}

/// 視窗偵測（spec 2026-07-22）：純函式命中測試＋座標轉換，selftest 可測。
/// 清單於截圖當下凍結一次（與凍結畫面一致），之後視窗移動不影響。
public enum WindowDetector {

    /// CG 視窗座標（左上原點、主螢幕基準、y 向下）→ AppKit 全域（左下原點、y 向上）。
    /// 公式對任何螢幕上的視窗都成立（都以主螢幕高度為基準翻轉）。
    public static func convert(cgBounds: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: cgBounds.origin.x,
               y: primaryHeight - (cgBounds.origin.y + cgBounds.height),
               width: cgBounds.width,
               height: cgBounds.height)
    }

    /// 由前到後第一個含點的視窗框（windows 陣列序＝z-order 前→後）；無命中回 nil。
    public static func hitTest(point: CGPoint, windows: [WindowInfo]) -> CGRect? {
        windows.first(where: { $0.frameGlobal.contains(point) })?.frameGlobal
    }

    /// 從 CGWindowList 原始 dict 陣列建清單：只收一般視窗（layer == 0）、面積 > 1，
    /// 依原陣列序（CGWindowListCopyWindowInfo 文件明訂＝前→後）。
    public static func makeWindowList(raw: [[String: Any]], primaryHeight: CGFloat) -> [WindowInfo] {
        raw.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width * bounds.height > 1
            else { return nil }
            return WindowInfo(frameGlobal: convert(cgBounds: bounds, primaryHeight: primaryHeight))
        }
    }

    /// 目前螢幕上的視窗清單（前→後）。失敗回空陣列——偵測 degrade、不擋截圖（spec）。
    public static func currentWindowList(primaryHeight: CGFloat) -> [WindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return makeWindowList(raw: raw, primaryHeight: primaryHeight)
    }
}
