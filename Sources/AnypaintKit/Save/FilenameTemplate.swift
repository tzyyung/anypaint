import Foundation

/// 檔名/路徑樣板展開：$…$ 日期 token＋%…% 變數＋非法字元清洗。
/// 純 Foundation、無狀態，selftest 可測。
/// token 對照自行實作——z（毫秒）、t（時區）與 DateFormatter 慣例衝突，不可丟 DateFormatter（spec）。
public enum FilenameTemplate {

    /// 預設樣板（與升級前的固定檔名規則一致）。
    public static let defaultName = "anypaint $yyyy-MM-dd HH.mm.ss$.png"

    // 星期/月份名稱固定英文（spec：en_US_POSIX 語意）。
    private static let weekAbbr = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let weekFull = ["Sunday", "Monday", "Tuesday", "Wednesday",
                                   "Thursday", "Friday", "Saturday"]
    private static let monthAbbr = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let monthFull = ["January", "February", "March", "April",
                                    "May", "June", "July", "August",
                                    "September", "October", "November", "December"]

    /// 展開樣板。vars 由呼叫端注入（os/computername/username/title）。
    /// timeZone 預設本機；測試注入固定時區（可測性必需，spec 簽章之外的預設參數）。
    public static func expand(_ template: String, date: Date,
                              vars: [String: String],
                              timeZone: TimeZone = .current) -> String {
        var out = ""
        var i = template.startIndex
        while i < template.endIndex {
            let ch = template[i]
            if ch == "$",
               let close = template[template.index(after: i)...].firstIndex(of: "$") {
                let inner = String(template[template.index(after: i)..<close])
                out += expandDateTokens(inner, date: date, timeZone: timeZone)
                i = template.index(after: close)
            } else if ch == "%",
                      let close = template[template.index(after: i)...].firstIndex(of: "%") {
                let inner = String(template[template.index(after: i)..<close])
                if let value = variableValue(inner, vars: vars) {
                    // 變數展開值中的 / 一律換 -（title 不會被當目錄，spec 定案）
                    out += value.replacingOccurrences(of: "/", with: "-")
                } else {
                    out += "%\(inner)%"   // 未知變數原樣保留
                }
                i = template.index(after: close)
            } else {
                out.append(ch)   // 未配對的 $/% 也走這裡：字面保留
                i = template.index(after: i)
            }
        }
        // 非法字元清洗：整串展開結果替換（樣板字面的 : 也清）；/ 保留為目錄分隔。
        for bad in ["|", ":", "*", "?", "<", ">"] {
            out = out.replacingOccurrences(of: bad, with: "-")
        }
        return out
    }

    /// 樣板/路徑是否以 .png 結尾（大小寫不拘）。
    public static func hasPNGExtension(_ s: String) -> Bool {
        s.lowercased().hasSuffix(".png")
    }

    /// 結尾非指定副檔名（大小寫不拘）時補上。ext 不含點（"mp4"/"gif"/"png"）。
    public static func ensuringExtension(_ s: String, ext: String) -> String {
        s.lowercased().hasSuffix("." + ext.lowercased()) ? s : s + "." + ext
    }

    /// 展開結果補正：結尾非 .png 時補上。
    public static func ensuringPNGExtension(_ s: String) -> String {
        ensuringExtension(s, ext: "png")
    }

    /// 檔名段（最後路徑段）為空或僅剩清洗替代字/空白/點 → 以 fallbackName 取代檔名段（spec 邊界）。
    public static func ensuringMeaningfulFilename(_ expandedPath: String,
                                                  fallbackName: String) -> String {
        let name = (expandedPath as NSString).lastPathComponent
        let stripped = name
            .replacingOccurrences(of: ".png", with: "", options: .caseInsensitive)
            .filter { $0 != "-" && $0 != " " && $0 != "." }
        guard stripped.isEmpty else { return expandedPath }
        let dir = (expandedPath as NSString).deletingLastPathComponent
        return dir.isEmpty ? fallbackName : dir + "/" + fallbackName
    }

    /// %…% 變數值：精確 key 比對；title:N（N 正整數）截前 N 字。未知回 nil。
    private static func variableValue(_ name: String, vars: [String: String]) -> String? {
        if let v = vars[name] { return v }
        if name.hasPrefix("title:"),
           let n = Int(name.dropFirst("title:".count)), n > 0,
           let title = vars["title"] {
            return String(title.prefix(n))
        }
        return nil
    }

    /// $…$ 內的日期 token 最長優先替換；非 token 字元原樣保留。
    private static func expandDateTokens(_ s: String, date: Date,
                                         timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday],
                                   from: date)
        // 毫秒從 epoch 四捨五入——DateComponents.nanosecond 有浮點誤差（7ms 會拿到 6999999…ns）
        let ms = Int((date.timeIntervalSince1970 * 1000).rounded()) % 1000
        func pad(_ v: Int, _ w: Int) -> String { String(format: "%0\(w)d", v) }
        let offset = timeZone.secondsFromGMT(for: date)
        let tz = (offset < 0 ? "-" : "+")
            + pad(abs(offset) / 3600, 2) + pad(abs(offset) % 3600 / 60, 2)
        // 陣列序＝match 優先序：同前綴由長到短（dddd 在 dd 前），確保最長優先。
        let tokens: [(String, String)] = [
            ("dddd", weekFull[(c.weekday ?? 1) - 1]),
            ("ddd", weekAbbr[(c.weekday ?? 1) - 1]),
            ("dd", pad(c.day ?? 0, 2)), ("d", "\(c.day ?? 0)"),
            ("MMMM", monthFull[(c.month ?? 1) - 1]),
            ("MMM", monthAbbr[(c.month ?? 1) - 1]),
            ("MM", pad(c.month ?? 0, 2)), ("M", "\(c.month ?? 0)"),
            ("yyyy", pad(c.year ?? 0, 4)), ("yy", pad((c.year ?? 0) % 100, 2)),
            ("HH", pad(c.hour ?? 0, 2)), ("H", "\(c.hour ?? 0)"),
            ("mm", pad(c.minute ?? 0, 2)), ("m", "\(c.minute ?? 0)"),
            ("ss", pad(c.second ?? 0, 2)), ("s", "\(c.second ?? 0)"),
            ("zzz", pad(ms, 3)), ("z", "\(ms)"),
            ("t", tz),
        ]
        var out = ""
        var i = s.startIndex
        scan: while i < s.endIndex {
            for (tok, val) in tokens where s[i...].hasPrefix(tok) {
                out += val
                i = s.index(i, offsetBy: tok.count)
                continue scan
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}
