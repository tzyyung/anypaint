import AnypaintKit
import CoreGraphics
import Foundation

/// 補 Annotation 子系統稽核抓到的 3 個純函式缺測。
nonisolated func annotationGapTests() {
    let style = AnnotationStyle(color: .red, lineWidth: 4)

    // 1) AnnotationDocument.update(id:_:) 單發：改動生效、可 undo、單次 undo 復原
    //    （與 updateWithoutSnapshot 的區別＝它自己 push 一個快照）
    let doc = AnnotationDocument()
    let a = Annotation(shape: .rect(CGRect(x: 0, y: 0, width: 10, height: 10)), style: style)
    doc.add(a)
    doc.update(id: a.id) { $0.move(by: CGVector(dx: 5, dy: 3)) }
    T.checkEq("update: 改動生效", doc.objects[0].bounds.origin, CGPoint(x: 5, y: 3))
    T.checkTrue("update: 可 undo", doc.canUndo)
    doc.undo()
    T.checkEq("update: 單次 undo 復原", doc.objects[0].bounds.origin, CGPoint.zero)
    // 不存在的 id → no-op、不 crash
    doc.update(id: UUID()) { $0.move(by: CGVector(dx: 99, dy: 99)) }
    T.checkEq("update: 不存在 id 無副作用", doc.objects[0].bounds.origin, CGPoint.zero)

    // 2) AnnotationColor.contrastingTextCGColor：淺色配黑字、深色配白字
    func comps(_ c: CGColor) -> [CGFloat] { c.components ?? [] }
    let whiteText = comps(AnnotationColor.white.contrastingTextCGColor)
    T.checkTrue("contrastText: 白圈→黑字(0,0,0)",
                whiteText.count >= 3 && whiteText[0] == 0 && whiteText[1] == 0 && whiteText[2] == 0)
    let yellowText = comps(AnnotationColor.yellow.contrastingTextCGColor)
    T.checkTrue("contrastText: 黃圈→黑字", yellowText.count >= 3 && yellowText[0] == 0)
    let redText = comps(AnnotationColor.red.contrastingTextCGColor)
    T.checkTrue("contrastText: 紅圈→白字(1,1,1)",
                redText.count >= 3 && redText[0] == 1 && redText[1] == 1 && redText[2] == 1)
    let blackText = comps(AnnotationColor.black.contrastingTextCGColor)
    T.checkTrue("contrastText: 黑圈→白字", blackText.count >= 3 && blackText[0] == 1)

    // 3) .measure 渲染分支（drawMeasurementLabel）——先前從未被任何測試渲染過。
    //    渲染一個 .measure 到離屏 bitmap,驗證其 bounds 內出現非透明像素（標籤底＋虛線框有畫出來）。
    let w = 200, h = 120
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let m = Annotation(shape: .measure(from: CGPoint(x: 20, y: 20),
                                       to: CGPoint(x: 160, y: 90), pixelScale: 2),
                       style: AnnotationStyle(color: .red, lineWidth: 4))
    buf.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        AnnotationRenderer.render([m], in: ctx)
    }
    var litPixels = 0
    for i in stride(from: 3, to: buf.count, by: 4) where buf[i] > 0 { litPixels += 1 }
    T.checkTrue(".measure 渲染: 有非透明像素（標籤/框已畫）", litPixels > 0)

    // 4) AnnotationDocument.hitTestAll：由上而下（最上層在前）、只回命中的（重疊循環選取用）。
    let d2 = AnnotationDocument()
    let low = Annotation(shape: .rect(CGRect(x: 0, y: 0, width: 100, height: 100)), style: style)
    let high = Annotation(shape: .rect(CGRect(x: 50, y: 50, width: 100, height: 100)), style: style)
    d2.add(low); d2.add(high)   // high 後加＝在上層
    let both = d2.hitTestAll(at: CGPoint(x: 75, y: 75))   // 重疊區
    T.checkEq("hitTestAll: 重疊回兩個", both.count, 2)
    T.checkEq("hitTestAll: 最上層在前", both.first?.id, high.id)
    T.checkEq("hitTestAll: 只命中 low 的區域", d2.hitTestAll(at: CGPoint(x: 10, y: 10)).map(\.id), [low.id])
    T.checkTrue("hitTestAll: 空白回空", d2.hitTestAll(at: CGPoint(x: 500, y: 500)).isEmpty)

    // 5) snapshotObjects / restore：surface 換底圖存/還原整份標註,並清空 undo/redo 與選取。
    let d3 = AnnotationDocument()
    d3.add(a)
    let snap = d3.snapshotObjects()
    T.checkEq("snapshotObjects: 複本內容", snap.map(\.id), [a.id])
    d3.selectedID = a.id
    d3.restore(objects: [])
    T.checkTrue("restore: 換成空", d3.isEmpty)
    T.checkTrue("restore: 清 undo", !d3.canUndo)
    T.checkTrue("restore: 清選取", d3.selectedID == nil)
    d3.restore(objects: snap)
    T.checkEq("restore: 還原回內容", d3.objects.map(\.id), [a.id])

    // 6) AnnotationInput.nextSelection：重疊循環選取決策
    let id0 = UUID(), id1 = UUID(), id2 = UUID()
    T.checkEq("nextSelection: 無選取→最上層", AnnotationInput.nextSelection(hits: [id0, id1], current: nil), id0)
    T.checkEq("nextSelection: 選中最上→下一個", AnnotationInput.nextSelection(hits: [id0, id1], current: id0), id1)
    T.checkEq("nextSelection: 選中最後→循環回第一", AnnotationInput.nextSelection(hits: [id0, id1], current: id1), id0)
    T.checkEq("nextSelection: current 不在命中清單→最上層",
              AnnotationInput.nextSelection(hits: [id0, id1], current: id2), id0)
    T.checkTrue("nextSelection: 空→nil", AnnotationInput.nextSelection(hits: [], current: id0) == nil)
}
