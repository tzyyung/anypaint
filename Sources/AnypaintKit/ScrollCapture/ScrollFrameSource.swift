import AppKit
import ScreenCaptureKit
import CoreImage

/// SCStream 封裝（spec §4）：吐出「已裁到選區、RGBA8」的影格。單一職責：抓活影格。
@MainActor
public final class ScrollFrameSource: NSObject {
    public var onFrame: ((PixelBuffer) -> Void)?
    public var onStreamError: ((Error) -> Void)?
    public private(set) var lastFrameAt: TimeInterval = 0

    private var stream: SCStream?
    private var pendingStop = false
    // nonisolated：handler 在 sampleQueue（非 MainActor）上直接讀取；CIContext 本身執行緒安全，
    // 但 @MainActor class 的 stored property 預設吃 MainActor 隔離，nonisolated context 存取不了——
    // 移出隔離讓 delegate callback 能直接用（brief 註記的編譯器限制，行為不變）。
    private nonisolated let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let sampleQueue = DispatchQueue(label: "anypaint.scroll.frames")

    public func start(selectionGlobal: CGRect, screen: NSScreen) async throws {
        pendingStop = false
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let displayID = screen.deviceDescription[key] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noDisplays
        }
        // 按 app 排除自家（HUD/選區框/預覽全部涵蓋，含 session 中途才開的視窗）
        let selfApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: selfApps, exceptingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let geo = ScrollCoords.streamGeometry(selectionGlobal: selectionGlobal,
                                              screenFrameGlobal: screen.frame, scale: scale)
        let config = SCStreamConfiguration()
        config.sourceRect = geo.sourceRect
        config.width = geo.pixelWidth          // 必設：預設會縮到 1920×1080（SDK 行為，SDK header 已核）
        config.height = geo.pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.showsCursor = false
        config.captureResolution = .best
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        if pendingStop {
            // start 的 await 期間被 stop()——立即收掉這條剛啟動的 stream，不外洩
            try? await stream.stopCapture()
            return
        }
        self.stream = stream
    }

    public func stop() async {
        pendingStop = true
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }
}

extension ScrollFrameSource: SCStreamOutput, SCStreamDelegate {
    nonisolated public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        // 只收 .complete；.idle（畫面沒變）丟棄——靜止時 SCStream 不產新格（spec §4 關鍵事實）
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              statusRaw == SCFrameStatus.complete.rawValue,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sb) else { return }
        // handler 內立即轉 CGImage（IOSurface 池只有 queueDepth 張，扣住就停流）
        let cgImage: CGImage? = autoreleasepool {
            let ci = CIImage(cvPixelBuffer: pixelBuffer)
            return ciContext.createCGImage(ci, from: ci.extent)
        }
        guard let cg = cgImage, let pb = PixelBuffer(cgImage: cg) else { return }
        Task { @MainActor in
            self.lastFrameAt = ProcessInfo.processInfo.systemUptime
            self.onFrame?(pb)
        }
    }

    nonisolated public func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.onStreamError?(error) }
    }
}
