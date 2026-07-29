import Foundation

/// 外部 gifski 引擎（高品質 GIF，設計文件 §1.7）。固定路徑偵測＋子程序呼叫，任何失敗一律讓
/// 呼叫端（`GifExporter`）回退內建 CGImageDestination 編碼路徑——不 shell `which`：launchd
/// 環境下 PATH 不可靠（CLAUDE.md 全域規則「不要憑印象寫 OS API」，動手前已查）。
public enum GifskiEngine {
    /// 偵測順序即優先序：homebrew（Apple Silicon 預設前綴）優先於 /usr/local（Intel 預設前綴）。
    public static let candidatePaths = ["/opt/homebrew/bin/gifski", "/usr/local/bin/gifski"]

    /// 純邏輯部分：注入 `isExecutable` 好測（selftest 用 stub，不碰真實檔案系統）。
    public static func detect(isExecutable: (String) -> Bool) -> String? {
        candidatePaths.first(where: isExecutable)
    }

    /// 便利版：實機呼叫走真正的檔案系統檢查。
    public static func detect() -> String? {
        detect(isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// 引數組裝純函式：`--fps N --quality Q --width W -o output frame1 frame2 …`——frames 逐一
    /// 列舉（不靠 shell glob，`Process` 不經 shell），順序即輸出順序，呼叫端須確保檔名已排序
    /// （`GifExporter` 用零填充檔名 `frame-0001.png…` 保證）。
    ///
    /// `--width` **必傳**（實測發現，非憑印象）：`gifski -h` 記載「By default anims are limited
    /// to about 800x600」——實機驗證過，1200×900 的來源 PNG 在不傳 `--width` 時被悄悄縮成
    /// 600×450；顯式傳來源寬度（與內建路徑輸出的 1x 點尺寸一致）後原尺寸不變（傳小於預設上限的
    /// 寬度一樣原樣輸出，非強制拉伸）。不傳會讓超過門檻的擷取畫面產出比內建編碼器更小的 GIF，
    /// 這是靜默的畫質倒退，不是「gifski 品質比較好」的可接受代價。
    public static func arguments(fps: Int, quality: Int, width: Int, output: String, frames: [String]) -> [String] {
        ["--fps", "\(fps)", "--quality", "\(quality)", "--width", "\(width)", "-o", output] + frames
    }

    public enum RunError: Error {
        case spawnFailed(Error)
        case exitCode(Int32)
        case outputMissing
    }

    /// 執行子程序、同步等待結束、檢查 exit code 與輸出檔存在（兩者皆須成立才算成功）。
    /// 輸出路徑從 `arguments` 的 `-o` 後一個元素取得——`arguments(...)` 保證這個形狀，不必
    /// 另外多傳一份 output 參數。
    public static func run(gifskiPath: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gifskiPath)
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            throw RunError.spawnFailed(error)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RunError.exitCode(process.terminationStatus)
        }
        guard let outputIndex = arguments.firstIndex(of: "-o"), outputIndex + 1 < arguments.count,
              FileManager.default.fileExists(atPath: arguments[outputIndex + 1]) else {
            throw RunError.outputMissing
        }
    }
}
