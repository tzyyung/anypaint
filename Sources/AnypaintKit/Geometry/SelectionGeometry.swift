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

    /// 控制點對應的縮放游標軸向（對角 NWSE/NESW、水平 EW、垂直 NS）。
    public enum ResizeAxis: Equatable { case nwse, nesw, ew, ns }

    /// 控制點 → 游標軸向（cursor(at:) 的純對應部分）。
    public static func resizeAxis(for edge: ResizeEdge) -> ResizeAxis {
        switch edge {
        case .topLeft, .bottomRight: return .nwse
        case .topRight, .bottomLeft: return .nesw
        case .left, .right:          return .ew
        case .top, .bottom:          return .ns
        }
    }

    /// 四角 → 游標軸向（標註物件縮放只有對角,無 EW/NS）。
    public static func resizeAxis(for corner: Corner) -> ResizeAxis {
        switch corner {
        case .topLeft, .bottomRight: return .nwse
        case .topRight, .bottomLeft: return .nesw
        }
    }

    /// 游標種類（view 把它映射成實際 NSCursor）。
    public enum CursorKind: Equatable { case arrow, openHand, crosshair, resize(ResizeAxis) }

    /// select 工具的游標：命中選取物件角落 handle→縮放游標;命中任一物件→openHand;否則 arrow。
    public static func selectToolCursor(cornerAxis: ResizeAxis?, hitAnyObject: Bool) -> CursorKind {
        if let cornerAxis { return .resize(cornerAxis) }
        return hitAnyObject ? .openHand : .arrow
    }

    /// cursor(at:) 主決策樹（純：把 view 狀態濃縮成幾個旗標）。層序與原本逐條相同。
    /// - edgeAxis：只有「有選取且未鎖框且命中控制點」時才非 nil（呼叫端負責 gate）。
    /// - insideSelection：只有「有選取且未鎖框且點在選區內」時才 true。
    public static func cursorKind(toolbarHit: Bool, isTextTool: Bool, textHover: Bool,
                                  isSelectTool: Bool, selectCursor: CursorKind,
                                  isDrawingTool: Bool, edgeAxis: ResizeAxis?, insideSelection: Bool) -> CursorKind {
        if toolbarHit { return .arrow }
        if isTextTool, textHover { return .openHand }
        if isSelectTool { return selectCursor }
        if isDrawingTool { return .crosshair }
        if let edgeAxis { return .resize(edgeAxis) }
        if insideSelection { return .openHand }
        return .crosshair
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

    /// 選取框兩邊是否都達最小邊長（≥,含相等）——錄影最小選區門檻用（點座標）。
    public static func meetsMinEdge(_ size: CGSize, min: CGFloat) -> Bool {
        size.width >= min && size.height >= min
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

    /// 視窗偵測候選框（游標懸在某視窗上時提亮的區域）：命中某視窗＝把它的全域框轉成本 view 座標
    /// （減 frameOrigin）再與 viewBounds 取交集（跨螢幕視窗 clamp 進本螢幕）；沒命中＝整個 viewBounds
    /// （桌面＝整顆螢幕）。純座標運算,WindowDetector 的命中判定留在呼叫端。
    public static func windowCandidate(hit: CGRect?, frameOrigin: CGPoint, viewBounds: CGRect) -> CGRect {
        guard let hit else { return viewBounds }
        return CGRect(x: hit.origin.x - frameOrigin.x, y: hit.origin.y - frameOrigin.y,
                      width: hit.width, height: hit.height).intersection(viewBounds)
    }

    /// 程式化鎖定選區的驗證＋座標轉換：globalRect 必須落在該螢幕 frame 內,否則回 nil（拒絕鎖定）；
    /// 通過則轉成該螢幕的 overlay 本地座標（減去螢幕原點）。ScrollSelectionOverlay.presentLocked 用。
    public static func validateAndLocalize(globalRect: CGRect, screenFrame: CGRect) -> CGRect? {
        guard screenFrame.contains(globalRect) else { return nil }
        return CGRect(x: globalRect.minX - screenFrame.minX, y: globalRect.minY - screenFrame.minY,
                      width: globalRect.width, height: globalRect.height)
    }

    /// HUD 浮層位置：預設在選區下緣外 12pt、水平置中；下方超出可視區 → 翻到上緣外；
    /// 最後水平**與垂直**都 clamp 進可視區。ScrollHUD 與 RecordHUD 共用。
    /// 垂直 clamp（審查 #5）：貼滿可視高度的選區時，下方與翻上後的上方都放不下、HUD 會跑出畫面頂端
    /// （開始/停止/取消整排消失，只能靠全域快鍵逃生）。clamp 後最差情況是壓在選區邊上，但至少看得到、按得到。
    public static func hudOrigin(selection: CGRect, panelSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        var origin = CGPoint(x: selection.midX - panelSize.width / 2,
                             y: selection.minY - panelSize.height - 12)
        if origin.y < visibleFrame.minY { origin.y = selection.maxY + 12 }
        origin.x = min(max(visibleFrame.minX, origin.x), visibleFrame.maxX - panelSize.width)
        origin.y = min(max(visibleFrame.minY, origin.y), visibleFrame.maxY - panelSize.height)
        return origin
    }
}
