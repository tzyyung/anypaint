import AppKit

/// 樣板 %…% 變數的執行期來源。frontWindowTitle 為純函式（raw dicts 注入，selftest 可測）。
public enum CaptureVars {

    /// 最前 layer-0 視窗的標題（kCGWindowName）。raw 陣列序＝CGWindowList 前→後 z-order。
    /// 最前 layer-0 視窗無標題→nil（degrade 交呼叫端；不找下一個視窗——那不是「使用中視窗」）。
    public static func frontWindowTitle(raw: [[String: Any]]) -> String? {
        for dict in raw {
            guard (dict[kCGWindowLayer as String] as? Int) == 0 else { continue }
            if let name = dict[kCGWindowName as String] as? String, !name.isEmpty {
                return name
            }
            return nil
        }
        return nil
    }

    /// 執行期抓 %title%：CGWindowList 最前 layer-0 視窗標題（需螢幕錄製權限，已授權）
    /// → degrade 最前景 app 名稱 → 空字串（spec）。
    public static func currentFrontTitle() -> String {
        let raw = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]]) ?? []
        if let title = frontWindowTitle(raw: raw) { return title }
        return NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
    }

    /// 組 vars dict（os/computername/username/title），供 FilenameTemplate.expand 注入。
    public static func makeVars(title: String) -> [String: String] {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var os = "macOS \(v.majorVersion).\(v.minorVersion)"
        if v.patchVersion > 0 { os += ".\(v.patchVersion)" }
        return [
            "os": os,
            "computername": Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            "username": NSUserName(),
            "title": title,
        ]
    }
}
