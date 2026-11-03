import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// Состояние панели истории (поиск и выделение).
@MainActor
@Observable
final class ClipboardPanelModel {
    var query = ""
    var selectedID: UUID?
    /// Увеличивается при каждом показе — представление по нему ставит фокус в поле поиска.
    var focusToken = 0

    /// Порядок отображения: сначала закреплённые, затем остальные (новые сверху).
    func visibleItems(in store: ClipboardStore) -> [ClipboardItem] {
        let found = store.search(query)
        return found.filter(\.isPinned) + found.filter { !$0.isPinned }
    }

    func moveSelection(by delta: Int, in items: [ClipboardItem]) {
        guard !items.isEmpty else { selectedID = nil; return }
        let current = items.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : items.count)
        let next = min(max(current + delta, 0), items.count - 1)
        selectedID = items[next].id
    }

    func ensureSelection(in items: [ClipboardItem]) {
        if let selectedID, items.contains(where: { $0.id == selectedID }) { return }
        selectedID = items.first?.id
    }
}

/// Управляет плавающей панелью истории. Панель не активирует приложение, поэтому после
/// выбора элемента фокус остаётся в том приложении, где пользователь работал.
@MainActor
final class ClipboardPanelController {
    private unowned let module: ClipboardHistoryModule
    private var panel: FloatingPanel?
    private var keyMonitor: Any?
    /// Приложение, в котором пользователь работал до открытия панели, — туда возвращается фокус.
    private var previousApp: NSRunningApplication?
    let model = ClipboardPanelModel()
    private let overlayID = "clipboard"

    init(module: ClipboardHistoryModule) {
        self.module = module
        // Закрытие из-за другой панели Mac Utilities (снимок, переключатель) не возвращает фокус —
        // его забирает новая панель.
        module.context.overlays.register(overlayID) { [weak self] in self?.hide(restoreFocus: false) }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        model.query = ""
        model.selectedID = nil
        model.ensureSelection(in: model.visibleItems(in: module.store))
        model.focusToken += 1

        let size = NSSize(width: 460, height: 540)
        panel.setFrame(NSRect(origin: origin(for: size), size: size), display: false)
        module.context.overlays.willShow(overlayID)

        // Неактивирующая панель не получает клавиатуру надёжно: активное приложение
        // (например, TextEdit) забирает фокус обратно. Поэтому на время показа панели
        // Mac Utilities становится активным, а после выбора возвращает фокус обратно.
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
            // Запоминаем конкретное окно: с несколькими мониторами активация приложения
            // может поднять другое его окно (на другом экране), и вставка ушла бы не туда.
            previousWindow = frontmost.flatMap { app in
                AXIsProcessTrusted() ? AX.element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute) : nil
            }
        }
        shownAt = Date()
        panel.applyOverlayStyle()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    private var previousWindow: AXUIElement?
    private var shownAt = Date.distantPast

    /// Панель потеряла фокус. Сразу после открытия это побочный эффект активации Mac Utilities
    /// (например, ключевым стало главное окно на другом мониторе) — возвращаем фокус панели.
    /// Позже — пользователь щёлкнул в другое место, панель закрывается.
    private func panelResignedKey() {
        guard isVisible else { return }
        if NSApp.isActive, Date().timeIntervalSince(shownAt) < 0.6 {
            DispatchQueue.main.async { [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                panel.makeKeyAndOrderFront(nil)
            }
            return
        }
        hide()
    }

    /// Закрывает панель. Если панель закрыта клавишей или выбором (Mac Utilities всё ещё
    /// активен) — фокус возвращается в предыдущее приложение. Если пользователь щёлкнул
    /// в другое окно — ничего не трогаем: фокус уже там, куда он щёлкнул.
    func hide(restoreFocus: Bool = true) {
        guard isVisible else { return }
        removeKeyMonitor()
        panel?.orderOut(nil)
        if restoreFocus && NSApp.isActive {
            restorePreviousApp()
        }
    }

    private func restorePreviousApp() {
        guard let app = previousApp, !app.isTerminated else { return }
        NSApp.yieldActivation(to: app)
        app.activate()
        // kAXFrontmost надёжно делает приложение активным даже при кооперативной активации macOS 14+.
        if AXIsProcessTrusted() {
            AX.set(AXUIElementCreateApplication(app.processIdentifier), kAXFrontmostAttribute, kCFBooleanTrue)
            if let window = previousWindow {
                AX.perform(window, kAXRaiseAction)
                AX.set(window, kAXMainAttribute, kCFBooleanTrue)
                AX.set(window, kAXFocusedAttribute, kCFBooleanTrue)
            }
        }
    }

    /// `action` — явное действие (кнопка на строке); nil — действие по умолчанию из настроек.
    func choose(_ item: ClipboardItem, action: ClipboardSelectionAction? = nil) {
        let target = previousApp
        hide()
        let action = action ?? module.settings.selectionAction
        module.restore(item, paste: action == .copyAndPaste, into: target)
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel()
        panel.onCancel = { [weak self] in self?.hide() }
        // Клик в другое место — панель закрывается, как системные всплывающие окна.
        panel.onResignKey = { [weak self] in self?.panelResignedKey() }
        panel.setContent(ClipboardHistoryPanelView(module: module, model: model, controller: self))
        return panel
    }

    private func origin(for size: NSSize) -> NSPoint {
        let screen = NSScreen.withMouse ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin: NSPoint
        switch module.settings.panelPosition {
        case .screenCenter:
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        case .nearMouse:
            let mouse = NSEvent.mouseLocation
            origin = NSPoint(x: mouse.x - 20, y: mouse.y - size.height + 20)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        return origin
    }

    // MARK: - Клавиатура

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Возвращает true, если событие обработано панелью (и не должно идти в поле поиска).
    private func handleKey(_ event: NSEvent) -> Bool {
        let items = model.visibleItems(in: module.store)
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let selected = items.first { $0.id == model.selectedID }

        switch Int(event.keyCode) {
        case kVK_DownArrow:
            model.moveSelection(by: 1, in: items); return true
        case kVK_UpArrow:
            model.moveSelection(by: -1, in: items); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let selected {
                // ⇧↩ — противоположное действие: вставить ↔ только скопировать.
                let action = module.settings.selectionAction
                let opposite: ClipboardSelectionAction = action == .copyAndPaste ? .copyToClipboard : .copyAndPaste
                choose(selected, action: flags.contains(.shift) ? opposite : action)
            }
            return true
        case kVK_Escape:
            if model.query.isEmpty { hide() } else { model.query = "" }
            return true
        case kVK_Delete where flags == .command:
            if let selected {
                model.moveSelection(by: 1, in: items)
                if model.selectedID == selected.id { model.moveSelection(by: -1, in: items) }
                module.delete(selected)
                model.ensureSelection(in: model.visibleItems(in: module.store))
            }
            return true
        case kVK_ANSI_P where flags == .command:
            if let selected { module.store.togglePin(selected.id) }
            return true
        default:
            break
        }

        // ⌘1…⌘9 — быстрый выбор по номеру.
        if flags == .command, let chars = event.charactersIgnoringModifiers, let digit = Int(chars), (1...9).contains(digit) {
            if digit <= items.count { choose(items[digit - 1]) }
            return true
        }
        return false
    }
}
