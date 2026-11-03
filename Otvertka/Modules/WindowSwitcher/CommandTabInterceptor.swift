import AppKit
import Carbon.HIToolbox

/// Перехват системного ⌘⇥ (и ⌘⇧⇥) для переключателя окон.
///
/// Почему не Carbon: ⌘⇥ обрабатывает сама macOS (Dock) раньше, чем срабатывают
/// RegisterEventHotKey-сочетания. Перехватить его можно только CGEventTap — активным
/// «перехватчиком событий» сеанса (так же делает AltTab). Нужен доступ Accessibility.
///
/// Перехватываются ТОЛЬКО нажатия Tab при зажатой ⌘ без ⌃ и ⌥; остальные события
/// проходят без изменений. При выключении опции или выходе из Mac Utilities системный
/// переключатель приложений снова работает.
@MainActor
final class CommandTabInterceptor {
    /// Вызывается на главном потоке: true — с ⇧ (назад).
    var onCommandTab: ((Bool) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var lastError: String?

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let interceptor = Unmanaged<CommandTabInterceptor>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated { interceptor.handle(type: type, event: event) }
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            lastError = "Не удалось перехватить ⌘⇥ — проверьте доступ «Универсальный доступ»"
            Log.shortcuts.error("CGEvent.tapCreate failed")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        lastError = nil
        Log.shortcuts.info("Command-Tab interceptor started")
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        Log.shortcuts.info("Command-Tab interceptor stopped")
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS отключает «медленные» перехватчики — включаем обратно.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp,
              event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Tab) else {
            return Unmanaged.passUnretained(event)
        }
        let flags = event.flags
        guard flags.contains(.maskCommand), !flags.contains(.maskControl), !flags.contains(.maskAlternate) else {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown {
            onCommandTab?(flags.contains(.maskShift))
        }
        // Событие поглощается — системный переключатель приложений не появляется.
        return nil
    }
}
