import Foundation

/// Типизированные настройки одного модуля (или общие настройки приложения).
///
/// Каждый тип хранится в отдельном JSON-файле `<storageKey>.json` в формате
/// `{ "schemaVersion": N, "settings": { ... } }`.
///
/// Совместимость при добавлении новых полей обеспечивается без ручных `init(from:)`:
/// при загрузке сохранённый словарь накладывается поверх словаря значений по умолчанию,
/// поэтому отсутствующие ключи получают значения из `defaultValue`.
protocol PersistedSettings: Codable, Equatable {
    static var storageKey: String { get }
    /// Текущая версия схемы. Увеличивается, когда нужно преобразовать старые данные.
    static var schemaVersion: Int { get }
    static var defaultValue: Self { get }
    /// Миграции: ключ — исходная версия, функция переводит словарь в версию key + 1.
    static var migrations: [Int: (inout [String: Any]) -> Void] { get }
}

extension PersistedSettings {
    static var schemaVersion: Int { 1 }
    static var migrations: [Int: (inout [String: Any]) -> Void] { [:] }
}

/// Результат загрузки — используется в логах и тестах.
enum SettingsLoadOutcome: Equatable {
    case defaults          // файла не было
    case loaded            // загружено без изменений
    case migrated(from: Int)
    case recoveredFromCorruption
    case partiallyRecovered(droppedKeys: [String])
}

final class SettingsStore {
    let directory: URL
    private let fileManager = FileManager.default
    private(set) var lastOutcome: [String: SettingsLoadOutcome] = [:]

    init(directory: URL = AppPaths.settingsDirectory) {
        self.directory = directory
        AppPaths.ensureDirectory(directory)
    }

    func fileURL<T: PersistedSettings>(for type: T.Type) -> URL {
        directory.appendingPathComponent("\(T.storageKey).json")
    }

    // MARK: - Load

    func load<T: PersistedSettings>(_ type: T.Type) -> T {
        let url = fileURL(for: type)
        guard fileManager.fileExists(atPath: url.path) else {
            lastOutcome[T.storageKey] = .defaults
            return T.defaultValue
        }

        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            Log.settings.error("Settings file \(T.storageKey, privacy: .public) is unreadable, using defaults")
            backupCorruptedFile(url)
            lastOutcome[T.storageKey] = .recoveredFromCorruption
            return T.defaultValue
        }

        let storedVersion = root["schemaVersion"] as? Int ?? 0
        var stored = root["settings"] as? [String: Any] ?? [:]

        // Последовательно применяем миграции от сохранённой версии до текущей.
        var migrated = false
        if storedVersion < T.schemaVersion {
            for version in storedVersion..<T.schemaVersion {
                if let migration = T.migrations[version] {
                    migration(&stored)
                }
            }
            migrated = true
        }

        let (value, dropped) = decodeMerged(T.self, stored: stored)

        if !dropped.isEmpty {
            Log.settings.error("Settings \(T.storageKey, privacy: .public): dropped invalid keys \(dropped, privacy: .public)")
            backupCorruptedFile(url)
            lastOutcome[T.storageKey] = .partiallyRecovered(droppedKeys: dropped)
            save(value)
        } else if migrated {
            Log.settings.info("Settings \(T.storageKey, privacy: .public) migrated from v\(storedVersion) to v\(T.schemaVersion)")
            lastOutcome[T.storageKey] = .migrated(from: storedVersion)
            save(value)
        } else {
            lastOutcome[T.storageKey] = .loaded
        }
        return value
    }

    /// Накладывает сохранённые значения на значения по умолчанию.
    /// Если целиком декодировать не удаётся (например, тип поля изменился),
    /// ключи применяются по одному, а некорректные отбрасываются.
    private func decodeMerged<T: PersistedSettings>(_ type: T.Type, stored: [String: Any]) -> (T, [String]) {
        guard let defaults = Self.dictionary(from: T.defaultValue) else { return (T.defaultValue, []) }

        let fullyMerged = Self.deepMerge(defaults, stored)
        if let value: T = Self.decode(fullyMerged) {
            return (value, [])
        }

        var current = defaults
        var dropped: [String] = []
        for key in stored.keys.sorted() {
            var candidate = current
            candidate[key] = Self.deepMergeValue(current[key], stored[key] as Any)
            if Self.decode(candidate) as T? != nil {
                current = candidate
            } else {
                dropped.append(key)
            }
        }
        return (Self.decode(current) ?? T.defaultValue, dropped)
    }

    // MARK: - Save

    func save<T: PersistedSettings>(_ value: T) {
        do {
            let settingsData = try JSONEncoder().encode(value)
            let settingsObject = try JSONSerialization.jsonObject(with: settingsData)
            let root: [String: Any] = ["schemaVersion": T.schemaVersion, "settings": settingsObject]
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL(for: T.self), options: .atomic)
        } catch {
            Log.settings.error("Failed to save \(T.storageKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func reset<T: PersistedSettings>(_ type: T.Type) {
        try? fileManager.removeItem(at: fileURL(for: type))
    }

    // MARK: - Helpers

    private func backupCorruptedFile(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = url.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
        try? fileManager.copyItem(at: url, to: backup)
    }

    static func dictionary<T: Encodable>(from value: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func decode<T: Decodable>(_ dictionary: [String: Any]) -> T? {
        guard JSONSerialization.isValidJSONObject(dictionary),
              let data = try? JSONSerialization.data(withJSONObject: dictionary) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func deepMerge(_ base: [String: Any], _ override: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in override {
            result[key] = deepMergeValue(base[key], value)
        }
        return result
    }

    private static func deepMergeValue(_ base: Any?, _ override: Any) -> Any {
        if let baseDict = base as? [String: Any], let overrideDict = override as? [String: Any] {
            return deepMerge(baseDict, overrideDict)
        }
        return override
    }
}
