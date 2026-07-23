import AppKit

/// 設定分頁共用容器：stack 四邊 pin（邊距 20）＋固定寬 480。
/// bottom 有 pin ⇒ 容器高度由內容決定——NSTabViewController(.toolbar) 切頁時
/// 視窗高度隨頁自動調整（依賴 autolayout 完整，已查證 pattern）。
/// stack 的方向/對齊/間距由各頁自設（控制頁需要 centerX，其他頁 leading）。
func settingsPageView(wrapping stack: NSStackView) -> NSView {
    let container = NSView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
        stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
        stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),   // 撐滿，欄位寬度與舊版一致
        stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
        container.widthAnchor.constraint(equalToConstant: 480),
    ])
    return container
}
