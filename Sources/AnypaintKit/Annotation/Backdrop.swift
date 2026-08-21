import Foundation
import CoreGraphics

/// #1 美化背景（Backdrop）：把截圖放到裝飾背景上（padding＋背景＋圓角＋陰影）。
/// 這裡是**純資料與版面**，零 UI 依賴；渲染在 `BackdropRenderer`、view 接線在 SelectionView。

/// 背景選項：一組精選純色＋線性漸層＋桌布（放射漸層）預設（CaseIterable → 面板逐一列出）。
public enum BackdropBackground: String, CaseIterable {
    // 純色
    case white, graphite, indigo
    // 線性漸層（由左上到右下兩色標）
    case sunset, ocean, mint, grape
    // 桌布（放射漸層，中心→外圈；比線性更有「桌布」感）
    case aurora, bloom, dusk

    public var displayName: String {
        switch self {
        case .white: return "米白"
        case .graphite: return "石墨"
        case .indigo: return "靛藍"
        case .sunset: return "日落"
        case .ocean: return "海洋"
        case .mint: return "薄荷"
        case .grape: return "葡萄"
        case .aurora: return "極光"
        case .bloom: return "花漾"
        case .dusk: return "暮色"
        }
    }

    /// 有漸層（線性或放射）；純色回 false。
    public var isGradient: Bool { gradientColors != nil }
    /// 放射漸層（桌布類）；線性漸層與純色回 false。
    public var isRadial: Bool {
        switch self {
        case .aurora, .bloom, .dusk: return true
        default: return false
        }
    }

    private static func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// 純色的顏色；漸層回 nil。
    public var solidColor: CGColor? {
        switch self {
        case .white:    return Self.c(0.96, 0.96, 0.97)
        case .graphite: return Self.c(0.16, 0.17, 0.20)
        case .indigo:   return Self.c(0.20, 0.23, 0.44)
        default:        return nil
        }
    }

    /// 漸層的兩個色標（線性＝左上→右下；放射＝中心→外圈）；純色回 nil。
    public var gradientColors: [CGColor]? {
        switch self {
        case .white, .graphite, .indigo: return nil
        case .sunset: return [Self.c(1.000, 0.494, 0.373), Self.c(0.996, 0.706, 0.482)]
        case .ocean:  return [Self.c(0.129, 0.576, 0.690), Self.c(0.427, 0.835, 0.929)]
        case .mint:   return [Self.c(0.263, 0.914, 0.482), Self.c(0.220, 0.976, 0.843)]
        case .grape:  return [Self.c(0.498, 0.000, 1.000), Self.c(0.882, 0.000, 1.000)]
        case .aurora: return [Self.c(0.435, 0.855, 0.753), Self.c(0.180, 0.208, 0.373)]  // 中心青綠→外深藍
        case .bloom:  return [Self.c(1.000, 0.780, 0.870), Self.c(0.541, 0.170, 0.470)]  // 中心粉→外莓紫
        case .dusk:   return [Self.c(1.000, 0.639, 0.400), Self.c(0.204, 0.157, 0.365)]  // 中心橘→外靛
        }
    }
}

/// 一次美化的樣式參數。padding／圓角以**點**表示（跨 DPI 一致，渲染時乘 scale）。
public struct BackdropStyle: Equatable {
    public var background: BackdropBackground
    /// 自訂純色背景（非 nil 時**蓋過** `background` 預設，填成這個純色）。
    public var customColor: CGColor?
    public var paddingPt: CGFloat
    public var cornerRadiusPt: CGFloat
    public var shadow: Bool

    /// padding 範圍 0–160pt、圓角 0–48pt（面板 slider 上下限,寫入路徑一律夾限）。
    public static let paddingRange: ClosedRange<CGFloat> = 0...160
    public static let cornerRange: ClosedRange<CGFloat> = 0...48

    public init(background: BackdropBackground = .sunset, customColor: CGColor? = nil, paddingPt: CGFloat = 48,
                cornerRadiusPt: CGFloat = 14, shadow: Bool = true) {
        self.background = background
        self.customColor = customColor
        self.paddingPt = BackdropStyle.clampPadding(paddingPt)
        self.cornerRadiusPt = BackdropStyle.clampCorner(cornerRadiusPt)
        self.shadow = shadow
    }

    public static func clampPadding(_ v: CGFloat) -> CGFloat {
        min(paddingRange.upperBound, max(paddingRange.lowerBound, v))
    }
    public static func clampCorner(_ v: CGFloat) -> CGFloat {
        min(cornerRange.upperBound, max(cornerRange.lowerBound, v))
    }
}

/// Backdrop 版面計算（純函式）：由來源尺寸＋padding 算輸出尺寸與內容置放矩形。
public enum BackdropLayout {
    /// 輸出尺寸（像素）＝來源四周各加 padding×scale。
    public static func outputSize(sourcePixelSize: CGSize, paddingPt: CGFloat, scale: CGFloat) -> CGSize {
        let pad = max(0, paddingPt) * scale
        return CGSize(width: sourcePixelSize.width + pad * 2,
                      height: sourcePixelSize.height + pad * 2)
    }

    /// 內容矩形（來源在輸出中的置放矩形，像素，左下原點——對齊 CGContext）：置中、四周等距 padding。
    public static func contentRect(sourcePixelSize: CGSize, paddingPt: CGFloat, scale: CGFloat) -> CGRect {
        let pad = max(0, paddingPt) * scale
        return CGRect(x: pad, y: pad, width: sourcePixelSize.width, height: sourcePixelSize.height)
    }

    /// 內容圓角的像素半徑：點半徑×scale，且不超過來源短邊一半（避免膠囊化過頭）。
    public static func cornerRadiusPx(cornerRadiusPt: CGFloat, sourcePixelSize: CGSize, scale: CGFloat) -> CGFloat {
        let half = min(sourcePixelSize.width, sourcePixelSize.height) / 2
        return min(max(0, cornerRadiusPt) * scale, half)
    }
}
