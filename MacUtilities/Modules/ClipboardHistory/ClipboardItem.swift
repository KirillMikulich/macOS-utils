import Foundation

/// Тип содержимого элемента истории. Определяет значок, предпросмотр и порядок поиска.
enum ClipboardKind: String, Codable, CaseIterable {
    case text
    case richText
    case link
    case image
    case files
    case other

    var title: String {
        switch self {
        case .text: return L("Текст")
        case .richText: return L("Форматированный текст")
        case .link: return L("Ссылка")
        case .image: return L("Изображение")
        case .files: return L("Файлы")
        case .other: return L("Другое")
        }
    }

    var systemImage: String {
        switch self {
        case .text: return "text.alignleft"
        case .richText: return "textformat"
        case .link: return "link"
        case .image: return "photo"
        case .files: return "doc.on.doc"
        case .other: return "shippingbox"
        }
    }
}

/// Одно представление (тип UTI + данные) одного объекта буфера обмена.
struct ClipboardRepresentation: Equatable {
    let type: String
    let data: Data
}

/// Один NSPasteboardItem со всеми его представлениями (например, HTML + RTF + обычный текст).
struct CapturedPasteboardItem: Equatable {
    var representations: [ClipboardRepresentation]

    func data(for type: String) -> Data? {
        representations.first { $0.type == type }?.data
    }

    var types: [String] { representations.map(\.type) }
}

/// Прочитанное содержимое буфера (ещё не сохранённое в истории).
struct CapturedClipboardContent: Equatable {
    var items: [CapturedPasteboardItem]
    var kind: ClipboardKind
    var previewText: String
    var imagePixelSize: CGSize?
    var contentHash: String

    var totalBytes: Int {
        items.reduce(0) { $0 + $1.representations.reduce(0) { $0 + $1.data.count } }
    }
}

// MARK: - Сохраняемая модель (индекс истории)

struct StoredRepresentation: Codable, Equatable {
    var type: String
    /// Имя файла с данными внутри каталога элемента.
    var fileName: String
    var byteCount: Int
}

struct StoredPasteboardItem: Codable, Equatable {
    var representations: [StoredRepresentation]
}

/// Запись истории. Сами данные хранятся отдельно (файлы или память), здесь только метаданные.
struct ClipboardItem: Codable, Identifiable, Equatable {
    var id: UUID
    var createdAt: Date
    /// Время последнего копирования (в том числе повторного выбора из истории). Ключ сортировки.
    var lastUsedAt: Date
    var kind: ClipboardKind
    var previewText: String
    var imageWidth: Double?
    var imageHeight: Double?
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var isPinned: Bool
    var contentHash: String
    var pasteboardItems: [StoredPasteboardItem]
    var totalBytes: Int

    var allTypes: [String] {
        pasteboardItems.flatMap { $0.representations.map(\.type) }
    }

    var imageSizeDescription: String? {
        guard let w = imageWidth, let h = imageHeight else { return nil }
        return "\(Int(w))×\(Int(h))"
    }
}
