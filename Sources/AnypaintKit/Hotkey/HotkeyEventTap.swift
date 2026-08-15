import AppKit
import CoreGraphics

/// CGEventTap 封裝：在**前景 app 之前**攔 keyDown,命中設定快鍵就觸發動作並**吞掉**事件
/// （active 模式）。用來對抗 TeamViewer 這類 event-tap 工具搶走 Carbon 全域快鍵（見設計文件
/// `2026-08-15-hotkey-eventtap-design.md`）。**需輔助使用（Accessibility）權限**——呼叫端須先確認
/// `AXIsProcessTrusted()`,這裡不自己要權限。
///
/// 執行緒：tap 的 run-loop source 掛在**主 run loop**,callback 因此在主緒跑,動作派發直接安全;
/// callback 內只做輕量比對＋`async` 派動作,快速回傳事件決定,不阻塞事件遞送。
@MainActor
public final class HotkeyEventTap {
    public enum Level {
        case session, hid
        var tapLocation: CGEventTapLocation { self == .hid ? .cghidEventTap : .cgSessionEventTap }
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// 每個事件重讀一次目前有效綁定（快鍵改鍵、框選/錄影期的暫停都即時反映）。
    private let bindingsProvider: () -> [HotkeyMatch.Binding]
    /// 命中時在主緒呼叫（帶命中的 KeyboardShortcuts.Name.rawValue）。回傳後 tap 一律吞掉該事件。
    private let onMatch: (String) -> Void

    public init(bindingsProvider: @escaping () -> [HotkeyMatch.Binding],
                onMatch: @escaping (String) -> Void) {
        self.bindingsProvider = bindingsProvider
        self.onMatch = onMatch
    }

    /// 建 tap＋掛主 run loop＋啟用。回 false＝建立失敗（權限未授、或系統拒絕）——呼叫端據此退回 Carbon。
    /// 重複呼叫先 `stop()`（不疊兩個 tap）。
    @discardableResult
    public func start(level: Level) -> Bool {
        stop()
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: level.tapLocation,
            place: .headInsertEventTap,          // 排同層最前面,先於後掛的 tap 收到
            options: .defaultTap,                // active：可吞事件（listen-only 吞不掉,無用）
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: selfPtr) else { return false }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        runLoopSource = nil
    }

    /// 系統會在逾時/睡醒把 tap 停用（`kCGEventTapDisabledByTimeout`/`ByUserInput`）——最著名的坑
    /// （睡醒後全域鍵失效）。callback 收到 disabled 事件時呼這個重新啟用。
    func reEnable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// callback 主體（在主緒）：回傳 true＝已命中並吞掉,false＝放行。
    fileprivate func handle(_ event: CGEvent) -> Bool {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let mods = HotkeyMatch.normalizedModifiers(fromRawFlags: event.flags.rawValue)
        guard let name = HotkeyMatch.matchName(keyCode: keyCode, modifiers: mods,
                                               among: bindingsProvider()) else { return false }
        let cb = onMatch
        DispatchQueue.main.async { cb(name) }   // 動作 async 派,callback 快速回傳吞掉決定,不重入
        return true
    }
}

/// CGEventTapCallBack（`@convention(c)`,不能捕獲 context）——self 由 `userInfo` refcon 帶回。
private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                              event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    // 系統停用（逾時/睡醒）→ 重新啟用後放行。這兩種 type 不是真的按鍵事件。
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo {
            let tap = Unmanaged<HotkeyEventTap>.fromOpaque(userInfo).takeUnretainedValue()
            MainActor.assumeIsolated { tap.reEnable() }
        }
        return Unmanaged.passUnretained(event)
    }
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<HotkeyEventTap>.fromOpaque(userInfo).takeUnretainedValue()
    // callback 掛在主 run loop → 已在主緒,可直接碰 @MainActor。
    let consumed = MainActor.assumeIsolated { tap.handle(event) }
    return consumed ? nil : Unmanaged.passUnretained(event)   // nil＝吞掉,不往下傳
}
