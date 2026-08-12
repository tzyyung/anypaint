import Foundation
import AnypaintKit

func fail(_ msg: String) -> Never { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); exit(1) }

// UITestServer.swift 的命令名是駝峰（getState／dumpUI／screenshotSelf）。這裡把常見的
// kebab-case／全小寫別名映射過去，讓 CLI 呼叫端不用背命名規則；駝峰原名照樣直通。
let commandAliases: [String: String] = [
    "getstate": "getState", "get-state": "getState",
    "dumpui": "dumpUI", "dump-ui": "dumpUI",
    "screenshotself": "screenshotSelf", "screenshot-self": "screenshotSelf",
]
func normalizeCommand(_ raw: String) -> String {
    commandAliases[raw.lowercased()] ?? raw
}

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    fail("""
    用法:
      anypaintctl <cmd> [--json '{...}']
      anypaintctl wait-event <name> [--after N] [--timeout S]

    <cmd> 別名（不分大小寫，kebab-case 或駝峰皆可，其餘命令直接透傳原字串）:
      get-state / getstate       -> getState
      dump-ui   / dumpui         -> dumpUI
      screenshot-self / screenshotself -> screenshotSelf
    """)
}
args.removeFirst()

func flag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if cmd == "wait-event" {
    guard let name = args.first else { fail("wait-event 需要事件名") }
    let after = Int(flag("--after") ?? "0") ?? 0
    let timeout = Double(flag("--timeout") ?? "30") ?? 30
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let text = try? String(contentsOfFile: UITestChannel.eventLogPath, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let seq = obj["seq"] as? Int, seq > after,
                      obj["event"] as? String == name else { continue }
                print(line); exit(0)
            }
        }
        usleep(200_000)
    }
    fail("timeout 等不到 \(name)（after=\(after)）")
}

var payload: [String: Any] = ["cmd": normalizeCommand(cmd)]
if let extra = flag("--json"),
   let obj = try? JSONSerialization.jsonObject(with: Data(extra.utf8)) as? [String: Any] {
    payload.merge(obj) { _, new in new }
}
guard let remote = CFMessagePortCreateRemote(nil, UITestChannel.portName as CFString) else {
    fail("連不上 \(UITestChannel.portName)——app 是否以 --uitest 啟動？")
}
let reqData = try! JSONSerialization.data(withJSONObject: payload)
var replyData: Unmanaged<CFData>?
let status = CFMessagePortSendRequest(remote, 0, reqData as CFData, 10, 10,
                                      CFRunLoopMode.defaultMode.rawValue, &replyData)
guard status == kCFMessagePortSuccess, let reply = replyData?.takeRetainedValue() else {
    fail("RPC 失敗 status=\(status)")
}
let out = String(data: reply as Data, encoding: .utf8) ?? ""
print(out)
let ok = (try? JSONSerialization.jsonObject(with: reply as Data) as? [String: Any])?["ok"] as? Bool ?? false
exit(ok ? 0 : 1)
