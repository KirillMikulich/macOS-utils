import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// Переключатель окон в стиле Alt+Tab: каждое окно — отдельный элемент.
///
/// Поток работы:
/// 1. Глобальное сочетание (по умолчанию ⌥⇥) запускает сеанс: окна перечисляются в фоне.
/// 2. Если модификатор уже отпущен (быстрое нажатие) — сразу переключаемся на следующее окно.
/// 3. Иначе показывается панель. Повторные ⌥⇥ / ⌥⇧⇥ двигают выбор; стрелки, ↩ и Esc
///    регистрируются как временные глобальные сочетания только на время показа панели.
/// 4. Отпускание модификатора (проверяется опросом `NSEvent.modifierFlags` раз в 15 мс,
///    только пока панель открыта) подтверждает выбор.
@MainActor
@Observable
final class WindowSwitcherModule: AppModule {
    let id = ModuleID.windowSwitcher
    let title = "Переключение окон"
    let summary = "Переключение между отдельными окнами (не только приложениями) с миниатюрами, как Alt+Tab."
    let systemImage = "macwindow.on.rectangle"
    let requiredPermissions: [PermissionKind] = [.accessibility]
    let optionalPermissions: [PermissionKind] = [.screenRecording]

    let context: ModuleContext
    var runState: ModuleRunState = .disabled

    var settings: WindowSwitcherSettings {
        didSet {
            guard settings != oldValue else { return }
            context.settingsStore.save(settings)
            if settings.isEnabled == oldValue.isEnabled {
                declareShortcuts(active: runState == .running)
                updateCommandTab(active: runState == .running)
            }
        }
    }

    var isEnabled: Bool {
        get { settings.isEnabled }
        set { settings.isEnabled = newValue }
    }

    @ObservationIgnored private let overlayModel = WindowOverlayModel()
    @ObservationIgnored private var session: SwitcherSession?
    @ObservationIgnored private var panel: FloatingPanel?
    @ObservationIgnored private var modifierTimer: Timer?
    @ObservationIgnored private var temporaryTokens: [UInt32] = []
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSteps = 0
    private let overlayID = "windowSwitcher"

    init(context: ModuleContext) {
        self.context = context
        self.settings = context.settingsStore.load(WindowSwitcherSettings.self)
        context.overlays.register(overlayID) { [weak self] in self?.cancel() }
        declareShortcuts(active: false)
    }

    var shortcuts: [ModuleShortcutInfo] {
        [
            ModuleShortcutInfo(id: .switcherForward, title: "Следующее окно", combo: settings.forwardShortcut),
            ModuleShortcutInfo(id: .switcherBackward, title: "Предыдущее окно", combo: settings.backwardShortcut),
        ]
    }

    // MARK: - Lifecycle

    func activate() throws {
        declareShortcuts(active: true)
        updateCommandTab(active: true)
    }

    func deactivate() {
        declareShortcuts(active: false)
        updateCommandTab(active: false)
        cancel()
    }

    // MARK: - ⌘⇥ вместо системного переключателя

    @ObservationIgnored private let commandTab = CommandTabInterceptor()
    private(set) var commandTabError: String?

    private func updateCommandTab(active: Bool) {
        if active && settings.replaceCommandTab {
            commandTab.onCommandTab = { [weak self] backward in
                self?.handleTrigger(backward ? .backward : .forward, hold: .command)
            }
            commandTab.start()
            commandTabError = commandTab.lastError
        } else {
            commandTab.stop()
            commandTabError = nil
        }
    }

    private func declareShortcuts(active: Bool) {
        context.shortcuts.update(.switcherForward, title: "Переключение окон: следующее окно",
                                 combo: settings.forwardShortcut, active: active) { [weak self] in
            self?.handleTrigger(.forward)
        }
        context.shortcuts.update(.switcherBackward, title: "Переключение окон: предыдущее окно",
                                 combo: settings.backwardShortcut, active: active) { [weak self] in
            self?.handleTrigger(.backward)
        }
    }

    /// Модификатор, которым начат текущий сеанс (⌘ — при ⌘⇥, иначе из сочетания).
    @ObservationIgnored private var sessionHoldModifiers: NSEvent.ModifierFlags?

    /// Модификаторы, удержание которых держит переключатель открытым (без ⇧).
    private var holdModifiers: NSEvent.ModifierFlags {
        if let sessionHoldModifiers { return sessionHoldModifiers }
        let combo = settings.forwardShortcut ?? settings.backwardShortcut
        return (combo?.modifierFlags ?? [.option]).subtracting(.shift)
    }

    // MARK: - Сеанс

    private func handleTrigger(_ direction: SwitchDirection, hold: NSEvent.ModifierFlags? = nil) {
        if session == nil && discoveryTask == nil {
            sessionHoldModifiers = hold
        }
        if session != nil {
            step(direction)
            return
        }
        if discoveryTask != nil {
            // Окна ещё перечисляются — запоминаем дополнительные нажатия.
            pendingSteps += direction == .forward ? 1 : -1
            return
        }
        beginSession(direction)
    }

    private func beginSession(_ direction: SwitchDirection) {
        pendingSteps = 0
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            let options = WindowDiscoveryOptions(includeMinimized: settings.showMinimized,
                                                 includeHiddenApps: settings.showHiddenApps)
            let all = await context.windowDiscovery.discover(options)
            let windows = WindowListBuilder.build(all, configuration: listConfiguration())
            discoveryTask = nil
            guard runState == .running else { return }
            guard !windows.isEmpty else {
                NSSound.beep()
                return
            }
            var newSession = SwitcherSession(windows: windows, direction: direction)
            for _ in 0..<abs(pendingSteps) { newSession.step(pendingSteps > 0 ? .forward : .backward) }
            session = newSession

            // Быстрое нажатие: модификатор уже отпущен — переключаемся без показа панели.
            if settings.confirmOnModifierRelease && !modifiersHeld() {
                confirm()
                return
            }
            showPanel()
        }
    }

    private func listConfiguration() -> WindowListConfiguration {
        var configuration = WindowListConfiguration(sortOrder: settings.sortOrder,
                                                    groupByApp: settings.groupByApp,
                                                    showMinimized: settings.showMinimized,
                                                    showHiddenApps: settings.showHiddenApps,
                                                    excludedBundleIDs: Set(settings.excludedBundleIDs))
        if settings.onlyMouseScreen, let screen = NSScreen.withMouse {
            configuration.filter = { $0.screen == screen || $0.isMinimized }
        }
        return configuration
    }

    private func step(_ direction: SwitchDirection) {
        guard var session else { return }
        session.step(direction)
        self.session = session
        overlayModel.selectedID = session.selectedWindow?.id
    }

    private func move(rows: Int, columns: Int) {
        guard var session else { return }
        if rows == 0 {
            session.step(columns > 0 ? .forward : .backward)
        } else {
            session.move(rows: rows, columns: settings.layout == .vertical ? 1 : overlayModel.columns)
        }
        self.session = session
        overlayModel.selectedID = session.selectedWindow?.id
    }

    private func confirm() {
        guard var current = session else { return }
        let window = current.confirm()
        session = nil
        closePanel()
        if let window {
            context.windowActivator.activate(window, scope: settings.activationScope)
        }
    }

    private func select(_ window: WindowInfo) {
        session?.select(id: window.id)
        confirm()
    }

    /// Отмена: панель закрывается, фокус возвращается в исходное приложение.
    func cancel() {
        discoveryTask?.cancel()
        discoveryTask = nil
        guard session != nil || panel?.isVisible == true else { return }
        session?.cancel()
        session = nil
        closePanel()
    }

    private func modifiersHeld() -> Bool {
        let required = holdModifiers
        guard !required.isEmpty else { return false }
        return !NSEvent.modifierFlags.intersection(required).isEmpty
    }

    // MARK: - Панель

    private func showPanel() {
        guard let session else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.appearance = settings.appearance.nsAppearance

        let frame = currentPanelFrame(count: session.windows.count)
        overlayModel.reset(windows: session.windows, selectedID: session.selectedWindow?.id)
        panel.setContent(WindowSwitcherView(model: overlayModel, settings: settings, actions: cellActions,
                                            onSelect: { [weak self] in self?.select($0) },
                                            onHover: { [weak self] window in
                                                self?.session?.select(id: window.id)
                                                self?.overlayModel.selectedID = window.id
                                            }))
        panel.setFrame(frame, display: true)
        context.overlays.willShow(overlayID)
        // Панель не становится key: клавиатура остаётся у текущего приложения,
        // а нужные клавиши приходят через временные глобальные сочетания.
        panel.orderFrontRegardless()

        installSessionKeys()
        startModifierPolling()
        loadThumbnails(for: session.windows)
    }

    private func currentPanelFrame(count: Int) -> NSRect {
        let screen = NSScreen.withMouse ?? NSScreen.main ?? NSScreen.screens[0]
        return panelFrame(count: count, style: settings.thumbnailStyle, screen: screen)
    }

    // MARK: - Действия над окнами (кнопки на миниатюрах и ⌥W / ⌥M / ⌥Q)

    private var cellActions: WindowCellActions {
        WindowCellActions(close: { [weak self] in self?.closeWindow($0) },
                          minimize: { [weak self] in self?.minimizeWindow($0) },
                          quitApp: { [weak self] in self?.quitApp(of: $0) })
    }

    private func closeWindow(_ window: WindowInfo) {
        context.windowActivator.close(window)
        removeFromSession { $0.id == window.id }
        scheduleRefresh()
    }

    private func minimizeWindow(_ window: WindowInfo) {
        guard !window.isMinimized else { return }
        context.windowActivator.minimize(window)
        if !settings.showMinimized { removeFromSession { $0.id == window.id } }
        scheduleRefresh()
    }

    private func quitApp(of window: WindowInfo) {
        // Обычное завершение: приложение может спросить о сохранении документов.
        NSRunningApplication(processIdentifier: window.pid)?.terminate()
        removeFromSession { $0.pid == window.pid }
    }

    /// Убирает окна из открытого переключателя сразу, не дожидаясь повторного перечисления.
    private func removeFromSession(where shouldRemove: (WindowInfo) -> Bool) {
        guard var current = session else { return }
        current.update(windows: current.windows.filter { !shouldRemove($0) })
        guard !current.windows.isEmpty else {
            cancel()
            return
        }
        session = current
        overlayModel.windows = current.windows
        overlayModel.selectedID = current.selectedWindow?.id
        panel?.setFrame(currentPanelFrame(count: current.windows.count), display: true, animate: false)
    }

    /// После закрытия или сворачивания состояние окон меняется не мгновенно —
    /// перечитываем список чуть позже, сохраняя выбранное окно.
    private func scheduleRefresh() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, session != nil else { return }
            let options = WindowDiscoveryOptions(includeMinimized: settings.showMinimized,
                                                 includeHiddenApps: settings.showHiddenApps)
            let windows = WindowListBuilder.build(await context.windowDiscovery.discover(options),
                                                  configuration: listConfiguration())
            guard var current = session else { return }
            current.update(windows: windows)
            guard !current.windows.isEmpty else { return cancel() }
            session = current
            overlayModel.reset(windows: current.windows, selectedID: current.selectedWindow?.id)
            panel?.setFrame(currentPanelFrame(count: current.windows.count), display: true, animate: false)
            loadThumbnails(for: current.windows)
        }
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel()
        panel.acceptsKey = false
        return panel
    }

    private func panelFrame(count: Int, style: WindowThumbnailStyle, screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let maxWidth = visible.width * 0.92
        let maxHeight = visible.height * 0.85
        var size: NSSize
        let padding = style.panelPadding * 2
        switch settings.layout {
        case .horizontal:
            let perRow = max(1, min(count, Int((maxWidth - padding + style.spacing) / (style.cellWidth + style.spacing))))
            overlayModel.columns = perRow
            let rows = Int(ceil(Double(count) / Double(perRow)))
            size = NSSize(width: CGFloat(perRow) * (style.cellWidth + style.spacing) - style.spacing + padding,
                          height: min(maxHeight, CGFloat(rows) * (style.cellHeight + style.spacing) - style.spacing + padding))
        case .vertical:
            overlayModel.columns = 1
            // Заголовки групп (при группировке) добавляют высоту — учитываем с запасом.
            let groups = settings.groupByApp ? Set(session?.windows.map(\.pid) ?? []).count : 0
            size = NSSize(width: WindowThumbnailStyle.listWidth + padding,
                          height: min(maxHeight, CGFloat(count) * (style.listRowHeight + style.spacing) + CGFloat(groups) * 22 + padding))
        }
        let x = visible.midX - size.width / 2
        let y: CGFloat
        switch settings.position {
        case .center: y = visible.midY - size.height / 2
        case .top: y = visible.maxY - size.height - 40
        case .bottom: y = visible.minY + 40
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func closePanel() {
        sessionHoldModifiers = nil
        stopModifierPolling()
        context.shortcuts.unregisterTemporary(temporaryTokens)
        temporaryTokens = []
        thumbnailTask?.cancel()
        thumbnailTask = nil
        panel?.orderOut(nil)
        // Освобождаем SwiftUI-иерархию и изображения — в покое память не занята.
        panel?.contentView = nil
        overlayModel.reset(windows: [], selectedID: nil)
    }

    private func loadThumbnails(for windows: [WindowInfo]) {
        thumbnailTask?.cancel()
        // В режиме значков миниатюры не захватываются вовсе — экономия CPU.
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

    // MARK: - Клавиши на время показа

    private func installSessionKeys() {
        context.shortcuts.unregisterTemporary(temporaryTokens)
        let held = KeyCombo.carbonFlags(from: holdModifiers)
        let shift = KeyCombo.carbonFlags(from: [.shift])
        let keys = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Escape, kVK_Return, kVK_ANSI_KeypadEnter,
                    kVK_ANSI_W, kVK_ANSI_M, kVK_ANSI_Q]
        var combos: [KeyCombo] = []
        for key in keys {
            combos.append(KeyCombo(keyCode: key, carbonModifiers: held))
            combos.append(KeyCombo(keyCode: key, carbonModifiers: held | shift))
            if !settings.confirmOnModifierRelease {
                combos.append(KeyCombo(keyCode: key, carbonModifiers: 0))
            }
        }
        temporaryTokens = context.shortcuts.registerTemporary(combos) { [weak self] combo in
            self?.handleSessionKey(Int(combo.keyCode))
        }
    }

    private func handleSessionKey(_ keyCode: Int) {
        switch keyCode {
        case kVK_LeftArrow: move(rows: 0, columns: -1)
        case kVK_RightArrow: move(rows: 0, columns: 1)
        case kVK_UpArrow: move(rows: -1, columns: 0)
        case kVK_DownArrow: move(rows: 1, columns: 0)
        case kVK_Escape: cancel()
        case kVK_Return, kVK_ANSI_KeypadEnter: confirm()
        case kVK_ANSI_W: if let window = session?.selectedWindow { closeWindow(window) }
        case kVK_ANSI_M: if let window = session?.selectedWindow { minimizeWindow(window) }
        case kVK_ANSI_Q: if let window = session?.selectedWindow { quitApp(of: window) }
        default: break
        }
    }

    private func startModifierPolling() {
        stopModifierPolling()
        guard settings.confirmOnModifierRelease else { return }
        let timer = Timer(timeInterval: 0.015, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.modifiersHeld() { self.confirm() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        modifierTimer = timer
    }

    private func stopModifierPolling() {
        modifierTimer?.invalidate()
        modifierTimer = nil
    }

    // MARK: - UI

    func makeSettingsView() -> AnyView {
        AnyView(WindowSwitcherSettingsView(module: self))
    }

    func makeQuickSettingsView() -> AnyView {
        AnyView(WindowSwitcherQuickSettingsView(module: self))
    }
}
