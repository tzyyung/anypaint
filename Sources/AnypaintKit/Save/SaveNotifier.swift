import AppKit
import Foundation
import UserNotifications

/// 存檔完成系統通知。
/// 裸 binary（swift run）無 bundle：UNUserNotificationCenter.current() 會 NSException crash——
/// 以 bundleIdentifier 防呆；實跑一律 scripts/build_app.sh 的 .app（專案既定做法）。
public final class SaveNotifier: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = SaveNotifier()
    private override init() { super.init() }

    /// 發「已儲存 <檔名>」。權限拒絕＝靜默不發，不影響存檔（spec degrade）。
    /// requestAuthorization 重複呼叫不會重複彈框；add 放 completion 內避免首發丟失。
    ///
    /// - Parameters:
    ///   - filename: 顯示在通知裡的檔名。
    ///   - fileURL: 非 nil 時塞進 userInfo，使用者點擊通知可開啟檔案位置；nil＝行為不變。
    public func notifySaved(filename: String, fileURL: URL? = nil) {
        guard Bundle.main.bundleIdentifier != nil else { return }   // 無 bundle 防 crash
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let content = UNMutableNotificationContent()
        content.title = "anypaint"
        content.body = "已儲存 \(filename)"
        if let fileURL {
            content.userInfo["filePath"] = fileURL.path
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            center.add(request)
        }
    }

    /// app 在前景時也顯示 banner（截圖剛結束時 anypaint 常是前景）。
    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler:
                                           @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    /// 使用者點擊通知時開啟檔案位置。
    /// 檔案已被移走或刪除時 activateFileViewerSelecting 是安靜 no-op，可接受（spec §1.1）。
    /// NSWorkspace 的執行緒親和性 header 未載明——防禦性跳主執行緒（成本為零）。
    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler:
                                           @escaping () -> Void) {
        if let filePath = response.notification.request.content.userInfo["filePath"] as? String {
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
            }
        }
        completionHandler()
    }
}
