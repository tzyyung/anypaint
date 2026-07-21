import AppKit

/// 文字標註的 inline 編輯器（單行 v1）。唯一的子 view 特例：
/// 疊在 SelectionView 上、commit 才把內容變成正式 Annotation。
/// Esc（cancelOperation）與 Enter（insertNewline）都＝完成編輯。
final class InlineTextView: NSTextView {
    var onCommit: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onCommit?() }
    override func insertNewline(_ sender: Any?) { onCommit?() }

    /// 建立設定好樣式的編輯器。origin＝文字框左下（view 座標）。
    static func make(origin: CGPoint, fontSize: CGFloat, color: NSColor,
                     initialString: String) -> InlineTextView {
        let height = ceil(fontSize * 1.5)
        let editor = InlineTextView(frame: CGRect(x: origin.x, y: origin.y,
                                                  width: 240, height: height))
        editor.string = initialString
        editor.font = .systemFont(ofSize: fontSize)
        editor.textColor = color
        editor.backgroundColor = NSColor(white: 0.1, alpha: 0.75)
        editor.insertionPointColor = .white
        editor.isRichText = false
        editor.allowsUndo = true
        editor.textContainerInset = .zero
        return editor
    }
}
