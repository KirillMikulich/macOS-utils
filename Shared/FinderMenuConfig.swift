import Foundation

// Общий код приложения и расширения Finder (FinderMenuExtension): формат пунктов меню,
// файл, через который приложение передаёт их расширению, и запрос на выполнение пункта.

/// Пункт контекстного меню Finder.
struct FinderMenuItem: Codable, Equatable, Identifiable {
    enum Action: String, Codable {
        /// Открыть выбранное в приложении `appPath` (VS Code, Терминал…).
        case openWithApp
        /// Скопировать пути выбранных файлов.
        case copyPath
        /// Создать пустой текстовый файл в папке.
        case newFile
    }

    var id = UUID()
    var title: String
    var action: Action
    var appPath: String?
    /// Где показывать пункт: на файлах, на папках, на пустом месте окна Finder.
    var forFiles = true
    var forFolders = true
    var forBackground = true
}

/// То, что видит расширение: включён ли модуль и какие пункты показывать.
struct FinderMenuConfig: Codable, Equatable {
    var enabled = false
    var items: [FinderMenuItem] = []

    /// ~/Library/Application Support/Mac Utilities/FinderMenu.json. Путь строится от настоящей
    /// домашней папки: у расширения в песочнице NSHomeDirectory() указывает на его контейнер.
    static var fileURL: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingUTF8: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Mac Utilities/FinderMenu.json")
    }

    static func load() -> FinderMenuConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(FinderMenuConfig.self, from: data) else { return FinderMenuConfig() }
        return config
    }
}

/// Запрос расширения к приложению: выполнить пункт для этих путей.
/// Передаётся распределённым уведомлением в `object` (JSON): из песочницы userInfo не доставляется.
struct FinderMenuRequest: Codable {
    var itemID: UUID
    var paths: [String]

    static let notification = Notification.Name("com.otvertka.MacUtilities.FinderMenu.perform")
}
