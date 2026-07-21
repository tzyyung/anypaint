import Foundation
import CoreGraphics

/// 標註工具（階段 2：四種繪製工具；階段 3–5 再加 text/counter/freehand/highlighter/pixelate/select，
/// 加 case 時編譯器會點名 toolbar 的 symbol 對照表）。
public enum AnnotationTool: String, CaseIterable {
    case rect, ellipse, line, arrow
}

/// 每種工具各自記住上次的樣式（UserDefaults；spec 定案「每工具各自記」）。
/// 粗細改連續值（spec 2026-07-22 修訂）後存 Double；舊版三檔字串鍵做一次性讀取遷移
/// （不寫回，讀到即用當次算出的值，下次 save 會自然寫成新鍵）。
public enum AnnotationStyleStore {
    private static func colorKey(_ t: AnnotationTool) -> String { "annotationStyle.\(t.rawValue).color" }
    private static func lineWidthKey(_ t: AnnotationTool) -> String { "annotationStyle.\(t.rawValue).lineWidth" }
    private static func legacyThicknessKey(_ t: AnnotationTool) -> String { "annotationStyle.\(t.rawValue).thickness" }

    /// 舊三檔字串鍵 → 新數值的一次性映射。
    private static func legacyLineWidth(for rawValue: String) -> CGFloat? {
        switch rawValue {
        case "thin": return 2
        case "medium": return 4
        case "thick": return 6
        default: return nil
        }
    }

    /// 讀取工具的記憶樣式；沒存過＝紅色、lineWidth 4。
    public static func style(for tool: AnnotationTool) -> AnnotationStyle {
        let d = UserDefaults.standard
        let color = d.string(forKey: colorKey(tool)).flatMap(AnnotationColor.init(rawValue:)) ?? .red
        let lineWidth = resolvedLineWidth(d, tool)
        return AnnotationStyle(color: color, lineWidth: lineWidth)
    }

    private static func resolvedLineWidth(_ d: UserDefaults, _ tool: AnnotationTool) -> CGFloat {
        // 新鍵存在 → 優先用它（object(forKey:) 而非 double(forKey:)，才能區分「沒存過」與「存了 0」）。
        if d.object(forKey: lineWidthKey(tool)) != nil {
            return AnnotationStyle.clampLineWidth(CGFloat(d.double(forKey: lineWidthKey(tool))))
        }
        if let legacy = d.string(forKey: legacyThicknessKey(tool)),
           let mapped = legacyLineWidth(for: legacy) {
            return mapped
        }
        return 4
    }

    public static func save(_ style: AnnotationStyle, for tool: AnnotationTool) {
        let d = UserDefaults.standard
        d.set(style.color.rawValue, forKey: colorKey(tool))
        d.set(Double(AnnotationStyle.clampLineWidth(style.lineWidth)), forKey: lineWidthKey(tool))
    }

    /// 清掉某工具的記憶（selftest 用，讓 default 測試可重複執行）。兩個 lineWidth 相關鍵都清，
    /// 含舊版三檔字串鍵，避免殘留影響下次讀取的遷移判斷。
    public static func reset(for tool: AnnotationTool) {
        let d = UserDefaults.standard
        d.removeObject(forKey: colorKey(tool))
        d.removeObject(forKey: lineWidthKey(tool))
        d.removeObject(forKey: legacyThicknessKey(tool))
    }
}
