import Foundation
import OSLog

/// Единая точка логирования. Используется системный unified logging (os.Logger),
/// поэтому логи можно смотреть в Console.app с фильтром `subsystem:com.otvertka.Otvertka`.
enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.otvertka.Otvertka"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let modules = Logger(subsystem: subsystem, category: "modules")
    static let shortcuts = Logger(subsystem: subsystem, category: "shortcuts")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
    static let windows = Logger(subsystem: subsystem, category: "windows")
    static let dock = Logger(subsystem: subsystem, category: "dock")
}
