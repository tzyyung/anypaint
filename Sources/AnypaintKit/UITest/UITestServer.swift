import AppKit

/// RPC 協定的純邏輯部分（selftest 可測，不碰 port）。
public enum UITestChannel {
    public static let portName = "com.aidaris.anypaint.uitest"
    public static let eventLogPath = "/tmp/anypaint-uitest-events.jsonl"
    public static let shotsDir = "/tmp/anypaint-uitest-shots"

    public struct Command { public let cmd: String; public let json: [String: Any] }

    public static func decodeCommand(_ data: Data) -> Command? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = obj["cmd"] as? String else { return nil }
        return Command(cmd: cmd, json: obj)
    }

    public static func eventLine(seq: Int, name: String, payload: [String: Any]) -> String {
        var obj = payload
        obj["seq"] = seq
        obj["event"] = name
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }
}

/// `--uitest` 才啟動的本機 RPC 伺服器。port 註冊在 main runloop → callback 在主執行緒，
/// 可直接碰 @MainActor 狀態（MainActor.assumeIsolated）。正常啟動完全不註冊（安全邊界）。
@MainActor
public final class UITestServer {
    public private(set) static var shared: UITestServer?
    private var port: CFMessagePort?
    private var seq = 0

    /// 命令接線出口（AppDelegate 在 `startIfRequested()` 之後設）：內建命令（getState／dumpUI／
    /// screenshotSelf）之外的命令都先問這個閉包。回 `nil`（閉包本身是 nil，或閉包執行後回 nil＝
    /// 「不是我認的命令」）都照走原本的 `unknownCommand`——不是「有 handler 就必定認得」。
    public var commandHandler: ((UITestChannel.Command) -> [String: Any]?)?

    public static func startIfRequested() {
        guard CommandLine.arguments.contains("--uitest")
                || AppSettings.allowLocalAutomation else { return }
        shared = UITestServer()
        shared?.register()
    }

    private func register() {
        var ctx = CFMessagePortContext(version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: CFMessagePortCallBack = { _, _, data, info in
            guard let info else { return nil }
            let server = Unmanaged<UITestServer>.fromOpaque(info).takeUnretainedValue()
            let reply = MainActor.assumeIsolated {
                server.handle((data as Data?) ?? Data())
            }
            return Unmanaged.passRetained(reply as CFData)
        }
        guard let p = CFMessagePortCreateLocal(nil, UITestChannel.portName as CFString,
                                               callback, &ctx, nil) else { return }
        port = p
        let source = CFMessagePortCreateRunLoopSource(nil, p, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        try? FileManager.default.createDirectory(atPath: UITestChannel.shotsDir,
                                                 withIntermediateDirectories: true)
        emit("channelReady", [:])
    }

    /// 事件寫檔（seq 單調遞增；診斷寫檔原則——NSLog 撈不到）。
    public func emit(_ name: String, _ payload: [String: Any]) {
        seq += 1
        let line = UITestChannel.eventLine(seq: seq, name: name, payload: payload) + "\n"
        if let h = FileHandle(forWritingAtPath: UITestChannel.eventLogPath) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(toFile: UITestChannel.eventLogPath, atomically: true, encoding: .utf8)
        }
    }

    private func reply(_ obj: [String: Any]) -> Data {
        var o = obj; o["seq"] = seq
        return (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
    }

    private func handle(_ data: Data) -> Data {
        guard let command = UITestChannel.decodeCommand(data) else {
            return reply(["ok": false, "error": "badRequest"])
        }
        switch command.cmd {
        case "getState":
            let windows = NSApp.windows.filter(\.isVisible).map {
                ["title": $0.title, "frame": NSStringFromRect($0.frame),
                 "class": String(describing: type(of: $0))]
            }
            return reply(["ok": true, "windows": windows,
                          "eventLog": UITestChannel.eventLogPath])
        case "dumpUI":
            let tree = NSApp.windows.filter(\.isVisible).map { win in
                ["title": win.title, "class": String(describing: type(of: win)),
                 "views": Self.viewTree(win.contentView)]
            }
            return reply(["ok": true, "tree": tree])
        case "screenshotSelf":
            var paths: [String] = []
            for (i, win) in NSApp.windows.filter(\.isVisible).enumerated() {
                guard let v = win.contentView,
                      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                v.cacheDisplay(in: v.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                let path = "\(UITestChannel.shotsDir)/win\(i)-\(Int(Date().timeIntervalSince1970)).png"
                try? png.write(to: URL(fileURLWithPath: path))
                paths.append(path)
            }
            return reply(["ok": true, "paths": paths])
        default:
            if let result = commandHandler?(command) {
                return reply(result)
            }
            return reply(["ok": false, "error": "unknownCommand:\(command.cmd)"])
        }
    }

    private static func viewTree(_ view: NSView?) -> [String: Any] {
        guard let view else { return [:] }
        var node: [String: Any] = ["class": String(describing: type(of: view)),
                                   "frame": NSStringFromRect(view.frame),
                                   "hidden": view.isHidden]
        if let b = view as? NSButton { node["title"] = b.title; node["enabled"] = b.isEnabled }
        if let t = view as? NSTextField { node["text"] = t.stringValue }
        if !view.subviews.isEmpty { node["subviews"] = view.subviews.map { viewTree($0) } }
        return node
    }
}
