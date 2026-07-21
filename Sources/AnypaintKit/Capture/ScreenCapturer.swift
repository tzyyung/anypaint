import ScreenCaptureKit
import AppKit

/// 一個 display 的凍結快照：像素影像 + 對應的 AppKit 螢幕資訊。
struct DisplaySnapshot {
    let displayID: CGDirectDisplayID
    let cgImage: CGImage        // 凍結的像素影像（左上原點）
    let screen: NSScreen        // 對應的 NSScreen（用來定位 overlay 視窗）
    let frameGlobal: CGRect     // 該螢幕在 AppKit 全域座標的 frame（點、左下原點）
    let scale: CGFloat          // pixel scale（Retina 通常為 2）

    /// 邏輯尺寸（點）。
    var pointSize: CGSize { frameGlobal.size }
}

enum CaptureError: Error {
    case noPermission
    case noDisplays
    case captureFailed
}

/// 用 ScreenCaptureKit 擷取整個桌面（每個實體螢幕一張）。單一職責：只負責「抓像素」。
final class ScreenCapturer {

    /// 凍結所有螢幕，各回一張快照。若無螢幕錄製權限會丟 `.noPermission`。
    func captureAllDisplays() async throws -> [DisplaySnapshot] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            // 權限未授予時，SCShareableContent 會丟錯。
            throw CaptureError.noPermission
        }

        guard !content.displays.isEmpty else { throw CaptureError.noDisplays }

        var snapshots: [DisplaySnapshot] = []
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)

            let config = SCStreamConfiguration()
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.showsCursor = false
            config.ignoreShadowsDisplay = true

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )

            guard let screen = Self.screen(for: display.displayID) else { continue }
            snapshots.append(
                DisplaySnapshot(
                    displayID: display.displayID,
                    cgImage: cgImage,
                    screen: screen,
                    frameGlobal: screen.frame,
                    scale: scale
                )
            )
        }

        guard !snapshots.isEmpty else { throw CaptureError.captureFailed }
        return snapshots
    }

    /// 是否已有螢幕錄製權限（試探性呼叫）。
    func hasPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.current
            return true
        } catch {
            return false
        }
    }

    /// 用 CGDirectDisplayID 找對應的 NSScreen。
    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return (screen.deviceDescription[key] as? CGDirectDisplayID) == id
        }
    }

    /// 開啟「系統設定 → 隱私權與安全性 → 螢幕錄製」。
    static func openScreenRecordingSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
