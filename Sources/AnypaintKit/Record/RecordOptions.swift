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
    /// 麥克風裝置 ID（nil＝系統預設）。
    public var microphoneDeviceID: String?

    public init(showsCursor: Bool, useHEVC: Bool,
                captureSystemAudio: Bool = false, captureMicrophone: Bool = false,
                excludesOwnAudio: Bool = true, microphoneDeviceID: String? = nil) {
        self.showsCursor = showsCursor
        self.useHEVC = useHEVC
        self.captureSystemAudio = captureSystemAudio
        self.captureMicrophone = captureMicrophone
        self.excludesOwnAudio = excludesOwnAudio
        self.microphoneDeviceID = microphoneDeviceID
    }

    // AppSettings 本身無隔離標註，nonisolated 如實反映；勿改回 @MainActor。
    nonisolated
    public static func fromSettings() -> RecordOptions {
        RecordOptions(showsCursor: AppSettings.recordShowsCursor,
                      useHEVC: AppSettings.recordUseHEVC,
                      captureSystemAudio: AppSettings.recordSystemAudio,
                      captureMicrophone: AppSettings.recordMicrophone,
                      microphoneDeviceID: AppSettings.recordMicrophoneDeviceID)
    }

    /// 自檢固定配方：判準確定性，不吃設定。
    public static let selfCheck = RecordOptions(showsCursor: false, useHEVC: false)
}
