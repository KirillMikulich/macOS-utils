import Foundation

/// Где лежат данные истории. Две реализации: файлы на диске и только память
/// (режим «не сохранять историю между запусками»).
protocol ClipboardStorage: AnyObject {
    var isPersistent: Bool { get }
    func loadIndex() -> [ClipboardItem]
    func saveIndex(_ items: [ClipboardItem])
    func writeBlob(_ data: Data, itemID: UUID, name: String)
    func readBlob(itemID: UUID, name: String) -> Data?
    func deleteItem(_ itemID: UUID)
    func deleteAll()
    /// Дождаться завершения отложенных операций записи.
    func flush()
}

/// Хранение на диске:
/// ```
/// ClipboardHistory/
///   index.json            — метаданные всех элементов
///   items/<uuid>/0-1.bin  — данные представлений (объект 0, представление 1)
/// ```
/// Запись выполняется на фоновой последовательной очереди, чтобы не блокировать интерфейс.
final class FileClipboardStorage: ClipboardStorage {
    private struct IndexFile: Codable {
        var version: Int
        var items: [ClipboardItem]
    }

    let root: URL
    private let queue = DispatchQueue(label: "com.otvertka.clipboard-storage", qos: .utility)
    private let fileManager = FileManager.default
    var isPersistent: Bool { true }

    init(root: URL = AppPaths.clipboardDirectory) {
        self.root = root
        AppPaths.ensureDirectory(itemsDirectory)
    }

    private var indexURL: URL { root.appendingPathComponent("index.json") }
    private var itemsDirectory: URL { root.appendingPathComponent("items", isDirectory: true) }
    private func directory(for id: UUID) -> URL { itemsDirectory.appendingPathComponent(id.uuidString, isDirectory: true) }

    func loadIndex() -> [ClipboardItem] {
        queue.sync {
            guard let data = try? Data(contentsOf: indexURL) else { return [] }
            do {
                let index = try JSONDecoder().decode(IndexFile.self, from: data)
                removeOrphans(keeping: Set(index.items.map(\.id)))
                return index.items
            } catch {
                Log.clipboard.error("Clipboard index is corrupted, starting with empty history: \(error.localizedDescription, privacy: .public)")
                let backup = root.appendingPathComponent("index.corrupt-\(Int(Date().timeIntervalSince1970)).json")
                try? fileManager.moveItem(at: indexURL, to: backup)
                removeOrphans(keeping: [])
                return []
            }
        }
    }

    func saveIndex(_ items: [ClipboardItem]) {
        queue.async { [indexURL] in
            do {
                let data = try JSONEncoder().encode(IndexFile(version: 1, items: items))
                try data.write(to: indexURL, options: .atomic)
            } catch {
                Log.clipboard.error("Failed to save clipboard index: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func writeBlob(_ data: Data, itemID: UUID, name: String) {
        let directory = directory(for: itemID)
        queue.async { [fileManager] in
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            } catch {
                Log.clipboard.error("Failed to write clipboard blob: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func readBlob(itemID: UUID, name: String) -> Data? {
        let url = directory(for: itemID).appendingPathComponent(name)
        return queue.sync { try? Data(contentsOf: url, options: .mappedIfSafe) }
    }

    func deleteItem(_ itemID: UUID) {
        let directory = directory(for: itemID)
        queue.async { [fileManager] in try? fileManager.removeItem(at: directory) }
    }

    func deleteAll() {
        queue.async { [fileManager, root, itemsDirectory] in
            try? fileManager.removeItem(at: root)
            try? fileManager.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
        }
    }

    func flush() {
        queue.sync {}
    }

    /// Удаляет каталоги элементов, которых нет в индексе (например, после сбоя).
    private func removeOrphans(keeping ids: Set<UUID>) {
        guard let contents = try? fileManager.contentsOfDirectory(at: itemsDirectory, includingPropertiesForKeys: nil) else { return }
        for url in contents {
            if let id = UUID(uuidString: url.lastPathComponent), ids.contains(id) { continue }
            try? fileManager.removeItem(at: url)
        }
    }
}

/// Хранение только в памяти: при выходе история исчезает.
final class MemoryClipboardStorage: ClipboardStorage {
    private var blobs: [UUID: [String: Data]] = [:]
    var isPersistent: Bool { false }

    func loadIndex() -> [ClipboardItem] { [] }
    func saveIndex(_ items: [ClipboardItem]) {}
    func writeBlob(_ data: Data, itemID: UUID, name: String) { blobs[itemID, default: [:]][name] = data }
    func readBlob(itemID: UUID, name: String) -> Data? { blobs[itemID]?[name] }
    func deleteItem(_ itemID: UUID) { blobs[itemID] = nil }
    func deleteAll() { blobs.removeAll() }
    func flush() {}
}
