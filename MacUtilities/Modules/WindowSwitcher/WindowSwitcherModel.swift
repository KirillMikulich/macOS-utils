import Foundation

/// Параметры построения списка окон (общие для Переключение окон и Превью в Dock).
struct WindowListConfiguration {
    var sortOrder: WindowSortOrder = .recentlyUsed
    var groupByApp = false
    var showMinimized = true
    var showHiddenApps = true
    var excludedBundleIDs: Set<String> = []
    /// Дополнительный фильтр (например, «только текущий экран»).
    var filter: ((WindowInfo) -> Bool)?
}

/// Чистая логика: фильтрация, сортировка и группировка окон. Без обращений к системе.
enum WindowListBuilder {
    static func build(_ windows: [WindowInfo], configuration: WindowListConfiguration) -> [WindowInfo] {
        let filtered = windows.filter { window in
            if let bundleID = window.bundleID, configuration.excludedBundleIDs.contains(bundleID) { return false }
            if window.isMinimized && !configuration.showMinimized { return false }
            if window.isAppHidden && !configuration.showHiddenApps { return false }
            if let filter = configuration.filter, !filter(window) { return false }
            return true
        }

        let sorted = filtered.sorted { lhs, rhs in
            switch configuration.sortOrder {
            case .recentlyUsed:
                return order(lhs, rhs)
            case .appName:
                let result = lhs.appName.localizedStandardCompare(rhs.appName)
                return result == .orderedSame ? order(lhs, rhs) : result == .orderedAscending
            case .windowTitle:
                let result = lhs.displayTitle.localizedStandardCompare(rhs.displayTitle)
                return result == .orderedSame ? order(lhs, rhs) : result == .orderedAscending
            }
        }

        guard configuration.groupByApp else { return sorted }

        // Группировка: приложения в порядке первого появления в отсортированном списке,
        // внутри группы — исходный порядок сортировки.
        var groups: [pid_t: [WindowInfo]] = [:]
        var appOrder: [pid_t] = []
        for window in sorted {
            if groups[window.pid] == nil { appOrder.append(window.pid) }
            groups[window.pid, default: []].append(window)
        }
        return appOrder.flatMap { groups[$0] ?? [] }
    }

    private static func order(_ lhs: WindowInfo, _ rhs: WindowInfo) -> Bool {
        lhs.zIndex != rhs.zIndex ? lhs.zIndex < rhs.zIndex : lhs.id < rhs.id
    }
}

enum SwitchDirection {
    case forward, backward
}

/// Состояние одного сеанса переключения (от нажатия ⌥⇥ до подтверждения или отмены).
struct SwitcherSession {
    private(set) var windows: [WindowInfo]
    private(set) var selectedIndex: Int
    private(set) var isFinished = false

    /// Как в Alt+Tab: первое нажатие выбирает следующее окно после текущего (индекс 1),
    /// обратное — последнее окно в списке.
    init(windows: [WindowInfo], direction: SwitchDirection = .forward) {
        self.windows = windows
        switch direction {
        case .forward: selectedIndex = windows.count > 1 ? 1 : 0
        case .backward: selectedIndex = max(windows.count - 1, 0)
        }
    }

    var selectedWindow: WindowInfo? {
        windows.indices.contains(selectedIndex) ? windows[selectedIndex] : nil
    }

    mutating func step(_ direction: SwitchDirection) {
        guard !windows.isEmpty, !isFinished else { return }
        let delta = direction == .forward ? 1 : -1
        selectedIndex = (selectedIndex + delta + windows.count) % windows.count
    }

    /// Перемещение по сетке: по горизонтали ±1, по вертикали ±columns (без зацикливания по вертикали).
    mutating func move(rows: Int, columns: Int) {
        guard !windows.isEmpty, !isFinished, columns > 0 else { return }
        let target = selectedIndex + rows * columns
        if windows.indices.contains(target) { selectedIndex = target }
    }

    mutating func select(id: String) {
        guard !isFinished, let index = windows.firstIndex(where: { $0.id == id }) else { return }
        selectedIndex = index
    }

    /// Список окон обновился (например, окно закрылось) — сохраняем выбранное окно, если оно осталось.
    mutating func update(windows newWindows: [WindowInfo]) {
        let selectedID = selectedWindow?.id
        windows = newWindows
        if let selectedID, let index = newWindows.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = index
        } else {
            selectedIndex = min(selectedIndex, max(newWindows.count - 1, 0))
        }
    }

    /// Подтверждение: возвращает окно для активации. Повторный вызов возвращает nil.
    mutating func confirm() -> WindowInfo? {
        guard !isFinished else { return nil }
        isFinished = true
        return selectedWindow
    }

    /// Отмена: окно не меняется, фокус остаётся там, где был.
    mutating func cancel() {
        isFinished = true
    }
}
