import Foundation
import CoreGraphics

/// 把標註畫進任意 CGContext。畫面預覽（SelectionView.draw）與最終擷取合成
/// 共用這一份 → 所見即所存。座標原點/翻轉由呼叫端的 context 決定，
/// 這裡只按給定座標畫路徑（階段 1 的形狀對翻轉不敏感）。
public enum AnnotationRenderer {

    /// 依陣列順序（＝z-order）逐一渲染。
    public static func render(_ objects: [Annotation], in ctx: CGContext) {
        for a in objects { render(a, in: ctx) }
    }

    static func render(_ a: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        let color = a.style.color.cgColor
        let lw = a.style.thickness.lineWidth
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(lw)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        switch a.shape {
        case .rect(let r):
            ctx.stroke(r)

        case .ellipse(let r):
            ctx.strokeEllipse(in: r)

        case .line(let from, let to):
            ctx.move(to: from)
            ctx.addLine(to: to)
            ctx.strokePath()

        case .arrow(let from, let to):
            // 線段畫到箭頭底部，頭部用實心三角（頭長 = max(10, 線寬×3)，spec）。
            let head = max(10, lw * 3)
            let angle = atan2(to.y - from.y, to.x - from.x)
            let base = CGPoint(x: to.x - head * cos(angle), y: to.y - head * sin(angle))
            ctx.move(to: from)
            ctx.addLine(to: base)
            ctx.strokePath()
            let half = head * 0.5
            let p1 = CGPoint(x: base.x - half * sin(angle), y: base.y + half * cos(angle))
            let p2 = CGPoint(x: base.x + half * sin(angle), y: base.y - half * cos(angle))
            ctx.move(to: to)
            ctx.addLine(to: p1)
            ctx.addLine(to: p2)
            ctx.closePath()
            ctx.fillPath()

        case .counter:
            // 序號渲染（圓＋數字，需編號與 CoreText）在階段 3 實作；
            // 編號來自 AnnotationDocument.counterNumber(for:)，renderer 屆時加參數。
            break
        }
    }
}
