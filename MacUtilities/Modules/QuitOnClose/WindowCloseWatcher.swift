import AppKit
import ApplicationServices

/// Следит за закрытием окон обычных приложений и сообщает, когда у приложения
/// закрылось последнее окно.
///
/// Механизм: для каждого приложения — AXObserver с уведомлениями
/// `kAXWindowCreatedNotification` (на приложении) и `kAXUIElementDestroyedNotification`
/// (на каждом окне). После закрытия окна, с небольшой задержкой, проверяется, остались ли окна.
///
/// «Окон не осталось» считается, только если:
/// 1. у приложения нет стандартных окон по Accessibility (в том числе свёрнутых);
/// 2. и ни одно из ранее замеченных стандартных окон приложения не существует в CGWindowList
///    с учётом ВСЕХ рабочих столов — Accessibility видит только текущий Space, и без этой
///    проверки закрылось бы приложение, у которого окно открыто на соседнем рабочем столе.
///    Сравниваются только «настоящие» окна, которые были стандартными по AX: многие
///    приложения (например, TextEdit) держат скрытые служебные окна, их учитывать нельзя.
@MainActor
final class WindowCloseWatcher {
    var onLastWindowClosed: ((NSRunningApplication) -> Void)?

    private final class Entry {
        let app: NSRunningApplication
        let element: AXUIElement
        var observer: AXObserver?
        /// Были ли у приложения окна с момента начала наблюдения (иначе это фоновое приложение).
        var hadWindows = false
        /// CGWindowID стандартных окон, которые приложение показывало (на любом рабочем столе).
        var knownWindowIDs: Set<CGWindowID> = []
        var handler: ((String, AXUIElement) -> Void)?

        init(app: NSRunningApplication) {
            self.app = app
            self.element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.3)
        }
    }

    private var entries: [pid_t: Entry] = [:]
    private var tokens: [NSObjectProtocol] = []
    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            attach(app)
        }
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // Приложение ещё строит дерево AX — подключаемся чуть позже.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated {
                    guard let self, self.isRunning, app.activationPolicy == .regular, !app.isTerminated else { return }
                    self.attach(app)
                }
            }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.detach(app.processIdentifier) }
        })
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        tokens.removeAll()
        for pid in Array(entries.keys) { detach(pid) }
    }

    // MARK: - Подключение к приложению

    private func attach(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard entries[pid] == nil, pid != ProcessInfo.processInfo.processIdentifier else { return }
        let entry = Entry(app: app)

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let entry = Unmanaged<Entry>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { entry.handler?(name, element) }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        entry.observer = observer
        entry.handler = { [weak self, weak entry] name, element in
            guard let self, let entry else { return }
            self.handle(name, element: element, entry: entry)
        }

        let refcon = Unmanaged.passUnretained(entry).toOpaque()
        AXObserverAddNotification(observer, entry.element, kAXWindowCreatedNotification as CFString, refcon)
        let windows = AX.elements(entry.element, kAXWindowsAttribute)
        for window in windows {
            AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, refcon)
        }
        let standard = windows.filter(Self.isStandardWindow)
        entry.hadWindows = !standard.isEmpty
        entry.knownWindowIDs = Set(standard.compactMap(AX.windowID(of:)))
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        entries[pid] = entry
    }

    private func detach(_ pid: pid_t) {
        guard let entry = entries.removeValue(forKey: pid), let observer = entry.observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        entry.handler = nil
    }

    private func handle(_ notification: String, element: AXUIElement, entry: Entry) {
        switch notification {
        case kAXWindowCreatedNotification:
            if let observer = entry.observer {
                AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString,
                                          Unmanaged.passUnretained(entry).toOpaque())
            }
            if Self.isStandardWindow(element) {
                entry.hadWindows = true
                if let id = AX.windowID(of: element) { entry.knownWindowIDs.insert(id) }
            }
        case kAXUIElementDestroyedNotification:
            // Небольшая пауза: приложение может закрыть одно окно и тут же открыть другое.
            let pid = entry.app.processIdentifier
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                MainActor.assumeIsolated { self?.checkWindows(pid) }
            }
        default:
            break
        }
    }

    private func checkWindows(_ pid: pid_t) {
        guard isRunning, let entry = entries[pid], entry.hadWindows, !entry.app.isTerminated else { return }
        let axWindows = AX.elements(entry.element, kAXWindowsAttribute).filter(Self.isStandardWindow)
        guard axWindows.isEmpty else { return }
        let alive = Self.existingWindowIDs(pid: pid)
        entry.knownWindowIDs.formIntersection(alive)
        // Известные окна ещё существуют — значит, они на другом рабочем столе.
        guard entry.knownWindowIDs.isEmpty else { return }
        entry.hadWindows = false
        onLastWindowClosed?(entry.app)
    }

    nonisolated static func isStandardWindow(_ element: AXUIElement) -> Bool {
        AX.string(element, kAXRoleAttribute) == kAXWindowRole as String
            && AX.string(element, kAXSubroleAttribute) == kAXStandardWindowSubrole as String
    }

    /// Идентификаторы всех окон приложения на всех рабочих столах (включая свёрнутые и скрытые).
    nonisolated static func existingWindowIDs(pid: pid_t) -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return Set(list.compactMap { info -> CGWindowID? in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid else { return nil }
            return info[kCGWindowNumber as String] as? CGWindowID
        })
    }
}
