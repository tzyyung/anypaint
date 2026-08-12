import Foundation

/// 錄製選項的單一載體：AppSettings 的唯一讀取點。
/// RecordFrameSource／WriterBox 不認識全域設定；新選項＝加欄位，不再增生參數列。
public struct RecordOptions: Equatable, Sendable {
    public var showsCursor: Bool
    public var useHEVC: Bool
    public var captureSystemAudio: Bool
    public var captureMicrophone: Bool
    /// 正式流程 true（不錄自家音效）；只有音訊自檢設 false（要聽到自己播的檢測音）。
    public var excludesOwnAudio: Bool

    public init(showsCursor: Bool, useHEVC: Bool,
                captureSystemAudio: Bool = false, captureMicrophone: Bool = false,
                excludesOwnAudio: Bool = true) {
        self.showsCursor = showsCursor
        self.useHEVC = useHEVC
        self.captureSystemAudio = captureSystemAudio
        self.captureMicrophone = captureMicrophone
        self.excludesOwnAudio = excludesOwnAudio
    }

    nonisolated
    public static func fromSettings() -> RecordOptions {
        RecordOptions(showsCursor: AppSettings.recordShowsCursor,
                      useHEVC: AppSettings.recordUseHEVC)
    }

    /// 自檢固定配方：判準確定性，不吃設定。
    public static let selfCheck = RecordOptions(showsCursor: false, useHEVC: false)
}
