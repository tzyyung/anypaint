import AppKit

/// 文字標註的 inline 編輯器（單行 v1）。唯一的子 view 特例：
/// 疊在 SelectionView 上、commit 才把內容變成正式 Annotation。
/// Esc（cancelOperation）與 Enter（insertNewline）都＝完成編輯。
final class InlineTextView: NSTextView {
    var onCommit: (() -> Void)?
    /// Enter 是否＝完成編輯。單行文字＝true（Enter 收尾）；callout 多行＝false（Enter 換行，Esc/點外面收尾）。
    var commitsOnNewline = true

    /// make() 收到的文字框原點（渲染語意＝文字框左下，與 AnnotationRenderer/Annotation.Shape.text
    /// 的 origin 同一個座標）。commit 時直接讀這個值，不從 frame 反推——frame 已因基線對齊公式
    /// 偏移，反推容易出錯（驗收回饋 Fix 1）。
    private(set) var textOrigin: CGPoint = .zero

    override func cancelOperation(_ sender: Any?) { onCommit?() }
    override func insertNewline(_ sender: Any?) {
        if commitsOnNewline { onCommit?() } else { super.insertNewline(sender) }
    }

    /// 建立設定好樣式的編輯器。origin＝文字框左下（view 座標，渲染語意）。
    ///
    /// 基線對齊公式（驗收回饋 Fix 1）：AnnotationRenderer.drawLine 把文字畫在
    /// 「基線 = origin.y + descent」（descent 用 CTLineGetTypographicBounds 的正值）。
    /// NSTextView 內部是 flipped 座標，第一行基線落在其 frame 頂下方約
    /// NSFont.ascender 處（textContainerInset=0、lineFragmentPadding=0 時，用
    /// layoutManager.location(forGlyphAt:) 實測驗證：14–60pt 字級誤差都 <0.5pt，
    /// 遠小於修正前的 8.8pt 垂直偏移，可接受）。
    /// 換算：frame 是本 view（y-up）座標，frame.maxY＝frame 的頂。
    /// 要 frame.maxY - ascent == origin.y + descent，即
    /// frame.origin.y = origin.y + (ascent + descent) - height。
    static func make(origin: CGPoint, fontSize: CGFloat, color: NSColor,
                     initialString: String) -> InlineTextView {
        let height = ceil(fontSize * 1.5)
        let font = NSFont.systemFont(ofSize: fontSize)
        let ascent = font.ascender
        let descent = abs(font.descender)
        let frameOriginY = origin.y + (ascent + descent) - height
        let editor = InlineTextView(frame: CGRect(x: origin.x, y: frameOriginY,
                                                  width: 240, height: height))
        editor.textOrigin = origin
        editor.string = initialString
        editor.font = font
        editor.textColor = color
        editor.backgroundColor = NSColor(white: 0.1, alpha: 0.75)
        editor.insertionPointColor = .white
        editor.isRichText = false
        editor.allowsUndo = true
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        return editor
    }

    /// 多行自動換行編輯器（callout 內嵌文字用）。frame＝文字可用矩形（view 座標）；
    /// 文字在框寬內自動換行、由上而下排（對齊 renderer 的 CTFramesetter 頂端排版）。
    /// Enter＝換行（不收尾）；Esc／點框外／切工具才收尾。
    static func makeWrapped(rect: CGRect, fontSize: CGFloat, color: NSColor,
                            initialString: String) -> InlineTextView {
        let editor = InlineTextView(frame: rect)
        editor.textOrigin = rect.origin
        editor.commitsOnNewline = false
        editor.string = initialString
        editor.font = NSFont.systemFont(ofSize: fontSize)
        editor.textColor = color
        editor.backgroundColor = NSColor(white: 0.1, alpha: 0.6)
        editor.insertionPointColor = .white
        editor.isRichText = false
        editor.allowsUndo = true
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        // 固定寬、依框寬換行；高度不隨內容拉伸（超出就在框內捲動）。
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.size = CGSize(width: rect.width, height: rect.height)
        return editor
    }
}
