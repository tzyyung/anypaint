import CoreGraphics

/// 座標轉換工具（純函式、可單元測試）。
///
/// 為什麼需要：AppKit 螢幕/視窗座標原點在**左下**、Y 向上；
/// 而 CGImage 的像素座標原點在**左上**、Y 向下。截圖裁切時必須翻轉 Y，
/// 且要乘上 Retina 的 pixel scale 才能對到影像的實際像素。這是最容易錯的地方。
public enum CoordinateUtils {

    /// 把「overlay 視圖內的選取矩形（點、左下原點）」轉成
    /// 「凍結影像的裁切矩形（像素、左上原點）」。
    ///
    /// - Parameters:
    ///   - selection: 選取框，座標相對於該 display 的 overlay 視圖，單位為點，原點左下。
    ///   - displayPointSize: 該 display 的邏輯尺寸（點）。
    ///   - scale: 該 display 的 pixel scale（Retina 通常為 2）。
    /// - Returns: 對齊整數的像素裁切矩形（左上原點），可直接餵給 CGImage.cropping。
    public static func pixelCropRect(selection: CGRect,
                                     displayPointSize: CGSize,
                                     scale: CGFloat) -> CGRect {
        let flippedY = displayPointSize.height - (selection.origin.y + selection.height)
        let rect = CGRect(
            x: selection.origin.x * scale,
            y: flippedY * scale,
            width: selection.width * scale,
            height: selection.height * scale
        )
        return rect.integral
    }

    /// 由兩個拖曳端點算出正規化矩形（永遠正的寬高）。
    public static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    /// 把「overlay 視圖內的選取框（點、左下原點）」平移成 AppKit 全域座標的框。
    /// overlay 視窗蓋滿整個螢幕（view 座標 == 視窗座標），所以只需加上視窗全域原點；
    /// 次螢幕的原點可能為負值，直接相加即正確。
    public static func globalRect(selection: CGRect, windowOrigin: CGPoint) -> CGRect {
        CGRect(x: selection.origin.x + windowOrigin.x,
               y: selection.origin.y + windowOrigin.y,
               width: selection.width,
               height: selection.height)
    }

    /// 以指定中心點放置指定尺寸的框（貼圖「貼在游標處」用）。
    public static func centeredRect(at center: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: center.x - size.width / 2,
               y: center.y - size.height / 2,
               width: size.width,
               height: size.height)
    }

    /// 長邊縮到 maxEdge 的等比尺寸；已不大於 maxEdge（或零尺寸）回原尺寸（貼圖快速縮圖）。
    public static func thumbnailSize(for size: CGSize, maxEdge: CGFloat) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > maxEdge, longest > 0 else { return size }
        let scale = maxEdge / longest
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// 以 rect 中心為錨、換成 newSize 的新 rect（貼圖縮放/縮圖/重設共用）。
    public static func rectResized(_ rect: CGRect, to newSize: CGSize) -> CGRect {
        CGRect(x: rect.midX - newSize.width / 2,
               y: rect.midY - newSize.height / 2,
               width: newSize.width,
               height: newSize.height)
    }

    /// 在 anchor 旁擺放 size 的視窗框（OCR 結果窗）：右側優先、放不下換左側、
    /// 兩側都不夠疊在 anchor 內緣（clamp 進 screen）；頂邊與 anchor 頂對齊、垂直 clamp。
    public static func sideRect(beside anchor: CGRect, size: CGSize,
                                in screen: CGRect, gap: CGFloat = 8) -> CGRect {
        var origin = CGPoint(x: anchor.maxX + gap, y: anchor.maxY - size.height)
        if origin.x + size.width > screen.maxX {
            origin.x = anchor.minX - gap - size.width
        }
        if origin.x < screen.minX {
            origin.x = min(max(screen.minX, anchor.minX), screen.maxX - size.width)
        }
        origin.y = min(max(screen.minY, origin.y), screen.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }
}
