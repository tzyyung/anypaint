import CoreGraphics
import Foundation

/// 斷言工具。selftest 無 XCTest（純 CLT 環境無執行器），以可執行檔跑斷言。
/// 封裝進型別而非 top-level var：Swift 6 模式下 top-level 變數隱式 @MainActor，
/// 跨檔存取會編譯失敗（SE-0343）；現在就封裝，升版不炸。
///
/// 型別短名警告：`T` 刻意取短名以降低呼叫點雜訊，但會遮蔽泛型參數常見慣例的 `T`
/// （checkEq 的泛型參數因此改名為 `V`，見下）。新增使用 `T` 當泛型參數名的程式碼前，
/// 先確認是否與此型別衝突。
enum T {
    // .v6（SE-0412）下 static var 屬於 global mutable state，會報
    // "static property 'failures' is not concurrency-safe"。
    // selftest 是同步單執行緒 CLI（無執行緒、無 Task、無 actor 跨界），不存在資料競爭，
    // nonisolated(unsafe) 是對 SE-0412 併發安全檢查的明示豁免，非隨意繞過。
    nonisolated(unsafe) static var failures = 0

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
