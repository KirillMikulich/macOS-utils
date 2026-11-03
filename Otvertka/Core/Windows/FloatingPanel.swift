import AppKit
import SwiftUI

/// Неактивирующая плавающая панель: показывается поверх всех окон (включая полноэкранные
/// приложения), не забирает активность у текущего приложения и не появляется в Dock.
/// Может стать key-окном, чтобы получать ввод с клавиатуры (поиск, стрелки, Esc).
final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onResignKey: (() -> Void)?
    var acceptsKey = true

    init(contentRect: NSRect = NSRect(x: 0, y: 0, width: 400, height: 300)) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered,
                   defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// Устанавливает SwiftUI-содержимое.
    /// Тень окна — по настройке оформления панелей.
    @MainActor
    func applyOverlayStyle() {
        hasShadow = OverlayStyle.shared.settings.shadow
        invalidateShadow()
    }

    func setContent<Content: View>(_ view: Content) {
        let hosting = FirstMouseHostingView(rootView: view)
        // Размер панелей задаётся явно (setFrame); содержимое не должно менять размер окна.
        hosting.sizingOptions = []
        contentView = hosting
        MainActor.assumeIsolated { applyOverlayStyle() }
    }

    /// Размер, который предпочитает SwiftUI-содержимое.
    var fittingContentSize: NSSize {
        contentView?.fittingSize ?? frame.size
    }
}

/// Панели не активируют приложение, поэтому первый же щелчок должен срабатывать
/// как нажатие (без него щелчок по неактивному окну только «фокусировал» бы его).
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Гарантирует, что одновременно показана только одна наша оверлей-панель
/// (например, Превью в Dock скрывается, когда открывается Переключение окон).
@MainActor
final class OverlayCoordinator {
    private var hideHandlers: [String: () -> Void] = [:]

    func willShow(_ owner: String) {
        for (key, hide) in hideHandlers where key != owner { hide() }
    }

    func register(_ owner: String, hide: @escaping () -> Void) {
        hideHandlers[owner] = hide
    }

    func unregister(_ owner: String) {
        hideHandlers[owner] = nil
    }
}

extension NSScreen {
    /// Экран, на котором сейчас находится курсор.
    static var withMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(location, $0.frame, false) } ?? main
    }
}
