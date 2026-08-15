import AppKit
import ApplicationServices
import KeyboardShortcuts

/// 全域快鍵攔截模式。`off`＝純 Carbon（零權限,現行預設）;`session`/`hid`＝加 CGEventTap 搶在
/// 前景 app 之前攔鍵（需輔助使用權限,見設計文件 `2026-08-15-hotkey-eventtap-design.md`）。
public enum HotkeyInterceptMode: String {
    case off, session, hid
}

/// 全域快鍵的單一協調層（facade）：同時管 Carbon 路徑（KeyboardShortcuts）與 CGEventTap 路徑,
/// 並維護框選/錄影期的互斥暫停集。**取代所有直接呼叫 `KeyboardShortcuts.disable/enable`**——那些散落
/// 在 6 處的呼叫改走這裡,否則 tap 接管 Carbon 後,子集 enable 會讓 Carbon 與 tap 對同一顆鍵雙觸發。
///
/// 退回原則：模式非 off 但**權限沒給或 tap 建立失敗 → 自動退回 Carbon**,絕不比現況差。
@MainActor
public enum Hotkeys {
    private static var tap: HotkeyEventTap?
    private static var names: [KeyboardShortcuts.Name] = []
    private static var actions: [String: () -> Void] = [:]     // rawValue → 動作（Carbon/tap 共用）
    private static var suspended: Set<String> = []             // 目前互斥暫停的 rawValue
    private static var tapActive = false                       // tap 真的在跑（權限給了＋建成功）
    private static var wakeObserverInstalled = false

    /// 目前是否走 tap 路徑（供設定頁/自檢顯示實際生效狀態,與「設定值」區分）。
    public static var isTapActive: Bool { tapActive }

    /// 啟動時註冊 5 顆快鍵的動作（tap 命中與 Carbon `onKeyDown` 共用同一動作）。呼叫端仍各自
    /// `KeyboardShortcuts.onKeyDown(for:)` 接 Carbon 路徑;這裡的 actions 供 tap 命中時派發。
    public static func register(_ pairs: [(KeyboardShortcuts.Name, () -> Void)]) {
        names = pairs.map(\.0)
        actions = Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.rawValue, $0.1) })
        installWakeObserverIfNeeded()
    }

    /// 套用模式（啟動時讀設定、或設定頁切換時呼叫）。回傳**是否真的以 tap 生效**（false＝退回 Carbon,
    /// 含 off、權限沒給、建 tap 失敗三種）。
    @discardableResult
    public static func applyMode(_ mode: HotkeyInterceptMode) -> Bool {
        tap?.stop(); tap = nil; tapActive = false
        guard mode != .off else { reconcileCarbon(); return false }
        guard AXIsProcessTrusted() else { reconcileCarbon(); return false }   // 沒權限→退回 Carbon
        let t = HotkeyEventTap(bindingsProvider: { Hotkeys.activeBindings() },
                               onMatch: { name in Hotkeys.actions[name]?() })
        guard t.start(level: mode == .hid ? .hid : .session) else { reconcileCarbon(); return false }
        tap = t
        tapActive = true
        KeyboardShortcuts.disable(names)   // tap 接管→全面停用 Carbon,避免雙觸發
        return true
    }

    /// 互斥暫停（取代 `KeyboardShortcuts.disable`）：tap 模式只更新暫停集（tap 讀 activeBindings 即時反映）;
    /// Carbon 模式轉呼 `disable`。**nonisolated shim**：呼叫端多為非 @MainActor 的 UI 類別
    /// （SelectionOverlayController／MenuBarController,但都在主緒跑,同原 `KeyboardShortcuts.disable`）
    /// →用 `assumeIsolated` 橋接,不逼呼叫端到處包。非主緒呼叫會 crash（本就是主緒 API 的前提）。
    public nonisolated static func suspend(_ ns: [KeyboardShortcuts.Name]) {
        MainActor.assumeIsolated {
            ns.forEach { suspended.insert($0.rawValue) }
            if !tapActive { KeyboardShortcuts.disable(ns) }
        }
    }
    public nonisolated static func suspend(_ ns: KeyboardShortcuts.Name...) { suspend(ns) }

    /// 互斥恢復（取代 `KeyboardShortcuts.enable`）。nonisolated shim,同 `suspend`。
    public nonisolated static func resume(_ ns: [KeyboardShortcuts.Name]) {
        MainActor.assumeIsolated {
            ns.forEach { suspended.remove($0.rawValue) }
            if !tapActive { KeyboardShortcuts.enable(ns) }
        }
    }
    public nonisolated static func resume(_ ns: KeyboardShortcuts.Name...) { resume(ns) }

    /// 引導輔助使用授權（設定頁開啟 tap 時呼叫）：未授權時彈系統對話框並開啟隱私權面板。
    /// 回傳當下是否已授權。
    @discardableResult
    public static func requestAccessibilityIfNeeded() -> Bool {
        if AXIsProcessTrusted() { return true }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - 內部

    /// 目前有效綁定：非暫停且真的有設快鍵的名稱 → Binding（keyCode＋遮成四鍵的修飾鍵）。
    private static func activeBindings() -> [HotkeyMatch.Binding] {
        names.compactMap { name in
            guard !suspended.contains(name.rawValue),
                  let s = KeyboardShortcuts.getShortcut(for: name) else { return nil }
            return HotkeyMatch.Binding(name: name.rawValue, keyCode: s.carbonKeyCode,
                                       modifiers: s.modifiers.rawValue & HotkeyMatch.modifierMask)
        }
    }

    /// Carbon 路徑對帳（tap 未生效時）：暫停集內的停用、其餘啟用。
    private static func reconcileCarbon() {
        let sus = names.filter { suspended.contains($0.rawValue) }
        let act = names.filter { !suspended.contains($0.rawValue) }
        KeyboardShortcuts.disable(sus)
        KeyboardShortcuts.enable(act)
    }

    /// 睡醒後系統會停用 tap（最著名的坑）——重掛 `didWakeNotification` 重新啟用（callback 也會在收到
    /// disabled 事件時自救,這裡是雙保險,涵蓋「睡醒後一直沒有按鍵事件來觸發 callback」的情況）。
    private static func installWakeObserverIfNeeded() {
        guard !wakeObserverInstalled else { return }
        wakeObserverInstalled = true
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Hotkeys.tap?.reEnable() }
        }
    }
}
