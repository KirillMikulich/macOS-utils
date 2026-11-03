import Foundation

/// Восстановление автоскрытия Dock.
///
/// В версиях 0.2–0.4 была опция «Не скрывать Dock, пока открыт предпросмотр»: она временно
/// выключала автоскрытие недокументированной функцией CoreDock, из-за чего у части
/// пользователей под Dock появлялась чёрная полоса. Опция удалена. Здесь осталась только
/// защита: если автоскрытие было выключено Mac Utilities и не вернулось (например, после сбоя),
/// оно восстанавливается при запуске.
enum DockAutoHideController {
    private typealias SetFunction = @convention(c) (Bool) -> Void
    private static let suspendedKey = "DockPreview.autoHideSuspended"

    static func recoverIfNeeded() {
        guard UserDefaults.standard.bool(forKey: suspendedKey) else { return }
        UserDefaults.standard.removeObject(forKey: suspendedKey)
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "CoreDockSetAutoHideEnabled") else { return }
        unsafeBitCast(symbol, to: SetFunction.self)(true)
        Log.dock.info("Restored Dock auto-hide left disabled by an earlier version")
    }
}
