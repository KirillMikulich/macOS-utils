import Cocoa
import FinderSync

/// Расширение Finder: добавляет пункты Mac Utilities в контекстное меню файлов, папок
/// и пустого места окна. Само ничего не выполняет (оно в песочнице) — передаёт запрос
/// приложению Mac Utilities, которое открывает файлы, копирует пути и создаёт файлы.
final class FinderMenuExtension: FIFinderSync {
    private var config = FinderMenuConfig()
    private var lastMenuKind: FIMenuKind = .contextualMenuForItems

    override init() {
        super.init()
        // Меню нужно везде: на всех дисках и в любой папке.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        // Файл крошечный; читаем при каждом открытии меню, чтобы изменения в настройках
        // применялись сразу, без перезапуска Finder.
        config = FinderMenuConfig.load()
        guard config.enabled else { return nil }
        lastMenuKind = menuKind

        let fits: (FinderMenuItem) -> Bool
        switch menuKind {
        case .contextualMenuForItems:
            let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
            let hasFolders = urls.contains(where: \.hasDirectoryPath)
            let hasFiles = urls.contains { !$0.hasDirectoryPath }
            fits = { (hasFiles && $0.forFiles) || (hasFolders && $0.forFolders) }
        case .contextualMenuForContainer:
            fits = \.forBackground
        default:
            return nil
        }

        let menu = NSMenu(title: "")
        for (index, item) in config.items.enumerated() where fits(item) {
            let menuItem = NSMenuItem(title: item.title, action: #selector(runItem(_:)), keyEquivalent: "")
            // Finder копирует пункты меню и сохраняет только заголовок, действие, картинку и tag.
            menuItem.tag = index
            menuItem.image = icon(for: item)
            menu.addItem(menuItem)
        }
        return menu.items.isEmpty ? nil : menu
    }

    @objc private func runItem(_ sender: NSMenuItem) {
        guard config.items.indices.contains(sender.tag) else { return }
        let controller = FIFinderSyncController.default()
        var urls: [URL] = []
        if lastMenuKind == .contextualMenuForItems {
            urls = controller.selectedItemURLs() ?? []
        }
        if urls.isEmpty, let folder = controller.targetedURL() {
            urls = [folder]
        }
        guard !urls.isEmpty else { return }
        let request = FinderMenuRequest(itemID: config.items[sender.tag].id, paths: urls.map(\.path))
        guard let data = try? JSONEncoder().encode(request), let json = String(data: data, encoding: .utf8) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            FinderMenuRequest.notification, object: json, userInfo: nil, deliverImmediately: true)
    }

    private func icon(for item: FinderMenuItem) -> NSImage? {
        let image: NSImage?
        switch item.action {
        case .openWithApp:
            image = item.appPath.map { NSWorkspace.shared.icon(forFile: $0) }
        case .copyPath:
            image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        case .newFile:
            image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
        }
        image?.size = NSSize(width: 16, height: 16)
        return image
    }
}
