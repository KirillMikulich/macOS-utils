import AppKit

/// Отслеживает изменения NSPasteboard.
///
/// В macOS нет публичного уведомления «буфер изменился», поэтому используется
/// периодическая проверка `changeCount`: это одно целое число, проверка очень дешёвая.
/// Содержимое читается только когда счётчик изменился. Таймер имеет допуск (tolerance),
/// чтобы система могла объединять пробуждения и экономить энергию.
@MainActor
final class ClipboardMonitor {
    let pasteboard: NSPasteboard
    var onChange: (() -> Void)?

    private var timer: Timer?
    private(set) var lastChangeCount: Int
    private(set) var interval: TimeInterval = 0.5

    var isRunning: Bool { timer != nil }

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
    }

    func start(interval: TimeInterval) {
        if isRunning && interval == self.interval { return }
        stop()
        self.interval = interval
        // То, что лежало в буфере до запуска, не записываем — фиксируем текущий счётчик.
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.checkNow() }
        }
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Log.clipboard.info("Clipboard monitor started (interval \(interval)s)")
    }

    func stop() {
        guard let timer else { return }
        timer.invalidate()
        self.timer = nil
        Log.clipboard.info("Clipboard monitor stopped")
    }

    /// Запись в буфер, сделанная самим приложением, не должна попасть в историю как новая.
    func ignoreChange(upTo changeCount: Int) {
        lastChangeCount = changeCount
    }

    /// Проверяет счётчик; возвращает true, если было изменение и вызван обработчик.
    @discardableResult
    func checkNow() -> Bool {
        guard isRunning else { return false }
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return false }
        lastChangeCount = current
        onChange?()
        return true
    }
}
