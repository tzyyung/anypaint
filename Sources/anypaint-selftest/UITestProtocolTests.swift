import Foundation
import AnypaintKit

/// UITestServer 協定的純邏輯部分（不碰 CFMessagePort）：請求解碼、事件行 JSON 格式。
func uitestProtocolTests() {
    let req = try! JSONSerialization.data(withJSONObject: ["cmd": "getState"])
    T.checkEq("protocol: 請求可解", UITestChannel.decodeCommand(req)?.cmd, "getState")
    let line = UITestChannel.eventLine(seq: 7, name: "recordingStopped",
                                       payload: ["outputURL": "/tmp/x.mp4"])
    let obj = try! JSONSerialization.jsonObject(with: line.data(using: .utf8)!) as! [String: Any]
    T.checkEq("event: seq", obj["seq"] as? Int, 7)
    T.checkEq("event: name", obj["event"] as? String, "recordingStopped")
    T.checkEq("event: payload", obj["outputURL"] as? String, "/tmp/x.mp4")
}
