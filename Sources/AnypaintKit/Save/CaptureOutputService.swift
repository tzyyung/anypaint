import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 截圖存檔的完整鏈：樣板展開 → 寫檔 → 通知；NSImage 與 CGImage（長圖直寫）共用同一套路徑邏輯。
/// 從 AppDelegate 抽出（滾動截圖需要 CGImage 直寫路徑，避免 NSImage→TIFF 三份拷貝峰值記憶體）。
public final class CaptureOutputService {
    public init() {}

    // MARK: - 共用：樣板展開 → 補副檔名 → fallback → ~ 展開 → 相對路徑補家目錄 → 碰撞遞增

    private func resolveURL(template: String, vars: [String: String]) -> URL {
        let now = Date()
        var expanded = FilenameTemplate.ensuringPNGExtension(
            FilenameTemplate.expand(template, date: now, vars: vars))
        let fallback = FilenameTemplate.expand(FilenameTemplate.defaultName, date: now, vars: vars)
        expanded = FilenameTemplate.ensuringMeaningfulFilename(expanded, fallbackName: fallback)
        var path = (expanded as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = NSHomeDirectory() + "/" + path }   // cwd 不可靠（launchd 啟動＝/）
        let target = URL(fileURLWithPath: path)
        return CaptureSaver.uniquedURL(
            directory: target.deletingLastPathComponent(),
            filename: target.lastPathComponent,
            exists: { FileManager.default.fileExists(atPath: $0.path) })
    }

    // MARK: - NSImage

    /// 展開路徑樣板 → 補 .png → 檔名 fallback → 相對路徑補家目錄 → 碰撞遞增 → 寫檔 → 通知。
    /// quiet：自動儲存失敗不 beep（背景行為不打擾，spec）。
    ///
    /// - Returns: **實際寫成功**的檔案 URL；寫檔失敗回 nil。「存檔並開啟」靠這個回傳值決定
    ///   要不要交給外部 app——不可改用 `resolveURL` 的結果，那只是預定路徑，寫失敗時去開
    ///   一個不存在的檔會得到系統的錯誤對話框（而不是這裡已經發過的 beep）。
    @discardableResult
    public func saveExpanding(template: String, image: NSImage,
                               vars: [String: String], quiet: Bool) -> URL? {
        let url = resolveURL(template: template, vars: vars)
        do {
            try CaptureSaver.writePNG(image: image, to: url)
            if AppSettings.saveNotificationEnabled {
                SaveNotifier.shared.notifySaved(filename: url.lastPathComponent, fileURL: url)
            }
            return url
        } catch {
            NSLog("anypaint: 存檔失敗 \(error)")
            if !quiet { NSSound.beep() }
            return nil
        }
    }

    /// 自動儲存（spec：預設關；掛全部四條完成鏈）。
    public func autoSaveIfEnabled(image: NSImage, vars: [String: String]) {
        guard AppSettings.autoSaveEnabled else { return }
        saveExpanding(template: AppSettings.autoSavePathTemplate,
                      image: image, vars: vars, quiet: true)
    }

    /// 另存為：彈 NSSavePanel 自選位置與檔名（覆寫確認交給面板，不套 uniquedURL）。
    /// 預設檔名＝manualNameTemplate 展開；起始目錄＝快速儲存路徑樣板的目錄段。
    /// 另存為不發通知——使用者親自選了位置，看得到結果（spec 只涵蓋快速/自動）。
    public func saveWithPanel(image: NSImage, vars: [String: String]) {
        let now = Date()
        var name = FilenameTemplate.ensuringPNGExtension(
            FilenameTemplate.expand(AppSettings.manualNameTemplate, date: now, vars: vars))
        name = name.replacingOccurrences(of: "/", with: "-")   // 檔名欄不接受目錄
        name = FilenameTemplate.ensuringMeaningfulFilename(
            name,
            fallbackName: FilenameTemplate.expand(FilenameTemplate.defaultName,
                                                  date: now, vars: vars))
        let quickExpanded = FilenameTemplate.expand(AppSettings.quickSavePathTemplate,
                                                    date: now, vars: vars)
        let startDir = URL(fileURLWithPath: (quickExpanded as NSString).expandingTildeInPath)
            .deletingLastPathComponent()

        let panel = NSSavePanel()
        panel.title = "圖像另存為"
        panel.nameFieldStringValue = name
        panel.directoryURL = startDir
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)   // agent app：不 activate 面板不會成 key
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CaptureSaver.writePNG(image: image, to: url)
        } catch {
            NSLog("anypaint: 另存失敗 \(error)")
            NSSound.beep()
        }
    }

    // MARK: - CGImage（長圖直寫，不經 NSImage→TIFF 三份拷貝——spec §8）

    /// 展開路徑樣板 → 補 .png → 檔名 fallback → 相對路徑補家目錄 → 碰撞遞增 → 寫檔 → 通知。
    /// quiet：自動儲存失敗不 beep（背景行為不打擾，spec）。
    ///
    /// - Returns: **實際寫成功**的檔案 URL；寫檔失敗回 nil（理由同 NSImage 版）。
    @discardableResult
    public func saveExpanding(template: String, cgImage: CGImage,
                               vars: [String: String], quiet: Bool) -> URL? {
        let url = resolveURL(template: template, vars: vars)
        do {
            try CaptureSaver.writePNG(cgImage: cgImage, to: url)
            if AppSettings.saveNotificationEnabled {
                SaveNotifier.shared.notifySaved(filename: url.lastPathComponent, fileURL: url)
            }
            return url
        } catch {
            NSLog("anypaint: 存檔失敗 \(error)")
            if !quiet { NSSound.beep() }
            return nil
        }
    }

    /// 自動儲存（spec：預設關；掛全部四條完成鏈）。
    public func autoSaveIfEnabled(cgImage: CGImage, vars: [String: String]) {
        guard AppSettings.autoSaveEnabled else { return }
        saveExpanding(template: AppSettings.autoSavePathTemplate,
                      cgImage: cgImage, vars: vars, quiet: true)
    }

    /// 另存為：彈 NSSavePanel 自選位置與檔名（覆寫確認交給面板，不套 uniquedURL）。
    /// 預設檔名＝manualNameTemplate 展開；起始目錄＝快速儲存路徑樣板的目錄段。
    /// 另存為不發通知——使用者親自選了位置，看得到結果（spec 只涵蓋快速/自動）。
    public func saveWithPanel(cgImage: CGImage, vars: [String: String]) {
        let now = Date()
        var name = FilenameTemplate.ensuringPNGExtension(
            FilenameTemplate.expand(AppSettings.manualNameTemplate, date: now, vars: vars))
        name = name.replacingOccurrences(of: "/", with: "-")   // 檔名欄不接受目錄
        name = FilenameTemplate.ensuringMeaningfulFilename(
            name,
            fallbackName: FilenameTemplate.expand(FilenameTemplate.defaultName,
                                                  date: now, vars: vars))
        let quickExpanded = FilenameTemplate.expand(AppSettings.quickSavePathTemplate,
                                                    date: now, vars: vars)
        let startDir = URL(fileURLWithPath: (quickExpanded as NSString).expandingTildeInPath)
            .deletingLastPathComponent()

        let panel = NSSavePanel()
        panel.title = "圖像另存為"
        panel.nameFieldStringValue = name
        panel.directoryURL = startDir
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)   // agent app：不 activate 面板不會成 key
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CaptureSaver.writePNG(cgImage: cgImage, to: url)
        } catch {
            NSLog("anypaint: 另存失敗 \(error)")
            NSSound.beep()
        }
    }

    // MARK: - 存檔並開啟（交給外部 App 繼續編輯）

    /// 存到快速儲存路徑，再把檔案交給外部程式：設定頁指定的 App，未指定就用系統預設的
    /// PNG 程式（多數機器＝預覽程式）。
    ///
    /// 刻意**不寫暫存檔**：使用者在外部程式標註完按 ⌘S 會存回這個檔，放系統暫存目錄的話
    /// 之後會被清掉——他以為存好了、檔案卻消失。存成正式檔則檔名樣板、碰撞遞增、儲存通知
    /// 全部沿用既有鏈路，外部程式的儲存也自然落在他自己的資料夾。
    ///
    /// 無回傳值：指定 App 的開啟 API 是**非同步**的（completionHandler），同步 Bool 表達
    /// 不了結果；失敗一律在下面統一 beep + log。
    public func saveAndOpen(image: NSImage, vars: [String: String]) {
        guard let url = saveExpanding(template: AppSettings.quickSavePathTemplate,
                                      image: image, vars: vars, quiet: false) else {
            return   // 寫檔失敗：saveExpanding 已 beep 過，不再重複
        }
        openInExternalApp(url)
    }

    /// CGImage 版（長圖直寫路徑）；語意與 NSImage 版相同。
    public func saveAndOpen(cgImage: CGImage, vars: [String: String]) {
        guard let url = saveExpanding(template: AppSettings.quickSavePathTemplate,
                                      cgImage: cgImage, vars: vars, quiet: false) else {
            return
        }
        openInExternalApp(url)
    }

    /// 兩條路（都已查 SDK header，皆非 deprecated）：
    /// - 未指定 App → `open(_:)`，走使用者的預設 PNG 程式。它回 Bool 而不拋錯，
    ///   不處理的話「按了沒反應」完全無從查起。
    /// - 指定了 App → `open(_:withApplicationAt:configuration:completionHandler:)`（10.15+），
    ///   **非同步**。completionHandler 不保證在主執行緒，beep 要切回主執行緒。
    ///
    /// 指定的 App 解析不到（被刪／改了 bundle ID）時 `resolveOpenWithApp` 回 nil，
    /// 這裡自然落到系統預設那條——檔案照樣開得起來，設定頁會顯示「找不到」讓使用者去修。
    private func openInExternalApp(_ url: URL) {
        let appURL = AppSettings.resolveOpenWithApp(
            stored: AppSettings.openWithBundleIdentifier,
            resolve: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })

        guard let appURL else {
            if !NSWorkspace.shared.open(url) {
                NSLog("anypaint: 無法開啟 \(url.path)")
                NSSound.beep()
            }
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true   // agent app：不 activate 的話外部程式在背景開起來、使用者看不到
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { _, error in
            guard let error else { return }
            NSLog("anypaint: 無法用 \(appURL.lastPathComponent) 開啟 \(url.path)：\(error)")
            DispatchQueue.main.async { NSSound.beep() }
        }
    }
}
