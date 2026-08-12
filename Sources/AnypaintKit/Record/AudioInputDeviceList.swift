import AVFoundation

public struct AudioInputDevice: Equatable, Sendable {
    public let uniqueID: String
    public let name: String
    public let isDefault: Bool
}

/// 列舉音訊輸入裝置。`isDefault` 真正對照系統預設（不硬編碼——BetterCapture 的坑）。
/// 過濾系統聚合裝置（CADefaultDeviceAggregate 類——QuickRecorder 經驗）。
///
/// SDK header 查證（2026-08-13，`xcrun --show-sdk-path` 下 AVCaptureDevice.h）：
/// - `AVCaptureDeviceTypeMicrophone`（Swift `.microphone`）：`API_AVAILABLE(macos(14.0), ...)`。
/// - `AVCaptureDeviceTypeExternal`（Swift `.external`）：`API_AVAILABLE(macos(14.0), ...)`，
///   非棄用；`AVCaptureDeviceTypeExternalUnknown`（`.externalUnknown`）反而是被
///   `API_DEPRECATED_WITH_REPLACEMENT("AVCaptureDeviceTypeExternal", macos(10.15, 14.0))`
///   取代的舊名。故用 `.external`，不用 `.externalUnknown`。
/// 兩者在 macOS 14 起可用，涵蓋 macOS 15。
public enum AudioInputDeviceList {
    public static func systemDefaultID() -> String? {
        AVCaptureDevice.default(for: .audio)?.uniqueID
    }

    public static func all() -> [AudioInputDevice] {
        let defID = systemDefaultID()
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        return session.devices
            .filter { !$0.localizedName.contains("CADefaultDeviceAggregate") }
            .map { AudioInputDevice(uniqueID: $0.uniqueID, name: $0.localizedName,
                                    isDefault: $0.uniqueID == defID) }
    }
}
