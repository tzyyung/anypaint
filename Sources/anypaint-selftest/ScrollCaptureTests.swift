import CoreGraphics
import Foundation
import Vision
import AnypaintKit

/// Task 2 實測結論：Vision alignmentTransform.ty 的單位（true=pixel）。
/// 實測（visionTyUnitTest，400×600 合成影格，B 相對 A 於頁面內向下捲 137px）：ty == -137.0（精確值，
/// 無次像素模糊——合成測資無縮放/濾波）。|ty|==137 與影像位移像素數一致 → 單位是 pixel（非 point、非
/// 0–1 normalized）。
///
/// 正負號規則（B 為 targeted/floating、A 為 handler/reference 時）：
/// Vision 內部座標系原點左下、y 軸向上（與 raster 的左上原點、y 向下相反）。alignmentTransform 是把
/// floating（B）對齊到 reference（A）的變換，即 P_A = P_B + (tx, ty)（純平移下）。
/// 因此 ty = (A 在 Vision y-up 座標系的 y) − (B 在 Vision y-up 座標系的 y)。
/// B 的內容若在 raster 座標（左上原點）相對 A 向下捲動（raster row 增加、頁面往下滑），
/// 在 y-up 座標系裡等於「變高」，故 ty 為負；換算回 raster 的向下捲動量（正值＝向下捲）＝ -ty。
/// Task 12 對帳時直接用：scrollDownPixels = -ty。
/// 由 visionTyUnitTest 持續看守——Vision 行為改變時此測試會先紅。
let visionTyIsInPixels = true

func runScrollCaptureTests() {
    visionTyUnitTest()
    pixelBufferTests()
    scrollCoordsTests()
}

/// 量測 Vision registration 回傳的 ty 單位：
/// 造兩張 400×600 的合成影格，B 相對 A 往下捲 137 px（質數避開巧合）。
/// 期望 ty == -137（B 需上移 137px 對齊 A）或 +137——正負號與 pixel/point 皆以本測試輸出為準，
/// 測出後把斷言鎖死成文件。
func visionTyUnitTest() {
    let page = SyntheticPage.make(width: 400, height: 1200, seed: 42)
    let a = SyntheticPage.window(page, y: 0, height: 600)
    let b = SyntheticPage.window(page, y: 137, height: 600)
    guard let cgA = a.makeCGImage(), let cgB = b.makeCGImage() else {
        T.checkTrue("vision-ty: 測資轉 CGImage", false); return
    }
    let request = VNTranslationalImageRegistrationRequest(targetedCGImage: cgB)
    let handler = VNImageRequestHandler(cgImage: cgA, options: [:])
    do { try handler.perform([request]) } catch {
        T.checkTrue("vision-ty: perform 不丟錯（\(error)）", false); return
    }
    guard let obs = request.results?.first else {
        T.checkTrue("vision-ty: 有 observation", false); return
    }
    let ty = obs.alignmentTransform.ty
    // 第一次執行時先印出實測值，據此把下面斷言的期望值鎖死：
    print("ℹ️ vision-ty 實測值：\(ty)（影像位移 137px）")
    // 實測鎖死：ty == -137.0（精確、無次像素模糊——合成測資無縮放/濾波）。
    // 單位＝pixel：|ty| 與影像位移像素數相符（非 0–1 normalized、非 point）。
    T.checkTrue("vision-ty: |ty| == 137（單位為 pixel）", abs(abs(ty) - 137) < 1.5)
    // 正負號：B（targeted/floating）相對 A（reference）在頁面內向下捲 137px → ty 為負
    // （見上方 visionTyIsInPixels 常數註解的完整推導；Task 12 用 scrollDownPixels = -ty）。
    T.checkTrue("vision-ty: 向下捲動時 ty 為負（符號規則）", ty < 0)
}

func pixelBufferTests() {
    // CGImage 往返
    let page = SyntheticPage.make(width: 64, height: 64, seed: 1)
    if let cg = page.makeCGImage(), let back = PixelBuffer(cgImage: cg) {
        T.checkEq("pixelbuffer: CGImage 往返尺寸", back.width * 10000 + back.height, 64 * 10000 + 64)
        T.checkTrue("pixelbuffer: CGImage 往返內容一致",
                    zip(back.bytes, page.bytes).allSatisfy { abs(Int($0) - Int($1)) <= 2 })  // 色彩管理容差
    } else { T.checkTrue("pixelbuffer: CGImage 往返", false) }

    // 通道順序鑑別：灰階測資對 R/B 對調零鑑別力（審查 Important）——用彩色像素守 RGBA 順序。
    var colored = [UInt8](repeating: 255, count: 2 * 2 * 4)
    colored[0] = 200; colored[1] = 10; colored[2] = 30    // (0,0) 偏紅
    colored[4] = 10; colored[5] = 200; colored[6] = 30    // (1,0) 偏綠
    colored[8] = 10; colored[9] = 30; colored[10] = 200   // (0,1) 偏藍
    let cbuf = PixelBuffer(width: 2, height: 2, bytes: colored)
    if let ccg = cbuf.makeCGImage(), let cback = PixelBuffer(cgImage: ccg) {
        T.checkTrue("pixelbuffer: 通道順序（R 像素 R>B）", cback.bytes[0] > 100 && cback.bytes[2] < 100)
        T.checkTrue("pixelbuffer: 通道順序（B 像素 B>R）", cback.bytes[10] > 100 && cback.bytes[8] < 100)
        T.checkTrue("pixelbuffer: 通道順序（G 像素）", cback.bytes[5] > 100)
    } else { T.checkTrue("pixelbuffer: 通道順序往返", false) }

    // crop
    let c = page.cropped(x: 8, y: 8, width: 16, height: 16)
    T.checkEq("pixelbuffer: crop 尺寸", c.width * 100 + c.height, 1616)
    T.checkEq("pixelbuffer: crop 內容（左上像素）",
              Int(c.bytes[0]), Int(page.bytes[(8 * 64 + 8) * 4]))

    // luma 翻轉自反
    let l = LumaPlane(page)
    T.checkTrue("luma: 翻轉兩次 == 原圖", l.flippedVertically().flippedVertically().v == l.v)
    // 降採樣尺寸
    T.checkEq("luma: 降採樣尺寸", l.downsampled().width * 100 + l.downsampled().height, 3232)

    // 奇數尺寸：捨去最後一列/欄（65→32）
    let odd = LumaPlane(width: 65, height: 65, v: [Float](repeating: 7, count: 65 * 65))
    T.checkEq("luma: 奇數降採樣 65→32", odd.downsampled().width * 100 + odd.downsampled().height, 3232)
}

func scrollCoordsTests() {
    // Retina 2x：主螢幕 1728×1117 點、選區 (100.3, 200.7, 300.2, 400.9)
    let g = ScrollCoords.streamGeometry(
        selectionGlobal: CGRect(x: 100.3, y: 200.7, width: 300.2, height: 400.9),
        screenFrameGlobal: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        scale: 2)
    // 手算（unit=0.5pt，origin 向下取整、max 向上取整到 0.5 倍數，已對答案鎖死）：
    //   alignedX   = floor(100.3/0.5)*0.5 = 100.0
    //   alignedY   = floor(200.7/0.5)*0.5 = 200.5
    //   alignedMaxX= ceil(400.5/0.5)*0.5  = 400.5   （selection.maxX = 100.3+300.2 = 400.5，恰為格點）
    //   alignedMaxY= ceil(601.6/0.5)*0.5  = 602.0   （selection.maxY = 200.7+400.9 = 601.6 → 上取到 602.0）
    //   w = 400.5-100.0 = 300.5, h = 602.0-200.5 = 401.5
    //   pixelWidth  = round(300.5*2) = 601
    //   pixelHeight = round(401.5*2) = 803
    T.checkEq("coords: pixelWidth", g.pixelWidth, Int(((400.5 - 100.0) * 2).rounded()))
    T.checkEq("coords: pixelHeight", g.pixelHeight, Int(((602.0 - 200.5) * 2).rounded()))
    T.checkTrue("coords: sourceRect minX", abs(g.sourceRect.minX - 100.0) < 0.001)
    T.checkTrue("coords: sourceRect width", abs(g.sourceRect.width - 300.5) < 0.001)
    T.checkTrue("coords: sourceRect Y 翻轉（上左原點）",
                abs(g.sourceRect.minY - (1117 - 200.5 - (602.0 - 200.5))) < 0.001)
    // scale=1 螢幕：對齊到整數點
    let g1 = ScrollCoords.streamGeometry(
        selectionGlobal: CGRect(x: 10.4, y: 20.6, width: 100.2, height: 50.9),
        screenFrameGlobal: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        scale: 1)
    T.checkTrue("coords: 副螢幕（負 x 全域座標）sourceRect 為螢幕相對", g1.sourceRect.minX >= 0)
    T.checkEq("coords: scale=1 pixelWidth == 點寬", g1.pixelWidth, 101)
    T.checkEq("coords: scale=1 pixelHeight == 點高", g1.pixelHeight, 52)
}
