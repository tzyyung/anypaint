import CoreGraphics
import Foundation

/// 斷言工具。selftest 無 XCTest（純 CLT 環境無執行器），以可執行檔跑斷言。
/// 封裝進型別而非 top-level var：Swift 6 模式下 top-level 變數隱式 @MainActor，
/// 跨檔存取會編譯失敗（SE-0343）；現在就封裝，升版不炸。
enum T {
    static var failures = 0

    static func check(_ name: String, _ got: CGRect, _ want: CGRect) {
        if got == want { print("✅ \(name)") }
        else { failures += 1; print("❌ \(name)\n   got : \(got)\n   want: \(want)") }
    }

    static func checkEq<V: Equatable>(_ name: String, _ got: V, _ want: V) {
        if got == want { print("✅ \(name)") }
        else { failures += 1; print("❌ \(name)\n   got : \(got)\n   want: \(want)") }
    }

    static func checkTrue(_ name: String, _ cond: Bool) {
        if cond { print("✅ \(name)") }
        else { failures += 1; print("❌ \(name)") }
    }

    /// main.swift 最尾端呼叫：印總結、非零退出碼供 CI 用。
    static func finish() -> Never {
        if failures == 0 { print("\n全部通過"); exit(0) }
        print("\n共 \(failures) 項失敗"); exit(1)
    }
}
