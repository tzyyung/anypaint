import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 截圖存檔：檔名規則、碰撞遞增、PNG 寫檔。
/// 檔名與碰撞是純函式（exists 注入），selftest 可測；寫檔部分 headless 也可測。
public enum CaptureSaver {

    /// "anypaint 2026-07-22 21.30.45.png"（與 macOS 內建截圖同風格；固定規則，spec）。
    public static func filename(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "anypaint \(f.string(from: date)).png"
    }

    /// 目標已存在 → 副檔名前加 "-2"、"-3"…直到不碰撞。
    public static func uniquedURL(directory: URL, filename: String,
                                  exists: (URL) -> Bool) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var n = 2
        while exists(candidate) {
            candidate = directory.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// NSImage → PNG 寫檔；上層目錄不存在自動建立。失敗 throw。
    public static func writePNG(image: NSImage, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }

    /// CGImage 直寫 PNG——長圖（可達 30000px）不得經 NSImage→tiffRepresentation
    /// （該鏈同時存在 3 份拷貝，峰值近 GB；spec §8）。上層目錄不存在自動建立（與 NSImage 版對齊）。
    public static func writePNG(cgImage: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
