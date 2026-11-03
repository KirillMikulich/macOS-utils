import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// Предпросмотр окон приложения при наведении на его значок в Dock.
///
/// Это НЕ модификация системного Dock: модуль наблюдает за Dock через Accessibility
/// (см. `DockObserver`) и показывает собственную плавающую панель рядом со значком.
/// Дополнительно доступна панель по горячей клавише с окнами активного приложения.
@MainActor
@Observable
final class DockPreviewModule: AppModule {
    let id = ModuleID.dockPreview
    let title = "Превью в Dock"
    let summary = "Миниатюры окон приложения при наведении на его значок в Dock и по горячей клавише."
    let systemImage = "dock.arrow.up.rectangle"
    let requiredPermissions: [PermissionKind] = [.accessibility]
    let optionalPermissions: [PermissionKind] = [.screenRecording]

    let context: ModuleContext
    var runState: ModuleRunState = .disabled

    var settings: DockPreviewSettings {
        didSet {
            guard settings != oldValue else { return }
            context.settingsStore.save(settings)
            if settings.isEnabled == oldValue.isEnabled, runState == .running {
                try? activate()
            } else if settings.isEnabled == oldValue.isEnabled {
                declareShortcut(active: false)
            }
        }
    }

    var isEnabled: Bool {
        get { settings.isEnabled }
        set { settings.isEnabled = newValue }
    }

    var observerError: String? { dockObserver.lastError }

    private enum Mode {
        case dock(iconFrame: CGRect)   // рамка значка в координатах AppKit
        case hotkey

        var isHotkey: Bool { if case .hotkey = self { return true } else { return false } }
    }

    @ObservationIgnored private let dockObserver = DockObserver()
    @ObservationIgnored private let overlayModel = WindowOverlayModel()
    @ObservationIgnored private var panel: FloatingPanel?
    @ObservationIgnored private var mode: Mode?
    @ObservationIgnored private var shownPID: pid_t?
    @ObservationIgnored private var showTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored private var mouseTimer: Timer?
    @ObservationIgnored private var mouseOutsideSince: Date?
    @ObservationIgnored private var clickMonitor: Any?
    @ObservationIgnored private var escapeTokens: [UInt32] = []
    private let overlayID = "dockPreview"

    init(context: ModuleContext) {
        self.context = context
        self.settings = context.settingsStore.load(DockPreviewSettings.self)
        DockAutoHideController.recoverIfNeeded()
        dockObserver.onHoverChange = { [weak self] item in self?.dockHoverChanged(item) }
        context.overlays.register(overlayID) { [weak self] in self?.hide() }
        declareShortcut(active: false)
    }

    var shortcuts: [ModuleShortcutInfo] {
        [ModuleShortcutInfo(id: .dockPreviewPanel, title: "Окна активного приложения", combo: settings.panelShortcut)]
    }

    // MARK: - Lifecycle

    func activate() throws {
        if settings.showOnDockHover {
            dockObserver.start()
            if let error = dockObserver.lastError {
                dockObserver.stop()
                throw ModuleError.startFailed(error)
            }
            startMouseFallback()
        } else {
            dockObserver.stop()
            stopMouseFallback()
        }
        declareShortcut(active: true)
    }

    func deactivate() {
        dockObserver.stop()
        stopMouseFallback()
        declareShortcut(active: false)
        hide()
    }

    private func declareShortcut(active: Bool) {
        context.shortcuts.update(.dockPreviewPanel, title: "Превью в Dock: окна активного приложения",
                                 combo: settings.panelShortcut, active: active) { [weak self] in
            self?.toggleHotkeyPanel()
        }
    }

    // MARK: - Наведение на Dock

    private func dockHoverChanged(_ item: DockHoveredItem?) {
        lastHoveredPID = item?.pid
        guard let item, let pid = item.pid,
              !(item.bundleID.map(settings.excludedBundleIDs.contains) ?? false),
              pid != ProcessInfo.processInfo.processIdentifier else {
            // Курсор ушёл со значка: панель скроется, если курсор не перейдёт на неё (см. таймер мыши).
            showTask?.cancel()
            pendingPID = nil
            return
        }
        // Повторное событие для того же значка не перезапускает отсчёт задержки.
        if pendingPID == pid, showTask != nil { return }
        showTask?.cancel()
        let iconFrame = item.frame.flippedToCocoa
        let isShowingDock: Bool = { if case .dock = mode { return panel?.isVisible == true } else { return false } }()
        // Курсор вернулся с панели на тот же значок — панель уже показана, ничего не пересоздаём.
        if isShowingDock && shownPID == pid {
            mode = .dock(iconFrame: iconFrame)
            return
        }
        // Если панель уже открыта для другого значка — переключаемся сразу, без задержки.
        let delay = isShowingDock ? 0 : settings.hoverDelay
        pendingPID = pid
        showTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .milliseconds(Int(delay * 1000))) }
            guard let self, !Task.isCancelled else { return }
            defer { if self.pendingPID == pid { self.pendingPID = nil; self.showTask = nil } }
            // Курсор всё ещё над тем же значком? Во время анимации Dock (выезд, увеличение)
            // AX может временно не ответить — тогда достаточно, что курсор над значком.
            @MainActor func stillHovered() -> Bool {
                self.dockObserver.currentHoveredItem()?.pid == pid
                    || NSMouseInRect(NSEvent.mouseLocation, iconFrame.insetBy(dx: -6, dy: -6), false)
            }
            guard stillHovered() else { return }
            // Курсор должен остановиться на значке: проход «по касательной» превью не открывает.
            if self.settings.requireCursorStop {
                var waited = 0.0
                while !self.pointerResting.isResting(at: NSEvent.mouseLocation) {
                    try? await Task.sleep(for: .milliseconds(60))
                    waited += 0.06
                    guard !Task.isCancelled, stillHovered(), waited < 5 else { return }
                }
            }
            await self.show(pid: pid, appName: item.title, mode: .dock(iconFrame: iconFrame))
        }
    }

    // MARK: - Запасной путь: сверка наведения по движению мыши

    @ObservationIgnored private var pendingPID: pid_t?
    @ObservationIgnored private var lastHoveredPID: pid_t?
    @ObservationIgnored private var mouseMoveMonitor: Any?
    @ObservationIgnored private var lastMouseCheck: TimeInterval = 0

    /// Уведомления Dock иногда теряются (быстрое движение мыши, анимация выезда).
    /// Пока курсор над Dock, раз в 60 мс сверяем наведённый значок сами.
    /// Вне Dock обработчик только сравнивает время — нагрузки нет.
    private func startMouseFallback() {
        guard mouseMoveMonitor == nil else { return }
        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
    }

    private func stopMouseFallback() {
        if let mouseMoveMonitor { NSEvent.removeMonitor(mouseMoveMonitor) }
        mouseMoveMonitor = nil
    }

    @ObservationIgnored private var pointerResting = PointerRestDetector()

    private func mouseMoved() {
        pointerResting.record(NSEvent.mouseLocation, at: ProcessInfo.processInfo.systemUptime)
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMouseCheck > 0.06 else { return }
        lastMouseCheck = now
        guard let dockFrame = dockObserver.dockFrame(),
              NSMouseInRect(NSEvent.mouseLocation, dockFrame.insetBy(dx: -4, dy: -4), false) else { return }
        let item = dockObserver.currentHoveredItem()
        if item?.pid != lastHoveredPID {
            dockHoverChanged(item)
        }
    }

    // MARK: - Горячая клавиша

    private func toggleHotkeyPanel() {
        if case .hotkey = mode, panel?.isVisible == true {
            hide()
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            NSSound.beep()
            return
        }
        showTask?.cancel()
        showTask = Task { [weak self] in
            await self?.show(pid: app.processIdentifier, appName: app.localizedName ?? "", mode: .hotkey)
        }
    }

    // MARK: - Показ

    private func show(pid: pid_t, appName: String, mode: Mode) async {
        let options = WindowDiscoveryOptions(includeMinimized: settings.showMinimized, includeHiddenApps: true, onlyPIDs: [pid])
        let discovered = await context.windowDiscovery.discover(options)
        guard !Task.isCancelled, runState == .running else { return }
        let windows = WindowListBuilder.build(discovered, configuration: WindowListConfiguration(
            sortOrder: .recentlyUsed, showMinimized: settings.showMinimized, excludedBundleIDs: Set(settings.excludedBundleIDs)))
        guard !windows.isEmpty else {
            if case .hotkey = mode { NSSound.beep() }
            hide()
            return
        }

        let style = settings.thumbnailStyle
        let sections = makeSections(windows)
        let screen = screen(for: mode)
        let frame = panelFrame(sections: sections, style: style, mode: mode, screen: screen)

        let panel = panel ?? makePanel()
        self.panel = panel
        self.mode = mode
        self.shownPID = pid
        overlayModel.reset(windows: windows, selectedID: nil)
        let actions = WindowCellActions(
            close: { [weak self] window in
                self?.context.windowActivator.close(window)
                self?.removeFromPanel(window)
            },
            minimize: { [weak self] window in
                self?.context.windowActivator.minimize(window)
                if self?.settings.showMinimized == false { self?.removeFromPanel(window) }
            },
            quitApp: { [weak self] window in
                NSRunningApplication(processIdentifier: window.pid)?.terminate()
                self?.hide()
            })
        panel.setContent(WindowPreviewView(model: overlayModel, appName: appName, showAppName: settings.showAppName,
                                           sections: sections, style: style,
                                           actions: actions, onSelect: { [weak self] in self?.select($0) }))
        panel.setFrame(frame, display: true)
        context.overlays.willShow(overlayID)
        panel.orderFrontRegardless()

        startMouseTracking()
        loadThumbnails(windows)
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel()
        panel.acceptsKey = false
        // Над Dock: уровень выше, чем у Dock, чтобы панель не пряталась под ним.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        return panel
    }

    private func makeSections(_ windows: [WindowInfo]) -> [DockPreviewSection] {
        guard settings.groupByDisplay, NSScreen.screens.count > 1 else {
            return [DockPreviewSection(id: "all", title: nil, windows: windows)]
        }
        var order: [String] = []
        var groups: [String: [WindowInfo]] = [:]
        for window in windows {
            let name = window.isMinimized ? "Свёрнутые" : (window.screen?.localizedName ?? "Другой экран")
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(window)
        }
        return order.map { DockPreviewSection(id: $0, title: $0, windows: groups[$0] ?? []) }
    }

    private func screen(for mode: Mode) -> NSScreen {
        switch mode {
        case .dock(let iconFrame):
            let center = NSPoint(x: iconFrame.midX, y: iconFrame.midY)
            return NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? NSScreen.withMouse ?? NSScreen.screens[0]
        case .hotkey:
            return NSScreen.withMouse ?? NSScreen.main ?? NSScreen.screens[0]
        }
    }

    /// Область экрана, в которой может находиться панель: для Dock — строго над ним
    /// (или сбоку от бокового Dock), чтобы панель никогда не перекрывала Dock.
    private func availableArea(for mode: Mode, screen: NSScreen, orientation: DockOrientation) -> NSRect {
        let frame = screen.frame
        // Высота строки меню: при автоскрытии Dock visibleFrame отличается от frame только сверху.
        let menuBar = max(frame.maxY - screen.visibleFrame.maxY, 25)
        let top = frame.maxY - menuBar - 6
        let gap: CGFloat = 10

        switch mode {
        case .hotkey:
            return screen.visibleFrame.insetBy(dx: 20, dy: 20)
        case .dock(let icon):
            // Толщина Dock считается от края экрана: при автоскрытии рамки Dock во время
            // выезда ещё частично за экраном, а толщина (размер списка значков или
            // увеличенного значка) от анимации не зависит.
            let dock = dockObserver.dockFrame() ?? icon
            let margin: CGFloat = 4 // Dock стоит с небольшим отступом от края экрана
            switch orientation {
            case .bottom:
                let thickness = max(dock.height, icon.height) + margin
                let bottom = frame.minY + thickness + gap
                return NSRect(x: frame.minX + 6, y: bottom, width: frame.width - 12, height: max(top - bottom, 100))
            case .left:
                let left = frame.minX + max(dock.width, icon.width) + margin + gap
                return NSRect(x: left, y: frame.minY + 6, width: max(frame.maxX - 6 - left, 100), height: top - frame.minY - 6)
            case .right:
                let right = frame.maxX - max(dock.width, icon.width) - margin - gap
                return NSRect(x: frame.minX + 6, y: frame.minY + 6, width: max(right - frame.minX - 6, 100), height: top - frame.minY - 6)
            }
        }
    }

    private func panelFrame(sections: [DockPreviewSection], style: WindowThumbnailStyle, mode: Mode, screen: NSScreen) -> NSRect {
        let orientation = DockOrientation.current
        let area = availableArea(for: mode, screen: screen, orientation: orientation)
        let maxWidth = mode.isHotkey ? area.width * 0.9 : area.width
        let maxHeight = mode.isHotkey ? area.height * 0.8 : area.height
        let isSideDock = !mode.isHotkey && orientation != .bottom
        let largest = sections.map(\.windows.count).max() ?? 1

        let padding = style.panelPadding * 2
        let fitting = max(1, Int((maxWidth - padding + style.spacing) / (style.cellWidth + style.spacing)))
        let columns = isSideDock ? min(largest > 4 ? 2 : 1, fitting) : max(1, min(largest, fitting))
        overlayModel.columns = columns

        let width = CGFloat(columns) * (style.cellWidth + style.spacing) - style.spacing + padding
        var height: CGFloat = padding + (settings.showAppName ? 26 : 0) // отступы + название приложения
        for section in sections {
            let rows = Int(ceil(Double(section.windows.count) / Double(columns)))
            height += CGFloat(rows) * (style.cellHeight + style.spacing) + (section.title != nil ? 26 : 0)
        }
        // Если окна не помещаются, панель ограничивается доступной областью, а внутри прокрутка.
        let size = NSSize(width: min(width, maxWidth), height: min(height, maxHeight))

        var origin: NSPoint
        switch mode {
        case .dock(let icon):
            switch orientation {
            case .bottom: origin = NSPoint(x: icon.midX - size.width / 2, y: area.minY)
            case .left: origin = NSPoint(x: area.minX, y: icon.midY - size.height / 2)
            case .right: origin = NSPoint(x: area.maxX - size.width, y: icon.midY - size.height / 2)
            }
        case .hotkey:
            origin = NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
        origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }

    private func loadThumbnails(_ windows: [WindowInfo]) {
        thumbnailTask?.cancel()
        guard settings.showThumbnails else { return }
        let maxPixel = settings.thumbnailSize * (NSScreen.main?.backingScaleFactor ?? 2)
        thumbnailTask = Task { [weak self] in
            guard let self else { return }
            await context.thumbnails.loadThumbnails(for: windows, maxPixelSize: maxPixel) { [weak self] id, image in
                guard let self, !Task.isCancelled else { return }
                overlayModel.images[id] = image
            }
        }
    }

    /// Окно закрыто с панели: если окон не осталось — панель скрывается,
    /// иначе предпросмотр перестраивается по актуальному списку.
    private func removeFromPanel(_ window: WindowInfo) {
        let remaining = overlayModel.windows.filter { $0.id != window.id }
        guard !remaining.isEmpty, let pid = shownPID, let mode else {
            hide()
            return
        }
        let appName = window.appName
        showTask?.cancel()
        showTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            await self.show(pid: pid, appName: appName, mode: mode)
        }
    }

    private func select(_ window: WindowInfo) {
        hide()
        context.windowActivator.activate(window, scope: settings.activationScope)
    }

    func hide() {
        showTask?.cancel()
        showTask = nil
        pendingPID = nil
        thumbnailTask?.cancel()
        stopMouseTracking()
        panel?.orderOut(nil)
        panel?.contentView = nil
        overlayModel.reset(windows: [], selectedID: nil)
        mode = nil
        shownPID = nil
    }

    // MARK: - Отслеживание курсора (только пока панель видна)

    private func startMouseTracking() {
        stopMouseTracking()
        mouseOutsideSince = nil
        switch mode {
        case .dock:
            // Скрываем панель, когда курсор покинул и значок, и панель (с небольшой задержкой,
            // чтобы успеть перевести курсор со значка на панель).
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkMouse() }
            }
            RunLoop.main.add(timer, forMode: .common)
            mouseTimer = timer
            // Щелчок по значку Dock — обычное действие Dock; панель при этом убираем.
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        case .hotkey:
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
            escapeTokens = context.shortcuts.registerTemporary([KeyCombo(keyCode: kVK_Escape, carbonModifiers: 0)]) { [weak self] _ in
                self?.hide()
            }
        case nil:
            break
        }
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        context.shortcuts.unregisterTemporary(escapeTokens)
        escapeTokens = []
    }

    private func checkMouse() {
        guard let panel, case .dock(let iconFrame) = mode else { return }
        let mouse = NSEvent.mouseLocation
        let overPanel = NSMouseInRect(mouse, panel.frame.insetBy(dx: -8, dy: -8), false)
        let overIcon = NSMouseInRect(mouse, iconFrame.insetBy(dx: -4, dy: -4), false)
        // Коридор от значка до панели считается частью превью: пока курсор идёт по нему,
        // Dock уже не подсвечивает значок, и раньше превью успевало закрыться.
        let corridorX = min(iconFrame.minX, panel.frame.minX)...max(iconFrame.maxX, panel.frame.maxX)
        let corridor = CGRect(x: max(iconFrame.minX - 30, corridorX.lowerBound), y: min(iconFrame.minY, panel.frame.minY),
                              width: min(iconFrame.width + 60, corridorX.upperBound - corridorX.lowerBound),
                              height: max(iconFrame.maxY, panel.frame.maxY) - min(iconFrame.minY, panel.frame.minY))
        let inCorridor = NSMouseInRect(mouse, corridor, false)
        if overPanel || overIcon || inCorridor {
            mouseOutsideSince = nil
            return
        }
        if let since = mouseOutsideSince {
            if Date().timeIntervalSince(since) > 0.25 { hide() }
        } else {
            mouseOutsideSince = Date()
        }
    }

    // MARK: - UI

    func makeSettingsView() -> AnyView {
        AnyView(DockPreviewSettingsView(module: self))
    }

    func makeQuickSettingsView() -> AnyView {
        AnyView(DockPreviewQuickSettingsView(module: self))
    }
}

/// Определяет, остановился ли курсор: за последние `window` секунд он сдвинулся
/// не больше чем на `threshold` pt. Отдельно от модуля — покрыто тестами.
struct PointerRestDetector {
    var window: TimeInterval = 0.12
    /// Допуск на дрожание руки: у чувствительных мышей 6 pt было мало — превью не дожидалось «остановки».
    var threshold: CGFloat = 12
    private var samples: [(time: TimeInterval, point: CGPoint)] = []

    mutating func record(_ point: CGPoint, at time: TimeInterval) {
        samples.append((time, point))
        // Храним только последние полсекунды.
        samples.removeAll { time - $0.time > 0.5 }
    }

    func isResting(at point: CGPoint, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        // Нет движений за окно — курсор стоит.
        let recent = samples.filter { now - $0.time <= window }
        guard !recent.isEmpty else { return true }
        // Самая ранняя точка в окне (или последняя до него) — откуда курсор пришёл.
        let reference = samples.last { now - $0.time > window }?.point ?? recent[0].point
        let points = recent.map(\.point) + [reference]
        return points.allSatisfy { hypot($0.x - point.x, $0.y - point.y) <= threshold }
    }
}
