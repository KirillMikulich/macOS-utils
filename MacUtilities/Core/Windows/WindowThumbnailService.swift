import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Миниатюры окон через ScreenCaptureKit (`SCScreenshotManager`, macOS 14+).
///
/// - Без разрешения Screen Recording сервис ничего не захватывает и НЕ вызывает системный
///   запрос: ScreenCaptureKit показал бы диалог при первом обращении, поэтому сначала
///   проверяется `CGPreflightScreenCaptureAccess()`.
/// - Свёрнутые окна захватить нельзя (их нет на экране). Для них возвращается последняя
///   удачная миниатюра из кэша, если окно было видно раньше в этом сеансе.
/// - Кэш в памяти ограничен по количеству и объёму; на диск миниатюры не пишутся.
@MainActor
final class WindowThumbnailService {
    private final class ImageBox {
        let image: CGImage
        let date: Date
        init(image: CGImage, date: Date) { self.image = image; self.date = date }
    }

    private let cache = NSCache<NSNumber, ImageBox>()
    private var shareableContent: SCShareableContent?
    private var shareableContentDate: Date?

    init() {
        cache.countLimit = 80
        cache.totalCostLimit = 120 * 1024 * 1024
    }

    var canCapture: Bool { CGPreflightScreenCaptureAccess() }

    func cachedThumbnail(for windowID: CGWindowID) -> CGImage? {
        cache.object(forKey: NSNumber(value: windowID))?.image
    }

    /// Захватывает миниатюры указанных окон. `maxPixelSize` — максимальная сторона в пикселях.
    /// Результат приходит по мере готовности через `onImage` (на главном потоке).
    func loadThumbnails(for windows: [WindowInfo],
                        maxPixelSize: CGFloat,
                        maxAge: TimeInterval = 0.5,
                        onImage: @escaping (String, CGImage) -> Void) async {
        // Сначала отдаём то, что уже есть в кэше (включая свёрнутые окна).
        var toCapture: [WindowInfo] = []
        for window in windows {
            guard let id = window.windowID else { continue }
            if let cached = cache.object(forKey: NSNumber(value: id)) {
                onImage(window.id, cached.image)
                if window.isMinimized || Date().timeIntervalSince(cached.date) < maxAge { continue }
            }
            if !window.isMinimized && !window.isAppHidden { toCapture.append(window) }
        }
        guard canCapture, !toCapture.isEmpty, let content = await currentShareableContent() else { return }

        let scWindows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        await withTaskGroup(of: (String, CGWindowID, CGImage?).self) { group in
            for window in toCapture {
                guard let windowID = window.windowID, let scWindow = scWindows[windowID] else { continue }
                let frame = scWindow.frame
                group.addTask {
                    let image = await Self.capture(scWindow, frame: frame, maxPixelSize: maxPixelSize)
                    return (window.id, windowID, image)
                }
            }
            for await (id, windowID, image) in group {
                guard let image else { continue }
                let cost = image.bytesPerRow * image.height
                cache.setObject(ImageBox(image: image, date: Date()), forKey: NSNumber(value: windowID), cost: cost)
                onImage(id, image)
            }
        }
    }

    func clearCache() {
        cache.removeAllObjects()
        shareableContent = nil
    }

    private func currentShareableContent() async -> SCShareableContent? {
        if let shareableContent, let date = shareableContentDate, Date().timeIntervalSince(date) < 1.0 {
            return shareableContent
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            shareableContent = content
            shareableContentDate = Date()
            return content
        } catch {
            Log.windows.error("SCShareableContent failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private nonisolated static func capture(_ window: SCWindow, frame: CGRect, maxPixelSize: CGFloat) async -> CGImage? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        // Масштаб фильтра учитывает Retina; ограничиваем максимальную сторону.
        let pointScale = CGFloat(filter.pointPixelScale)
        let scale = min(1.0, maxPixelSize / (max(frame.width, frame.height) * pointScale)) * pointScale
        configuration.width = max(1, Int(frame.width * scale))
        configuration.height = max(1, Int(frame.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            Log.windows.debug("Capture failed for window \(window.windowID): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
