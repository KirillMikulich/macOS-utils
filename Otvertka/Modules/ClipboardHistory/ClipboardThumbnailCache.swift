import AppKit
import ImageIO

/// Миниатюры изображений из истории. Генерируются лениво (когда строка видна) на фоне
/// через ImageIO, без декодирования полноразмерной картинки; хранятся в NSCache.
@MainActor
final class ClipboardThumbnailCache {
    private let cache = NSCache<NSUUID, NSImage>()

    init() {
        cache.countLimit = 200
    }

    func cached(_ id: UUID) -> NSImage? {
        cache.object(forKey: id as NSUUID)
    }

    func thumbnail(for item: ClipboardItem, store: ClipboardStore, maxPixelSize: Int = 160) async -> NSImage? {
        if let cached = cached(item.id) { return cached }
        guard let data = store.imageData(for: item) else { return nil }
        let image = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value
        if let image { cache.setObject(image, forKey: item.id as NSUUID) }
        return image
    }

    func remove(_ id: UUID) {
        cache.removeObject(forKey: id as NSUUID)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
