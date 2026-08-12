import AVFoundation
import CoreMedia

/// 待命試音錶：對指定 uniqueID 的音訊輸入裝置即時算線性 RMS（0..1），供設定頁／HUD 的
/// `LevelMeterView` 與 RPC `micLevel` 使用。
///
/// ### Step 1 技術決策（2026-08-13，brief 指定二選一，記錄選擇與理由）
/// macOS 上「對指定裝置即時算音量」有兩條路：
/// 1. `AVAudioEngine` 的 `AVAudioInputNode.installTap`——但要把整條 engine 釘死在**特定裝置**
///    （非系統預設）上，沒有公開的 `AVAudioEngine` API 可直接設，得繞去 Audio Unit 層
///    （`kAudioOutputUnitProperty_CurrentDevice`），實作面繁瑣、風險較高。
/// 2. `AVCaptureSession` ＋ `AVCaptureAudioDataOutput` ＋ `AVCaptureDeviceInput(device:)`——
///    `AVCaptureDevice(uniqueID:)`（SDK header `AVCaptureDevice.h` 的 `deviceWithUniqueID:`，
///    Swift 側自動橋接為 `init?(uniqueID:)`）可直接拿 A1 `AudioInputDeviceList` 給的
///    `uniqueID` 換到裝置物件，餵給 `AVCaptureDeviceInput(device:)` 就把整條 session 釘死在
///    那顆裝置上，沒有中間層。
///
/// 本專案這次除錯階段已用一次性 probe 實測驗證路線 2 可行（能收到指定裝置的
/// `CMSampleBuffer`），故採用**路線 2**。
///
/// RMS 從 `CMSampleBuffer` 直接算，不經 `AVAssetReader`（那是既有母帶解碼用的路徑，
/// 見 `RecordAudioSelfCheck.decodeMonoSamples`；這裡是即時擷取，沒有檔案可讀）：手法比照
/// 同一個檔案「`CMSampleBufferGetDataBuffer` → `CMBlockBufferCopyDataBytes` 複製裸位元組」，
/// 但這裡要處理的是裝置**原生格式**（`audioSettings` 留 nil，不強制轉碼），格式可能是
/// Float32 或 Int16（部分裝置可能是 Int32），用 ASBD 的 `mFormatFlags`／`mBitsPerChannel`
/// 判斷後分別正規化到 -1..1 再算 RMS。**不分聲道、不管 interleave**：把整段位元組當成一串
/// 樣本值算整體 RMS——這是待命試音錶（回答「有沒有收到聲音」的粗略確認），不是精確逐聲道
/// 電平表，這個近似可接受。
@MainActor
public final class MicLevelMonitor: NSObject {

    /// 節流後的線性 RMS（0..1）回呼，~20Hz。
    public var onLevel: ((Float) -> Void)?
    /// 最新一次算出的線性 RMS（0..1）。**不節流**——供 RPC `micLevel` 之類輪詢式呼叫端隨時讀
    /// 到最新值，節流只限制 `onLevel` 回呼頻率。
    public private(set) var latestLevel: Float = 0

    /// 見 `deinit` 開頭的說明——這個屬性平時只在 MainActor 呼叫的 `start()`/`stop()` 內被
    /// 讀寫（兩者都要求先持有一個活著的 self 才呼叫得到），標 `nonisolated(unsafe)` 只是為了
    /// 讓 `deinit`（非 MainActor 的執行環境）也能讀到它；`deinit` 開始執行代表已經沒有任何
    /// 存活的 strong reference 指向這個實例，`start()`/`stop()` 之後不可能再被呼叫，因此這裡
    /// 不會有真正的資料競爭（比照 `RecordFrameSource.box` 的 `nonisolated(unsafe)` 豁免理由，
    /// 但這裡的不變式建立在物件生命週期上，不是佇列邊界上）。
    private nonisolated(unsafe) var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    /// 目前 session 的 sample buffer delegate。**只被 `session`/`output` 透過 `addOutput`
    /// 間接保留還不夠保險**（delegate 屬性的保留策略未在 SDK header 明文——不假設），這裡額外
    /// 存一份強參照，確保它至少活到 `stop()` 明確清掉為止。
    private var forwarder: SampleForwarder?
    /// session 生命週期（`startRunning`/`stopRunning`）用的佇列——`startRunning()` 會阻塞呼叫
    /// 執行緒直到啟動完成，不可在 MainActor 上直接呼叫（CLAUDE.md「不要塞爆主執行緒」的一貫
    /// 紀律）。與 `sampleQueue` 分開，兩者互不等待。`nonisolated`：純不可變的 `DispatchQueue`
    /// 常數（Sendable、init 後不再變動），`deinit` 也要用它派工，讓它可以從任何隔離環境讀取。
    private nonisolated let sessionQueue = DispatchQueue(label: "anypaint.miclevel.session")
    /// 樣本 buffer 送達的佇列（`AVCaptureAudioDataOutput` 的 `sampleBufferCallbackQueue`）。
    private let sampleQueue = DispatchQueue(label: "anypaint.miclevel.sample")

    /// 上次呼叫 `onLevel` 的時間（`ProcessInfo.systemUptime`——單調時鐘，這裡純粹當節流間隔用，
    /// 選它只是就地取材、與專案其餘計時邏輯一致，不代表對齊 SCK 的 PTS 時鐘）。
    private var lastCallbackTime: TimeInterval = 0
    /// 節流間隔：50ms ≈ 20Hz（brief 指定）。
    private let throttleInterval: TimeInterval = 0.05

    /// session 世代號：每次 `start()` 建出新 session、或 `stop()` 收掉現有 session 都遞增。
    /// `SampleForwarder` 記著自己出生時的世代號，`handleLevel(_:generation:)` 只接受世代號與
    /// 「當下」相符的結果——**修掉 fix round 1 抓到的殘留 bug**：`stop()` 把 `latestLevel`
    /// 歸零之後，舊 session 排進 `sampleQueue`／已經在飛的 `Task { @MainActor }` 遲到才執行，
    /// 若不擋，會把 `latestLevel` 蓋回一個非零舊值，而且之後沒有新 buffer 會再覆寫它——電平表
    /// 停止後看起來「卡在最後一格」。世代號比對讓任何舊世代的遲到結果被直接丟棄。
    private var generation = 0

    public override init() { super.init() }

    /// 防禦性收尾：呼叫端忘記呼叫 `stop()` 時，避免麥克風 session 一路開著到 ARC 某個不確定
    /// 時間點才收尾（可能多佔用硬體資源一段時間）。`stopRunning()` 一樣派工到
    /// `sessionQueue`、不在 `deinit` 內同步呼叫——`deinit` 執行的執行緒不保證是背景執行緒，
    /// 若剛好是 MainActor，同步呼叫會塞住主執行緒（同 `stop()` 為什麼要派工的理由）。
    deinit {
        if let session {
            let box = SessionBox(session)
            sessionQueue.async { box.stop() }
        }
    }

    /// 對 `deviceID` 指定的裝置開始即時算 RMS；`nil` 用系統預設輸入
    /// （`AVCaptureDevice.default(for:.audio)`，同 `AudioInputDeviceList.systemDefaultID()`
    /// 底層呼叫的同一支 API）。
    ///
    /// 前置動作：先停掉舊的（`start` 是換裝置的唯一入口，不會疊兩條 session）。
    /// 未授權（`AVCaptureDevice.authorizationStatus` 非 `.authorized`）或裝置不存在
    /// （`AVCaptureDevice(uniqueID:)` 回 nil，例如已拔線）或裝置忙碌
    /// （`AVCaptureDeviceInput(device:)` 拋錯）時**靜默不啟動**：`latestLevel` 停在 0、
    /// `onLevel` 不會被呼叫，不 crash。
    ///
    /// **不在這裡要求麥克風權限**：本 app 既有的權限請求走
    /// `CaptureSettingsViewController` 勾選「錄製麥克風」核取方塊那條路
    /// （`AVCaptureDevice.requestAccess`），試音錶只消費既有授權狀態，不重複觸發系統對話框。
    public func start(deviceID: String?) {
        stop()
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) }
            ?? AVCaptureDevice.default(for: .audio)
        guard let device else { return }

        let newSession = AVCaptureSession()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard newSession.canAddInput(input) else { return }
            newSession.addInput(input)
        } catch {
            return   // 裝置忙碌／已拔線等實機常見狀況：不 crash，維持恆靜音
        }
        let newOutput = AVCaptureAudioDataOutput()
        guard newSession.canAddOutput(newOutput) else { return }

        // 確定會成功才遞增世代號、建 forwarder——避免中途失敗的路徑白白燒掉一個世代號
        // （無害，但徒增追蹤負擔）。
        generation += 1
        let newForwarder = SampleForwarder(monitor: self, generation: generation)
        newOutput.setSampleBufferDelegate(newForwarder, queue: sampleQueue)
        newSession.addOutput(newOutput)

        session = newSession
        output = newOutput
        forwarder = newForwarder
        latestLevel = 0
        lastCallbackTime = 0
        let box = SessionBox(newSession)
        sessionQueue.async { box.start() }
    }

    /// 停止試音錶：先遞增世代號（讓任何仍在飛的舊 forwarder 結果被判定過期）、清掉 delegate
    /// （避免 session→output→delegate 疊成保留循環——雖然 delegate 是 `forwarder` 不是
    /// `self`，`forwarder` 只弱參照 `monitor`，理論上已經沒有循環，這裡仍明確清空，不依賴
    /// 「目前沒有循環」這個較脆弱的推論），派工到 `sessionQueue` 呼叫 `stopRunning()`——不等
    /// 它完成，fire-and-forget：沒有檔案要保護（同 `RecordFrameSource` 的 WriterBox 收尾
    /// 不同，這裡沒有母帶完整性要顧），`latestLevel` 立刻歸零讓呼叫端馬上看到「已停」。
    public func stop() {
        guard let session else { return }
        generation += 1
        self.session = nil
        output?.setSampleBufferDelegate(nil, queue: nil)
        output = nil
        forwarder = nil
        latestLevel = 0
        let box = SessionBox(session)
        sessionQueue.async { box.stop() }
    }

    /// 節流＋更新：`latestLevel` 每次都更新，`onLevel` 依 `throttleInterval` 節流。
    /// `generation` 與呼叫當下的 `self.generation` 不符──代表這是舊 session（已經
    /// `stop()` 過，或已經被新的 `start()` 取代）的遲到結果，整個丟棄（fix round 1）。
    fileprivate func handleLevel(_ rms: Float, generation: Int) {
        guard generation == self.generation else { return }
        latestLevel = rms
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastCallbackTime >= throttleInterval else { return }
        lastCallbackTime = now
        onLevel?(rms)
    }

    /// 純計算：從 `CMSampleBuffer` 算線性 RMS（0..1）。`nil`＝格式判不出來或複製失敗，
    /// 呼叫端靜默跳過這個 buffer（不影響下一個 buffer，不 crash）。
    fileprivate nonisolated static func computeRMS(from sampleBuffer: CMSampleBuffer) -> Float? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        let asbd = asbdPtr.pointee
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        let status = bytes.withUnsafeMutableBytes { raw -> OSStatus in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                       destination: raw.baseAddress!)
        }
        guard status == noErr else { return nil }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        var sumSquares = 0.0
        var count = 0
        bytes.withUnsafeBytes { raw in
            if isFloat, asbd.mBitsPerChannel == 32 {
                let samples = raw.bindMemory(to: Float32.self)
                for v in samples { sumSquares += Double(v) * Double(v) }
                count = samples.count
            } else if isSignedInt, asbd.mBitsPerChannel == 16 {
                let samples = raw.bindMemory(to: Int16.self)
                for v in samples {
                    let f = Double(v) / 32_768.0
                    sumSquares += f * f
                }
                count = samples.count
            } else if isSignedInt, asbd.mBitsPerChannel == 32 {
                let samples = raw.bindMemory(to: Int32.self)
                for v in samples {
                    let f = Double(v) / 2_147_483_648.0
                    sumSquares += f * f
                }
                count = samples.count
            }
            // 其餘格式（少見的 8/24-bit 容器等）：count 留 0，下面回 nil，靜默跳過這個 buffer。
        }
        guard count > 0 else { return nil }
        return Float(sqrt(sumSquares / Double(count)))
    }

    /// 每個 `start()` 呼叫建立一個新的 forwarder，只認得自己出生時的世代號——`stop()`／換
    /// 裝置後，舊世代的遲到 buffer 一律被 `handleLevel(_:generation:)` 擋下，不會覆寫已經
    /// 歸零的 `latestLevel`（fix round 1，team-lead 審查抓到的殘留 bug）。獨立成一個物件
    /// （而非讓 `MicLevelMonitor` 自己當 delegate）還有第二個好處：它只弱參照 `monitor`，
    /// `session`/`output` 對它的保留完全不會構成 monitor↔session 的循環參照。
    private final class SampleForwarder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
        weak var monitor: MicLevelMonitor?
        let generation: Int

        init(monitor: MicLevelMonitor, generation: Int) {
            self.monitor = monitor
            self.generation = generation
        }

        /// AVFoundation 在 `sampleQueue`（背景執行緒）呼叫。算完 RMS 後跳 MainActor 更新
        /// `latestLevel`／呼叫 `onLevel`（照 `RecordFrameSource.onStreamError` 的既有慣例）。
        func captureOutput(_ output: AVCaptureOutput, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            guard let rms = MicLevelMonitor.computeRMS(from: sampleBuffer) else { return }
            let generation = self.generation
            Task { @MainActor [weak monitor] in
                monitor?.handleLevel(rms, generation: generation)
            }
        }
    }
}

/// `AVCaptureSession` 的執行緒邊界包裝。比照 `WriterBox`（`RecordFrameSource.swift`）的
/// `@unchecked Sendable` 成立條件：建構發生在 MainActor（`start()`/`stop()` 呼叫端），賦值進
/// `sessionQueue.async` 閉包之後只在那顆佇列上被觸碰（`startRunning`/`stopRunning`），沒有
/// 任何跨佇列直接讀寫的路徑——真正的隔離邊界在呼叫端（誰負責派工進 `sessionQueue`），不需要
/// `AVCaptureSession` 本身符合 `Sendable`（它是 AVFoundation 的一般 NSObject 子類，SDK 沒有
/// 標成 Sendable）。
private final class SessionBox: @unchecked Sendable {
    let session: AVCaptureSession
    init(_ session: AVCaptureSession) { self.session = session }
    func start() { session.startRunning() }
    func stop() { session.stopRunning() }
}
