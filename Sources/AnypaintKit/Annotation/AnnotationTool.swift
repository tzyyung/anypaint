import Foundation

/// 標註工具（階段 2：四種繪製工具；階段 3–5 再加 text/counter/freehand/highlighter/pixelate/select，
/// 加 case 時編譯器會點名 toolbar 的 symbol 對照表）。
public enum AnnotationTool: String, CaseIterable {
    case rect, ellipse, line, arrow
}

/// 每種工具各自記住上次的樣式（UserDefaults；spec 定案「每工具各自記」）。
public enum AnnotationStyleStore {
    private static func colorKey(_ t: AnnotationTool) -> String { "annotationStyle.\(t.rawValue).color" }
    private static func thicknessKey(_ t: AnnotationTool) -> String { "annotationStyle.\(t.rawValue).thickness" }

    /// 讀取工具的記憶樣式；沒存過＝紅色中筆。
    public static func style(for tool: AnnotationTool) -> AnnotationStyle {
        let d = UserDefaults.standard
        let color = d.string(forKey: colorKey(tool)).flatMap(AnnotationColor.init(rawValue:)) ?? .red
        let thickness = d.string(forKey: thicknessKey(tool)).flatMap(AnnotationThickness.init(rawValue:)) ?? .medium
        return AnnotationStyle(color: color, thickness: thickness)
    }

    public static func save(_ style: AnnotationStyle, for tool: AnnotationTool) {
        let d = UserDefaults.standard
        d.set(style.color.rawValue, forKey: colorKey(tool))
        d.set(style.thickness.rawValue, forKey: thicknessKey(tool))
    }

    /// 清掉某工具的記憶（selftest 用，讓 default 測試可重複執行）。
    public static func reset(for tool: AnnotationTool) {
        let d = UserDefaults.standard
        d.removeObject(forKey: colorKey(tool))
        d.removeObject(forKey: thicknessKey(tool))
    }
}
