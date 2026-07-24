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
    public func saveExpanding(template: String, image: NSImage,
                               vars: [String: String], quiet: Bool) {
        let url = resolveURL(template: template, vars: vars)
        do {
            try CaptureSaver.writePNG(image: image, to: url)
            if AppSettings.saveNotificationEnabled {
                SaveNotifier.shared.notifySaved(filename: url.lastPathComponent)
            }
        } catch {
            NSLog("anypaint: 存檔失敗 \(error)")
            if !quiet { NSSound.beep() }
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
    public func saveExpanding(template: String, cgImage: CGImage,
                               vars: [String: String], quiet: Bool) {
        let url = resolveURL(template: template, vars: vars)
        do {
            try CaptureSaver.writePNG(cgImage: cgImage, to: url)
            if AppSettings.saveNotificationEnabled {
                SaveNotifier.shared.notifySaved(filename: url.lastPathComponent)
            }
        } catch {
            NSLog("anypaint: 存檔失敗 \(error)")
            if !quiet { NSSound.beep() }
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
}
