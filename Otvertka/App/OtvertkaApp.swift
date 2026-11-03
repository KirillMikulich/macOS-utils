import AppKit

/// Точка входа. Используется жизненный цикл AppKit (а не SwiftUI `App`), потому что
/// приложению нужно полностью управлять главным окном: не открывать его при фоновом
/// запуске, переключать значок в Dock и работать без окон вообще.
@main
enum OtvertkaMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
