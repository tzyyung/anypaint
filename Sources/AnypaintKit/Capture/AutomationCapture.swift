import CoreGraphics

/// 非互動（RPC/AI 自行調用）截圖的**純幾何**：把全域選區對應到「哪個螢幕、該螢幕上的像素裁切矩形」。
/// 與 ScreenCaptureKit/AppKit 無關,selftest 可測;實際擷取與裁切像素由呼叫端做。
public enum AutomationCapture {

    /// 一個螢幕的幾何（DisplaySnapshot 的可測子集）。
    public struct DisplayGeometry: Equatable {
        public let frameGlobal: CGRect   // AppKit 全域座標(點,左下原點)
        public let pointSize: CGSize     // 邏輯尺寸(點)
        public let scale: CGFloat        // pixel scale
        public init(frameGlobal: CGRect, pointSize: CGSize, scale: CGFloat) {
            self.frameGlobal = frameGlobal; self.pointSize = pointSize; self.scale = scale
        }
    }

    /// 選區裁切計畫：全域選區 `globalRect` 必須**完整落在**某個螢幕內（比照錄影 presentLocked
    /// 的紀律,跨螢幕選區不受支援）,回傳該螢幕 index 與其上的像素裁切矩形（左上原點,已 Y 翻轉×scale）；
    /// 沒有任何螢幕完整包住＝nil（呼叫端回 badRect）。
    public static func cropPlan(globalRect: CGRect, displays: [DisplayGeometry]) -> (index: Int, pixelCrop: CGRect)? {
        guard let index = displays.firstIndex(where: { $0.frameGlobal.contains(globalRect) }) else { return nil }
        let d = displays[index]
        // 全域→該螢幕本地(減螢幕原點)→像素裁切(CoordinateUtils.pixelCropRect 做 Y 翻轉+scale)。
        let local = CGRect(x: globalRect.minX - d.frameGlobal.minX, y: globalRect.minY - d.frameGlobal.minY,
                           width: globalRect.width, height: globalRect.height)
        let pixelCrop = CoordinateUtils.pixelCropRect(selection: local, displayPointSize: d.pointSize, scale: d.scale)
        return (index, pixelCrop)
    }
}
