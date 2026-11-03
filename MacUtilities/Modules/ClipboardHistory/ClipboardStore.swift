import Foundation
import Observation

/// История буфера обмена.
///
/// Правила:
/// - Элементы упорядочены по времени последнего использования (новые сверху).
/// - Дубликат (тот же `contentHash`) не создаёт новую запись: существующая поднимается наверх,
///   её время обновляется, а данные заменяются свежими представлениями.
/// - Лимит распространяется только на незакреплённые элементы. При превышении удаляются
///   самые старые незакреплённые. Закреплённые элементы удаляются только вручную.
/// - Если задан срок хранения, незакреплённые элементы старше него удаляются.
@MainActor
@Observable
final class ClipboardStore {
    private(set) var items: [ClipboardItem] = []

    @ObservationIgnored private(set) var storage: ClipboardStorage
    @ObservationIgnored var historyLimit: Int {
        didSet { if historyLimit != oldValue { enforceLimits() } }
    }
    @ObservationIgnored var retentionDays: Int {
        didSet { if retentionDays != oldValue { enforceLimits() } }
    }
    @ObservationIgnored var now: () -> Date = Date.init

    init(storage: ClipboardStorage, historyLimit: Int = 20, retentionDays: Int = 0) {
        self.storage = storage
        self.historyLimit = historyLimit
        self.retentionDays = retentionDays
        self.items = storage.loadIndex().sorted { $0.lastUsedAt > $1.lastUsedAt }
        enforceLimits()
    }

    var pinnedItems: [ClipboardItem] { items.filter(\.isPinned) }
    var unpinnedItems: [ClipboardItem] { items.filter { !$0.isPinned } }

    func item(_ id: UUID) -> ClipboardItem? {
        items.first { $0.id == id }
    }

    // MARK: - Добавление

    @discardableResult
    func add(_ content: CapturedClipboardContent, sourceBundleID: String? = nil, sourceAppName: String? = nil) -> ClipboardItem {
        let date = now()

        if let index = items.firstIndex(where: { $0.contentHash == content.contentHash }) {
            var existing = items.remove(at: index)
            storage.deleteItem(existing.id)
            existing.pasteboardItems = writeBlobs(content, itemID: existing.id)
            existing.lastUsedAt = date
            existing.totalBytes = content.totalBytes
            existing.sourceAppBundleID = sourceBundleID ?? existing.sourceAppBundleID
            existing.sourceAppName = sourceAppName ?? existing.sourceAppName
            items.insert(existing, at: 0)
            persistIndex()
            return existing
        }

        let id = UUID()
        let item = ClipboardItem(id: id,
                                 createdAt: date,
                                 lastUsedAt: date,
                                 kind: content.kind,
                                 previewText: content.previewText,
                                 imageWidth: content.imagePixelSize.map { Double($0.width) },
                                 imageHeight: content.imagePixelSize.map { Double($0.height) },
                                 sourceAppBundleID: sourceBundleID,
                                 sourceAppName: sourceAppName,
                                 isPinned: false,
                                 contentHash: content.contentHash,
                                 pasteboardItems: writeBlobs(content, itemID: id),
                                 totalBytes: content.totalBytes)
        items.insert(item, at: 0)
        enforceLimits(save: false)
        persistIndex()
        return item
    }

    private func writeBlobs(_ content: CapturedClipboardContent, itemID: UUID) -> [StoredPasteboardItem] {
        content.items.enumerated().map { itemIndex, item in
            StoredPasteboardItem(representations: item.representations.enumerated().map { repIndex, rep in
                let name = "\(itemIndex)-\(repIndex).bin"
                storage.writeBlob(rep.data, itemID: itemID, name: name)
                return StoredRepresentation(type: rep.type, fileName: name, byteCount: rep.data.count)
            })
        }
    }

    // MARK: - Чтение данных

    /// Загружает все представления элемента. nil — если данные потеряны.
    func content(for item: ClipboardItem) -> [CapturedPasteboardItem]? {
        var result: [CapturedPasteboardItem] = []
        for stored in item.pasteboardItems {
            var reps: [ClipboardRepresentation] = []
            for rep in stored.representations {
                guard let data = storage.readBlob(itemID: item.id, name: rep.fileName) else { continue }
                reps.append(ClipboardRepresentation(type: rep.type, data: data))
            }
            if !reps.isEmpty { result.append(CapturedPasteboardItem(representations: reps)) }
        }
        return result.isEmpty ? nil : result
    }

    /// Данные лучшего представления-изображения (для миниатюры).
    func imageData(for item: ClipboardItem) -> Data? {
        guard let first = item.pasteboardItems.first else { return nil }
        let reps = first.representations
        let chosen = ClipboardContentReader.preferredImageTypes.lazy.compactMap { type in reps.first { $0.type == type } }.first
            ?? reps.first { ClipboardContentReader.isImageType($0.type) }
        guard let chosen else { return nil }
        return storage.readBlob(itemID: item.id, name: chosen.fileName)
    }

    // MARK: - Изменение

    /// Элемент повторно выбран пользователем — поднимаем наверх.
    func touch(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.lastUsedAt = now()
        items.insert(item, at: 0)
        persistIndex()
    }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPinned = pinned
        enforceLimits(save: false)
        persistIndex()
    }

    func togglePin(_ id: UUID) {
        guard let item = item(id) else { return }
        setPinned(id, !item.isPinned)
    }

    func delete(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        storage.deleteItem(id)
        persistIndex()
    }

    /// Очистка истории. По умолчанию закреплённые элементы остаются.
    func clear(includingPinned: Bool = false) {
        let removed = includingPinned ? items : unpinnedItems
        items = includingPinned ? [] : pinnedItems
        if includingPinned {
            storage.deleteAll()
        } else {
            removed.forEach { storage.deleteItem($0.id) }
        }
        persistIndex()
    }

    // MARK: - Поиск

    func search(_ query: String) -> [ClipboardItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter { item in
            item.previewText.localizedStandardContains(trimmed)
                || (item.sourceAppName?.localizedStandardContains(trimmed) ?? false)
                || item.kind.title.localizedStandardContains(trimmed)
        }
    }

    // MARK: - Лимиты

    func enforceLimits(save: Bool = true) {
        var removedIDs: [UUID] = []

        if retentionDays > 0 {
            let cutoff = now().addingTimeInterval(-Double(retentionDays) * 86_400)
            for item in items where !item.isPinned && item.lastUsedAt < cutoff { removedIDs.append(item.id) }
        }

        let limit = max(0, historyLimit)
        let unpinned = items.filter { !$0.isPinned && !removedIDs.contains($0.id) }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
        if unpinned.count > limit {
            removedIDs.append(contentsOf: unpinned[limit...].map(\.id))
        }

        guard !removedIDs.isEmpty else { return }
        let removedSet = Set(removedIDs)
        items.removeAll { removedSet.contains($0.id) }
        removedSet.forEach { storage.deleteItem($0) }
        if save { persistIndex() }
    }

    // MARK: - Хранилище

    /// Переключение «хранить на диске / только в памяти» с переносом текущих данных.
    func switchStorage(to newStorage: ClipboardStorage) {
        let old = storage
        var migrated: [ClipboardItem] = []
        for item in items {
            guard let content = content(for: item) else { continue }
            for (itemIndex, pasteboardItem) in item.pasteboardItems.enumerated() where itemIndex < content.count {
                for (repIndex, rep) in pasteboardItem.representations.enumerated() where repIndex < content[itemIndex].representations.count {
                    newStorage.writeBlob(content[itemIndex].representations[repIndex].data, itemID: item.id, name: rep.fileName)
                }
            }
            migrated.append(item)
        }
        storage = newStorage
        items = migrated
        newStorage.saveIndex(items)
        old.deleteAll()
        old.saveIndex([])
    }

    private func persistIndex() {
        storage.saveIndex(items)
    }

    func flush() {
        storage.flush()
    }
}
