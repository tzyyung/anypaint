import AppKit
import Vision

/// 圖中文字辨識（Vision）。完全離線；繁中優先＋英文（Vision 規定中文只能配英文）。
/// 已知限制：直式中文辨識不佳（Apple 論壇 749234，記錄不處理）。
public enum TextRecognizer {

    /// 行陣列 → 剪貼簿文字（純函式）。
    public static func joinedText(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    /// 同步辨識（阻塞呼叫緒）：selftest 與背景 queue 用。
    /// 行序＝Vision observations 序（大致由上到下）。
    public static func recognizeSync(cgImage: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hant", "en-US"]   // 繁中必須首位（Vision 規定）
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
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
