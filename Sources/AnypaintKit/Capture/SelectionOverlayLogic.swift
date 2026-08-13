/// SelectionOverlayController 的**純決策**（無 AppKit、無 view 狀態,selftest 可測）。
public enum SelectionOverlayLogic {

    /// Shift 上升緣切換 RGB/HEX：Shift 剛按下（`!shiftWasDown`）、且沒有同時按其他修飾鍵。
    /// 避免 ⌘⇧/⌃⇧ 這類組合誤觸切換。
    public static func shouldToggleColorFormat(shiftDown: Bool, shiftWasDown: Bool, othersDown: Bool) -> Bool {
        shiftDown && !shiftWasDown && !othersDown
    }

    /// 能否把選取權獨佔給某個視窗：其他視窗只要有任一個已鎖框（frameLocked）就不准搶（回 false→beep）；
    /// 都沒鎖（含「沒有其他視窗」）＝准（其他的選區會被 relinquish）。
    public static func shouldGrant(otherFrameLockedFlags: [Bool]) -> Bool {
        !otherFrameLockedFlags.contains(true)
    }

    /// Esc 分層動作（純：只看跨視窗的三個聚合旗標）。層序：組字中讓 IME → 編輯中先完成編輯 →
    /// 有選取先解除選取 → 否則取消整個 overlay。
    public enum EscAction: Equatable { case letIME, commitEditing, deselect, cancel }
    public static func escAction(anyComposing: Bool, anyEditing: Bool, anySelection: Bool) -> EscAction {
        if anyComposing { return .letIME }
        if anyEditing { return .commitEditing }
        if anySelection { return .deselect }
        return .cancel
    }

    /// 把符合條件的元素移到最前（看門狗搶救取像順序：最後互動的視窗優先）；
    /// 找不到符合者＝原順序不變。純陣列運算,泛型可測。
    public static func movedToFront<T>(_ items: [T], matching: (T) -> Bool) -> [T] {
        guard let idx = items.firstIndex(where: matching) else { return items }
        var out = items
        let e = out.remove(at: idx)
        out.insert(e, at: 0)
        return out
    }
}
