import AppKit
import ApplicationServices

struct DockHoveredItem: Equatable {
    let title: String
    let bundleID: String?
    let pid: pid_t?
    /// Рамка значка в координатах AX (начало — левый верхний угол главного экрана).
    let frame: CGRect
}

enum DockOrientation: String {
    case bottom, left, right

    static var current: DockOrientation {
        let value = CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String
        return DockOrientation(rawValue: value ?? "bottom") ?? .bottom
    }
}

/// Отслеживает, над каким значком Dock находится курсор.
///
/// Как это работает: системный Dock предоставляет дерево Accessibility; его значки лежат в
/// элементе AXList. Когда курсор наводится на значок, Dock «выделяет» его, и список рассылает
/// уведомление `kAXSelectedChildrenChangedNotification`. Мы подписываемся на него через
/// AXObserver — это публичный API, нужен только доступ Accessibility. Тот же подход
/// использует DockDoor (GPL-3.0); код здесь написан независимо.
///
/// Ограничения:
/// - Встроиться в Dock или изменить его поведение нельзя — мы только наблюдаем и показываем
///   свою панель рядом.
/// - После перезапуска Dock (`killall Dock`) наблюдатель переподключается автоматически.
@MainActor
final class DockObserver {
    var onHoverChange: ((DockHoveredItem?) -> Void)?

    private var observer: AXObserver?
    private var dockList: AXUIElement?
    private var workspaceTokens: [NSObjectProtocol] = []
    private(set) var isRunning = false
    private(set) var lastError: String?

    func start() {
        guard !isRunning else { return }
        isRunning = true
        attach()
        let center = NSWorkspace.shared.notificationCenter
        // Dock — фоновый системный процесс: NSWorkspace не присылает для него
        // didLaunchApplication. Поэтому следим за списком процессов (KVO) и замечаем,
        // что у Dock сменился PID (перезапуск через killall Dock, модуль «Мышь и Dock» и т.п.).
        runningAppsObservation = NSWorkspace.shared.observe(\.runningApplications, options: []) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.checkDockProcess() }
            }
        }
        // После сна и смены мониторов Dock перестраивает дерево AX, и старый наблюдатель
        // может перестать получать события — переподключаемся.
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleReattach()
        })
        screenToken = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleReattach()
        }
    }

    private var screenToken: NSObjectProtocol?
    private var runningAppsObservation: NSKeyValueObservation?
    private var attachedPID: pid_t?
    private var reattachGeneration = 0

    private func checkDockProcess() {
        guard isRunning else { return }
        let currentPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        if currentPID != attachedPID {
            scheduleReattach()
        }
    }

    /// Переподключение с повторами: новый Dock строит дерево Accessibility не сразу.
    private nonisolated func scheduleReattach() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.reattachGeneration += 1
                self.reattach(attempt: 1, generation: self.reattachGeneration)
            }
        }
    }

    private func reattach(attempt: Int, generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, generation == self.reattachGeneration else { return }
                self.detach()
                self.attach()
                if self.observer == nil, attempt < 8 {
                    self.reattach(attempt: attempt + 1, generation: generation)
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceTokens.removeAll()
        runningAppsObservation?.invalidate()
        runningAppsObservation = nil
        if let screenToken { NotificationCenter.default.removeObserver(screenToken) }
        screenToken = nil
        detach()
    }

    private func attach() {
        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            lastError = "Процесс Dock не найден"
            return
        }
        let pid = dockApp.processIdentifier
        let dockElement = AXUIElementCreateApplication(pid)
        // Без ограничения запрос к занятому Dock (выезд, увеличение значков) может ждать
        // ответа секундами — и весь главный поток Mac Utilities «висел» вместе с превью.
        AXUIElementSetMessagingTimeout(dockElement, 0.15)
        guard let list = AX.elements(dockElement, kAXChildrenAttribute).first(where: { AX.string($0, kAXRoleAttribute) == kAXListRole as String }) else {
            lastError = "Не удалось получить список значков Dock (нет доступа Accessibility?)"
            Log.dock.error("Dock AXList not found")
            return
        }

        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let observer = Unmanaged<DockObserver>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { observer.selectionChanged() }
        }
        guard AXObserverCreate(pid, callback, &newObserver) == .success, let newObserver else {
            lastError = "AXObserverCreate завершился ошибкой"
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = AXObserverAddNotification(newObserver, list, kAXSelectedChildrenChangedNotification as CFString, refcon)
        guard result == .success else {
            lastError = "Не удалось подписаться на события Dock (код \(result.rawValue))"
            Log.dock.error("AXObserverAddNotification failed: \(result.rawValue)")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
        observer = newObserver
        AXUIElementSetMessagingTimeout(list, 0.15)
        dockList = list
        attachedPID = pid
        lastError = nil
        Log.dock.info("Dock observer attached")
    }

    private func detach() {
        if let observer, let dockList {
            AXObserverRemoveNotification(observer, dockList, kAXSelectedChildrenChangedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        attachedPID = nil
        dockList = nil
    }

    private func selectionChanged() {
        guard isRunning else { return }
        onHoverChange?(currentHoveredItem())
    }

    /// Рамка всего Dock (элемента-списка значков) в координатах AppKit.
    func dockFrame() -> CGRect? {
        guard let dockList, let frame = AX.frame(dockList), frame.width > 0, frame.height > 0 else { return nil }
        return frame.flippedToCocoa
    }

    /// Текущий выделенный (наведённый) значок приложения в Dock, если он есть.
    func currentHoveredItem() -> DockHoveredItem? {
        guard let dockList,
              let selected = AX.elements(dockList, kAXSelectedChildrenAttribute).first,
              AX.string(selected, kAXSubroleAttribute) == "AXApplicationDockItem",
              let frame = AX.frame(selected) else { return nil }

        let title = AX.string(selected, kAXTitleAttribute) ?? ""
        var bundleID: String?
        if let url = AX.attribute(selected, kAXURLAttribute, as: URL.self) ?? AX.attribute(selected, kAXURLAttribute, as: NSURL.self) as URL? {
            bundleID = Bundle(url: url)?.bundleIdentifier
        }
        let app = bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            ?? NSWorkspace.shared.runningApplications.first { $0.localizedName == title && $0.activationPolicy == .regular }
        return DockHoveredItem(title: title, bundleID: bundleID ?? app?.bundleIdentifier, pid: app?.processIdentifier, frame: frame)
    }
}
