import AppKit
@testable import Otvertka

enum TestSupport {
    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtvertkaTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Отдельный именованный буфер: тесты не трогают системный буфер пользователя.
    static func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("OtvertkaTests-\(UUID().uuidString)"))
    }

    static func pngData(width: Int = 12, height: Int = 8, color: NSColor = .systemBlue) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static func textContent(_ text: String) -> CapturedClipboardContent {
        ClipboardContentReader.analyze(items: [CapturedPasteboardItem(representations: [
            ClipboardRepresentation(type: "public.utf8-plain-text", data: Data(text.utf8)),
        ])])!
    }

    static func window(_ id: String, pid: pid_t = 1, app: String = "App", bundle: String? = nil, title: String = "",
                       z: Int = 0, minimized: Bool = false, hidden: Bool = false) -> WindowInfo {
        WindowInfo(id: id, windowID: nil, pid: pid, bundleID: bundle ?? "com.test.\(app.lowercased())", appName: app,
                   title: title, frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                   isMinimized: minimized, isAppHidden: hidden, zIndex: z)
    }
}
