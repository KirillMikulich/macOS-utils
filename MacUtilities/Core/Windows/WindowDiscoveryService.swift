import AppKit
import ApplicationServices

struct WindowDiscoveryOptions {
    var includeMinimized = true
    var includeHiddenApps = true
    /// Ограничить поиск конкретными процессами (Превью в Dock запрашивает одно приложение).
    var onlyPIDs: Set<pid_t>?
}

/// Перечисление окон других приложений.
///
/// Источники данных:
/// 1. Accessibility (AXUIElement) — список окон каждого приложения, заголовки, состояние
///    «свёрнуто», возможность поднять окно. Требует разрешения Accessibility.
/// 2. CGWindowListCopyWindowInfo — порядок окон по глубине (используется как
///    «недавно использованные») и CGWindowID для миниатюр. Разрешений не требует.
///
/// Ограничение macOS: публичный AX API возвращает окна только текущего рабочего стола (Space).
/// Окна на других Spaces и в полноэкранных Spaces других приложений, как правило, не видны.
final class WindowDiscoveryService: @unchecked Sendable {
    private struct AppSnapshot {
        let pid: pid_t
        let bundleID: String?
        let name: String
        let isHidden: Bool
    }

    private struct CGWindowEntry {
        let id: CGWindowID
        let pid: pid_t
        let bounds: CGRect
        let order: Int
    }

    private let queue = DispatchQueue(label: "com.otvertka.window-discovery", qos: .userInitiated)
    /// Таймаут на один AX-запрос, чтобы зависшее приложение не блокировало список.
    private let messagingTimeout: Float = 0.25

    /// Собирает окна в фоне и возвращает их отсортированными по глубине (верхние первыми).
    @MainActor
    func discover(_ options: WindowDiscoveryOptions = WindowDiscoveryOptions()) async -> [WindowInfo] {
        // Окна самого Mac Utilities тоже попадают в список (главное окно настроек),
        // а наши плавающие панели отсеиваются фильтром по подроли окна.
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> AppSnapshot? in
            guard app.activationPolicy == .regular, !app.isTerminated else { return nil }
            if let only = options.onlyPIDs, !only.contains(app.processIdentifier) { return nil }
            return AppSnapshot(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                               name: app.localizedName ?? app.bundleIdentifier ?? "App", isHidden: app.isHidden)
        }
        guard AXIsProcessTrusted() else { return [] }

        return await withCheckedContinuation { continuation in
            queue.async {
                let result = self.discoverSync(apps: apps, options: options)
                continuation.resume(returning: result)
            }
        }
    }

    private func discoverSync(apps: [AppSnapshot], options: WindowDiscoveryOptions) -> [WindowInfo] {
        let cgWindows = Self.onScreenWindows()
        let orderByID = Dictionary(cgWindows.map { ($0.id, $0.order) }, uniquingKeysWith: { first, _ in first })

        var results = [[WindowInfo]](repeating: [], count: apps.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: apps.count) { index in
            let windows = self.windows(of: apps[index], cgWindows: cgWindows, orderByID: orderByID, options: options)
            lock.lock()
            results[index] = windows
            lock.unlock()
        }
        return results.flatMap { $0 }.sorted { lhs, rhs in
            lhs.zIndex != rhs.zIndex ? lhs.zIndex < rhs.zIndex : lhs.id < rhs.id
        }
    }

    private func windows(of app: AppSnapshot,
                         cgWindows: [CGWindowEntry],
                         orderByID: [CGWindowID: Int],
                         options: WindowDiscoveryOptions) -> [WindowInfo] {
        if app.isHidden && !options.includeHiddenApps { return [] }

        let appElement = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)

        var result: [WindowInfo] = []
        for (position, window) in AX.elements(appElement, kAXWindowsAttribute).enumerated() {
            guard AX.string(window, kAXRoleAttribute) == kAXWindowRole as String else { continue }
            let subrole = AX.string(window, kAXSubroleAttribute)
            guard subrole == kAXStandardWindowSubrole as String || subrole == kAXDialogSubrole as String else { continue }

            let minimized = AX.bool(window, kAXMinimizedAttribute) ?? false
            if minimized && !options.includeMinimized { continue }

            guard let frame = AX.frame(window), frame.width > 1, frame.height > 1 else { continue }
            let title = AX.string(window, kAXTitleAttribute) ?? ""
            let windowID = AX.windowID(of: window) ?? Self.matchByFrame(pid: app.pid, frame: frame, in: cgWindows)

            // Видимые окна сортируются по реальной глубине, остальные — после них.
            let zIndex: Int
            if let windowID, let order = orderByID[windowID], !minimized, !app.isHidden {
                zIndex = order
            } else if minimized {
                zIndex = 20_000 + position
            } else {
                zIndex = 10_000 + position
            }

            result.append(WindowInfo(windowID: windowID, pid: app.pid, bundleID: app.bundleID, appName: app.name,
                                     title: title, frame: frame, isMinimized: minimized, isAppHidden: app.isHidden,
                                     zIndex: zIndex, element: window))
        }
        return result
    }

    /// Запасной путь, если `_AXUIElementGetWindow` недоступна: окно с тем же PID и той же рамкой.
    private static func matchByFrame(pid: pid_t, frame: CGRect, in windows: [CGWindowEntry]) -> CGWindowID? {
        windows.first { entry in
            entry.pid == pid
                && abs(entry.bounds.minX - frame.minX) < 2 && abs(entry.bounds.minY - frame.minY) < 2
                && abs(entry.bounds.width - frame.width) < 2 && abs(entry.bounds.height - frame.height) < 2
        }?.id
    }

    /// Видимые окна обычного уровня в порядке сверху вниз.
    private static func onScreenWindows() -> [CGWindowEntry] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var entries: [CGWindowEntry] = []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            entries.append(CGWindowEntry(id: id, pid: pid, bounds: bounds, order: entries.count))
        }
        return entries
    }
}
