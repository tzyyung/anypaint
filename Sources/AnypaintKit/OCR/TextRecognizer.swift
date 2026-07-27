import AppKit
import Vision

/// 圖中文字辨識（Vision）。完全離線；繁中優先＋英文（Vision 規定中文只能配英文）。
/// 已知限制：直式中文辨識不佳（Apple 論壇 749234，記錄不處理）。
public enum TextRecognizer {

    /// 一次辨識的結果。
    ///
    /// **條碼優先於文字**：畫面上有 QR 時，使用者刻意框住它就是想拿裡面的內容——
    /// 這比同一區域裡的文字是更強的意圖訊號（QR 底下常印著說明文字，若以文字為先就永遠拿不到）。
    public enum Recognition: Equatable {
        case barcode([String])
        case text([String])
        case empty

        /// 要放進剪貼簿／顯示的字串。
        public var joined: String {
            switch self {
            case .barcode(let codes): return codes.joined(separator: "\n")
            case .text(let lines): return TextRecognizer.joinedText(lines)
            case .empty: return ""
            }
        }
    }

    /// 行陣列 → 剪貼簿文字（純函式）。
    public static func joinedText(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    /// 文字＋條碼一次辨識（同步、阻塞呼叫緒）。
    ///
    /// 兩個 request 交給**同一個** handler 一起 perform——省一次影像前處理。
    /// 不去設 `symbologies`：預設就會偵測 Vision 支援的全部種類，而查詢支援清單依 header
    /// 註解「could be a potentially expensive operation」，沒必要付這個代價。
    public static func recognizeContentSync(cgImage: CGImage) throws -> Recognition {
        let textRequest = makeTextRequest()
        let codeRequest = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([textRequest, codeRequest])

        // payloadStringValue 是 nullable（header 明載：依 symbology／payload 內容可能無字串表示）
        // → compactMap 掉，不能強解。
        let codes = (codeRequest.results ?? []).compactMap { $0.payloadStringValue }
            .filter { !$0.isEmpty }
        if !codes.isEmpty { return .barcode(codes) }

        let lines = textLines(from: textRequest)
        return lines.isEmpty ? .empty : .text(lines)
    }

    /// 背景辨識、main queue 回呼（UI 用）。
    public static func recognizeContent(cgImage: CGImage,
                                        completion: @escaping (Result<Recognition, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try recognizeContentSync(cgImage: cgImage) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 只辨文字的同步版（阻塞呼叫緒）：selftest 與純文字路徑用。
    /// 行序＝Vision observations 序（大致由上到下）。
    public static func recognizeSync(cgImage: CGImage) throws -> [String] {
        let request = makeTextRequest()
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        return textLines(from: request)
    }

    private static func makeTextRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hant", "en-US"]   // 繁中必須首位（Vision 規定）
        request.usesLanguageCorrection = true
        return request
    }

    private static func textLines(from request: VNRecognizeTextRequest) -> [String] {
        (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// 背景辨識、main queue 回呼（UI 用）。
    public static func recognize(cgImage: CGImage,
                                 completion: @escaping (Result<[String], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try recognizeSync(cgImage: cgImage) }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
