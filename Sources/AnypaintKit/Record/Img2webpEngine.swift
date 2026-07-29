import Foundation

/// 外部 img2webp 引擎（WebP 匯出，設計文件 §1.7b）。與 `GifskiEngine` 同模式（固定路徑偵測＋
/// 子程序呼叫），但**沒有回退**：ImageIO 在這台機器上探測不到 webp 輸出型別
/// （`CGImageDestinationCopyTypeIdentifiers()` 不含 webp，實測見 task-8b 報告）——沒有內建
/// WebP 編碼器可退，找不到 img2webp 時「存 WebP」鈕直接不出現（見 `RecordPreviewWindow`），
/// 不是灰鈕也不是錯誤訊息。
///
/// 另立一個檔案（而非塞進 `GifskiEngine.swift` 擴充）：兩個引擎的偵測路徑／子程序邊界完全
/// 獨立，且 `GifskiEngine` 已經是「一個引擎一個型別」的既有慣例，跟著同一個模式走，不要把
/// 兩種外部工具的偵測常數混進同一個型別裡。
public enum Img2webpEngine {
    /// 偵測順序即優先序：homebrew（Apple Silicon 預設前綴）優先於 /usr/local（Intel 預設前綴）。
    /// 同 `GifskiEngine.candidatePaths` 的道理——homebrew 的 `webp` 套件把 img2webp 裝在這兩個
    /// 前綴之一。
    public static let candidatePaths = ["/opt/homebrew/bin/img2webp", "/usr/local/bin/img2webp"]

    /// 純邏輯部分：注入 `isExecutable` 好測（selftest 用 stub，不碰真實檔案系統）。
    public static func detect(isExecutable: (String) -> Bool) -> String? {
        candidatePaths.first(where: isExecutable)
    }

    /// 便利版：實機呼叫走真正的檔案系統檢查。
    public static func detect() -> String? {
        detect(isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// 引數組裝純函式：`-loop 0 -d <ms> frame1 frame2 … -o output`。
    ///
    /// **`-d` 語法**（`img2webp -h`，本機未裝 img2webp，語法照 libwebp 官方文件寫入，
    /// 標記未實測——見任務報告的待驗清單）：`-d` 是「per-frame」選項，套用到它之後所有列出的
    /// frame，直到下一個 `-d` 出現為止（不是每格都要重複），例如
    /// `img2webp -loop 0 -d 100 in0.png -d 200 in1.png -o out.webp`。因此本專案固定 fps
    /// 抽格（等長 delay）時只需要在最前面放一個 `-d`；這裡的實作更通用一點：把「連續相同
    /// delay」摺疊成單一 `-d`，只有 delay 真的改變時才插入新的 `-d`——等長情境（唯一會發生的
    /// 情境，抽格 grid 固定 fps）自動退化成單一全域 `-d`，非等長情境（目前呼叫端不會傳，但
    /// 函式本身不假設）也正確。
    ///
    /// `-loop 0` 固定放最前面（file-level 選項，官方文件說明只在指令最前面生效一次）；
    /// `-o output` 放最後（img2webp 範例慣例把輸出檔放在所有 frame 之後）。
    ///
    /// `delaysMs`／`frames` 長度不一致時以較短者為準（防禦性；呼叫端——`GifExporter`——保證
    /// 兩者等長，每格一個 delay）。
    public static func arguments(delaysMs: [Int], frames: [String], output: String) -> [String] {
        var args = ["-loop", "0"]
        var lastDelay: Int?
        for (delay, frame) in zip(delaysMs, frames) {
            if delay != lastDelay {
                args += ["-d", "\(delay)"]
                lastDelay = delay
            }
            args.append(frame)
        }
        args += ["-o", output]
        return args
    }

    public enum RunError: Error {
        case spawnFailed(Error)
        case exitCode(Int32)
        case outputMissing
    }

    /// 執行子程序、同步等待結束、檢查 exit code 與輸出檔存在（兩者皆須成立才算成功）。
    /// 輸出路徑從 `arguments` 的 `-o` 後一個元素取得，同 `GifskiEngine.run` 的做法——不必
    /// 另外多傳一份 output 參數，`-o` 在陣列中的位置與 gifski 不同（這裡在最後）不影響
    /// `firstIndex(of:)` 查找。
    public static func run(img2webpPath: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: img2webpPath)
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
