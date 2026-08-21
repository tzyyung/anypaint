import AnypaintKit
import CoreGraphics

/// ImageTransform 純幾何：像素座標轉換、拉直尺寸推估、外接框。
nonisolated func imageTransformTests() {
    // imagePixel：view 左下原點 → 影像左上原點像素。view 高 100、scale 2。
    T.checkEq("xform: imagePixel 左下→左上×scale",
              ImageTransform.imagePixel(viewPoint: CGPoint(x: 10, y: 10), viewHeight: 100, scale: 2),
              CGPoint(x: 20, y: 180))
    T.checkEq("xform: imagePixel 頂端",
              ImageTransform.imagePixel(viewPoint: CGPoint(x: 0, y: 100), viewHeight: 100, scale: 2),
              CGPoint(x: 0, y: 0))

    // rectifiedSize：100×60 矩形四角 [tl,tr,br,bl]（任一致座標系）→ 100×60。
    let corners = [CGPoint(x: 0, y: 60), CGPoint(x: 100, y: 60),
                   CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 0)]
    T.checkEq("xform: rectifiedSize 正矩形", ImageTransform.rectifiedSize(corners: corners),
              CGSize(width: 100, height: 60))
    // 梯形：上邊 100、下邊 200 → 寬平均 150；斜邊長 hypot(50,100)=111.8 → 高取兩斜邊平均 112。
    let trap = [CGPoint(x: 50, y: 100), CGPoint(x: 150, y: 100),
                CGPoint(x: 200, y: 0), CGPoint(x: 0, y: 0)]
    T.checkEq("xform: rectifiedSize 梯形寬取平均、高取斜邊",
              ImageTransform.rectifiedSize(corners: trap), CGSize(width: 150, height: 112))
    T.checkEq("xform: rectifiedSize 非4角→zero",
              ImageTransform.rectifiedSize(corners: [.zero, .zero]), CGSize.zero)

    // pixelBoundingBox
    T.checkEq("xform: pixelBoundingBox",
              ImageTransform.pixelBoundingBox([CGPoint(x: 5, y: 8), CGPoint(x: 25, y: 8),
                                               CGPoint(x: 20, y: 40)]),
              CGRect(x: 5, y: 8, width: 20, height: 32))
}
