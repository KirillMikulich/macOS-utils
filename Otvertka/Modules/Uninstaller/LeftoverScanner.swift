import AppKit
import Security

/// Сведения об удаляемом приложении.
struct AppBundleInfo: Equatable {
    let url: URL
    let name: String
    let bundleID: String
    let version: String?
    /// Команда разработчика из подписи — по ней находятся общие Group Containers.
    let teamID: String?

    init?(url: URL) {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return nil }
        self.url = url
        self.bundleID = bundleID
        self.name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        self.version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        self.teamID = Self.teamIdentifier(of: url)
    }

    init(url: URL, name: String, bundleID: String, version: String? = nil, teamID: String? = nil) {
        self.url = url
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.teamID = teamID
    }

    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }

    /// Системные приложения Apple защищены macOS (SIP) и удалению не подлежат.
    var isProtected: Bool {
        bundleID.hasPrefix("com.apple.") || url.path.hasPrefix("/System/") || bundleID == Bundle.main.bundleIdentifier
    }

    private static func teamIdentifier(of url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

enum LeftoverMatch: String {
    case bundleID      // имя совпадает с идентификатором приложения — надёжно
    case name          // папка названа как приложение — вероятно, но не наверняка
    case team          // общий контейнер команды разработчика — может использоваться другими её приложениями

    var title: String {
        switch self {
        case .bundleID: return "по идентификатору"
        case .name: return "по названию"
        case .team: return "общая папка разработчика"
        }
    }
}

/// Найденный «хвост» приложения.
struct LeftoverItem: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let category: String
    let match: LeftoverMatch
    /// Лежит в /Library — для удаления может понадобиться пароль администратора.
    let isSystemWide: Bool
    var size: Int64?
    var isSelected: Bool
}

/// Поиск файлов, которые приложение оставляет вне своего .app.
///
/// Проверяются стандартные места в ~/Library и /Library. Совпадения по идентификатору
/// отмечаются сразу; совпадения по названию и общие контейнеры разработчика — нет,
/// их пользователь включает сам.
struct LeftoverScanner {
    var homeLibrary: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
    var systemLibrary = URL(fileURLWithPath: "/Library")

    private struct Location {
        let path: String
        let category: String
        let matchByName: Bool
    }

    private static let userLocations: [Location] = [
        Location(path: "Application Support", category: "Данные приложения", matchByName: true),
        Location(path: "Caches", category: "Кэш", matchByName: true),
        Location(path: "Preferences", category: "Настройки", matchByName: false),
        Location(path: "Preferences/ByHost", category: "Настройки", matchByName: false),
        Location(path: "Containers", category: "Контейнер (песочница)", matchByName: false),
        Location(path: "Group Containers", category: "Общий контейнер", matchByName: false),
        Location(path: "Saved Application State", category: "Состояние окон", matchByName: false),
        Location(path: "Logs", category: "Журналы", matchByName: true),
        Location(path: "HTTPStorages", category: "Сетевые данные", matchByName: false),
        Location(path: "WebKit", category: "Веб-данные", matchByName: false),
        Location(path: "Cookies", category: "Cookies", matchByName: false),
        Location(path: "LaunchAgents", category: "Автозапуск", matchByName: false),
        Location(path: "Application Scripts", category: "Скрипты", matchByName: false),
    ]

    private static let systemLocations: [Location] = [
        Location(path: "Application Support", category: "Данные (для всех пользователей)", matchByName: true),
        Location(path: "Caches", category: "Кэш (для всех пользователей)", matchByName: false),
        Location(path: "Preferences", category: "Настройки (для всех пользователей)", matchByName: false),
        Location(path: "LaunchAgents", category: "Автозапуск (для всех пользователей)", matchByName: false),
        Location(path: "LaunchDaemons", category: "Системная служба", matchByName: false),
        Location(path: "PrivilegedHelperTools", category: "Вспомогательный инструмент", matchByName: false),
        Location(path: "Logs", category: "Журналы (для всех пользователей)", matchByName: true),
    ]

    func scan(_ app: AppBundleInfo) -> [LeftoverItem] {
        var items: [LeftoverItem] = []
        var seen = Set<String>()
        func collect(_ locations: [Location], root: URL, systemWide: Bool) {
            for location in locations {
                let directory = root.appendingPathComponent(location.path, isDirectory: true)
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
                for name in names {
                    guard let match = Self.match(name: name, app: app, byName: location.matchByName) else { continue }
                    let url = directory.appendingPathComponent(name)
                    guard seen.insert(url.path).inserted else { continue }
                    items.append(LeftoverItem(url: url, category: location.category, match: match,
                                              isSystemWide: systemWide, size: nil, isSelected: match == .bundleID))
                }
            }
        }
        collect(Self.userLocations, root: homeLibrary, systemWide: false)
        collect(Self.systemLocations, root: systemLibrary, systemWide: true)
        return items.sorted { lhs, rhs in
            lhs.isSystemWide != rhs.isSystemWide ? !lhs.isSystemWide : lhs.url.path < rhs.url.path
        }
    }

    /// Правила совпадения имени файла/папки с приложением.
    static func match(name: String, app: AppBundleInfo, byName: Bool) -> LeftoverMatch? {
        let lower = name.lowercased()
        let bundleID = app.bundleID.lowercased()
        // com.example.app, com.example.app.plist, com.example.app.savedState, com.example.app.helper…
        if lower == bundleID || lower.hasPrefix(bundleID + ".") {
            return .bundleID
        }
        // Group Containers: TEAMID.com.example.app или group.com.example.app.
        if lower.hasSuffix("." + bundleID) || lower.contains("." + bundleID + ".") {
            return .bundleID
        }
        if let team = app.teamID?.lowercased(), lower.hasPrefix(team + ".") {
            return .team
        }
        if byName {
            let appName = app.name.lowercased()
            // Слишком короткие названия («Notes», «Mail») дают ложные совпадения — только точное совпадение.
            if lower == appName && appName.count >= 3 {
                return .name
            }
        }
        return nil
    }

    /// Размер файла или папки (для папок — сумма содержимого).
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let file = enumerator?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
