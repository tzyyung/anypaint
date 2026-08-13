import CoreGraphics

/// 選取框控制點／放大鏡／十字帶／角落縮放的**純幾何**（無 AppKit、無 view 狀態,selftest 可測）。
/// 這些公式原本內嵌在 `SelectionView`（internal NSView，測不到）與 `ScrollSelectionView` 各一份,
/// 抽出來統一並可單元驗證——把「幾何」與「NSView 繪製/事件」分開（humble object）。
public enum SelectionGeometry {

    /// 8 個控制點,固定順序（對應 SelectionView.Handle.allCases）：
    /// 左上、上中、右上、右中、右下、下中、左下、左中。座標系左下原點（maxY＝上緣）。
    public static func handlePoints(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
         CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.midX, y: r.minY),
         CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX, y: r.midY)]
    }

    /// 以控制點為中心的方形命中/繪製區。
    public static func handleRect(at p: CGPoint, size: CGFloat) -> CGRect {
        CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
    }

    /// 命中第幾個控制點（±tolerance 外擴容差）；沒中回 nil。呼叫端把 index 映射到自己的 Handle。
    public static func hitHandleIndex(_ point: CGPoint, in r: CGRect,
                                      size: CGFloat, tolerance: CGFloat = 4) -> Int? {
        for (i, p) in handlePoints(r).enumerated() {
            if handleRect(at: p, size: size).insetBy(dx: -tolerance, dy: -tolerance).contains(point) {
                return i
            }
        }
        return nil
    }

    /// 選取框 8 向控制點（順序須與 `handlePoints` 一致）。
    public enum ResizeEdge: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    /// 由拖曳某控制點算新選取框；允許拖過頭翻轉,用 min/max 正規化。
    public static func resized(_ start: CGRect, edge: ResizeEdge, to p: CGPoint) -> CGRect {
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        switch edge {
        case .topLeft:     minX = p.x; maxY = p.y
        case .top:         maxY = p.y
        case .topRight:    maxX = p.x; maxY = p.y
        case .right:       maxX = p.x
        case .bottomRight: maxX = p.x; minY = p.y
        case .bottom:      minY = p.y
        case .bottomLeft:  minX = p.x; minY = p.y
        case .left:        minX = p.x
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY),
                      width: abs(maxX - minX), height: abs(maxY - minY))
    }

    /// 點 clamp 進 [0,size]。
    public static func clampPoint(_ p: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, p.x), size.width), y: min(max(0, p.y), size.height))
    }

    /// 矩形 clamp 進 [0,size]（只移原點、不改尺寸；rect 比 size 大時原點被夾成負值,行為與既有一致）。
    public static func clampRectOrigin(_ r: CGRect, in size: CGSize) -> CGRect {
        var out = r
        out.origin.x = min(max(0, r.origin.x), size.width - r.width)
        out.origin.y = min(max(0, r.origin.y), size.height - r.height)
        return out
    }

    /// 選取框是否夠大（寬高都需 > minSize）；nil 選區＝無效。
    public static func isValidSelectionSize(_ r: CGRect?, minSize: CGFloat) -> Bool {
        guard let r else { return false }
        return r.width > minSize && r.height > minSize
    }

    /// 四角（標註物件縮放用）。
    public enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    /// 四角座標,固定順序（左上、右上、左下、右下）。
    public static func cornerPoints(_ r: CGRect) -> [(Corner, CGPoint)] {
        [(.topLeft, CGPoint(x: r.minX, y: r.maxY)), (.topRight, CGPoint(x: r.maxX, y: r.maxY)),
         (.bottomLeft, CGPoint(x: r.minX, y: r.minY)), (.bottomRight, CGPoint(x: r.maxX, y: r.minY))]
    }

    /// 命中第幾角（±tolerance）；沒中回 nil。
    public static func hitCorner(_ point: CGPoint, in r: CGRect,
                                 size: CGFloat, tolerance: CGFloat = 4) -> Corner? {
        for (corner, p) in cornerPoints(r) {
            if handleRect(at: p, size: size).insetBy(dx: -tolerance, dy: -tolerance).contains(point) {
                return corner
            }
        }
        return nil
    }

    /// 由拖出的某一角算新 bounds；允許拖過頭翻轉,用 min/max 正規化成正寬高。
    public static func resizedBounds(_ start: CGRect, corner: Corner, to p: CGPoint) -> CGRect {
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        switch corner {
        case .topLeft:     minX = p.x; maxY = p.y
        case .topRight:    maxX = p.x; maxY = p.y
        case .bottomLeft:  minX = p.x; minY = p.y
        case .bottomRight: maxX = p.x; minY = p.y
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY),
                      width: abs(maxX - minX), height: abs(maxY - minY))
    }

    /// 放大鏡位置：預設在游標右下 16pt 外；碰到右/下邊界翻到另一側,最後 clamp 進畫面。
    public static func loupeRect(at p: CGPoint, in bounds: CGSize, side: CGFloat) -> CGRect {
        var lx = p.x + 16
        var ly = p.y - 16 - side
        if lx + side > bounds.width { lx = p.x - 16 - side }
        if ly < 0 { ly = p.y + 16 }
        lx = min(max(0, lx), bounds.width - side)
        ly = min(max(0, ly), bounds.height - side)
        return CGRect(x: lx, y: ly, width: side, height: side)
    }

    /// 游標點（左下原點、點）→ 快照像素座標（左上原點、像素,clamp 進影像範圍）。
    public static func samplePixelCoord(at p: CGPoint, scale: CGFloat,
                                        imageWidth: Int, imageHeight: Int,
                                        viewHeight: CGFloat) -> (x: Int, y: Int) {
        let x = min(max(0, Int(p.x * scale)), imageWidth - 1)
        let y = min(max(0, Int((viewHeight - p.y) * scale)), imageHeight - 1)
        return (x, y)
    }

    /// 十字線垂直帶（±2pt 涵蓋反鋸齒與像素格對齊位移）。
    public static func crosshairBandVertical(atX x: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: x - 2, y: 0, width: 4, height: height)
    }

    /// 十字線水平帶。
    public static func crosshairBandHorizontal(atY y: CGFloat, width: CGFloat) -> CGRect {
        CGRect(x: 0, y: y - 2, width: width, height: 4)
    }

    /// HUD 浮層位置：預設在選區下緣外 12pt、水平置中；下方超出可視區 → 翻到上緣外；
    /// 最後水平 clamp 進可視區（避免貼邊選區把 HUD 推出畫面）。ScrollHUD 與 RecordHUD 共用。
    public static func hudOrigin(selection: CGRect, panelSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        var origin = CGPoint(x: selection.midX - panelSize.width / 2,
                             y: selection.minY - panelSize.height - 12)
        if origin.y < visibleFrame.minY { origin.y = selection.maxY + 12 }
        origin.x = min(max(visibleFrame.minX, origin.x), visibleFrame.maxX - panelSize.width)
        return origin
    }
}
