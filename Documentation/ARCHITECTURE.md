# Архитектура Otvertka

## Структура

```
Otvertka/
  App/                     точка входа, AppDelegate, координатор, строка меню, главное окно
  Core/
    ModuleProtocol.swift   протокол AppModule + общий жизненный цикл
    ModuleRegistry.swift   ModuleContext (общие сервисы) и реестр модулей
    SettingsStore.swift    типизированные JSON-настройки с миграциями
    GeneralSettings.swift  настройки приложения
    KeyCombo.swift         модель сочетания клавиш
    ShortcutManager.swift  глобальные горячие клавиши (Carbon), конфликты
    PermissionManager.swift Accessibility / Screen Recording
    LoginItemService.swift запуск при входе (SMAppService)
    LoggingService.swift   os.Logger по категориям
    Windows/               общие сервисы окон: AX-хелперы, обнаружение, активация,
                           миниатюры (ScreenCaptureKit), плавающая панель
  Modules/
    ClipboardHistory/      модель, чтение/запись NSPasteboard, хранилище, монитор, панель, UI
    WindowSwitcher/        настройки, чистая логика (WindowListBuilder, SwitcherSession), модуль, UI
    DockPreview/           наблюдатель Dock, модуль, UI
  UI/                      главное окно, Dashboard, общие настройки, разрешения, компоненты
  Resources/               Assets.xcassets (иконка)
OtvertkaTests/         XCTest
```

Правило: системная логика, хранение данных и SwiftUI-представления лежат в разных файлах. Чистая логика (`ClipboardContentReader.analyze`, `ClipboardStore`, `WindowListBuilder`, `SwitcherSession`, `SettingsStore`) не зависит от UI и покрыта тестами.

## Жизненный цикл

- Используется AppKit-жизненный цикл (`@main enum OtvertkaMain` → `AppDelegate`), а не SwiftUI `App`: так проще не открывать окно при фоновом запуске, переключать значок в Dock и работать вообще без окон. SwiftUI используется для содержимого окон и панелей (`NSHostingView`).
- `AppCoordinator` создаёт сервисы и модули, применяет общие настройки (Dock, строка меню, тема), открывает главное окно.
- Приложение — агент (`LSUIElement = YES`): по умолчанию нет значка в Dock. Значок включается в настройках (`NSApp.setActivationPolicy(.regular)`).
- При запуске хостом XCTest модули не стартуют (`AppPaths.isRunningTests`).

## Модули

```swift
@MainActor protocol AppModule: AnyObject {
    var id: ModuleID { get }
    var title: String { get }; var summary: String { get }; var systemImage: String { get }
    var isEnabled: Bool { get set }          // хранится в настройках модуля
    var runState: ModuleRunState { get set } // disabled / paused / running / waitingForPermissions / failed
    var context: ModuleContext { get }       // общие сервисы
    var requiredPermissions: [PermissionKind] { get }
    var optionalPermissions: [PermissionKind] { get }
    var shortcuts: [ModuleShortcutInfo] { get }
    func activate() throws   // идемпотентный запуск
    func deactivate()        // полная остановка: таймеры, наблюдатели, клавиши, панели
    func makeSettingsView() -> AnyView
    func makeQuickSettingsView() -> AnyView  // основные настройки для карточки Dashboard
}
```

`start()`, `stop()` и `setEnabled(_:)` реализованы в расширении протокола:

1. выключен → `deactivate()`, состояние `disabled`;
2. глобальная пауза → `deactivate()`, `paused`;
3. нет обязательных разрешений → `deactivate()`, `waitingForPermissions`, `PermissionManager` начинает опрос; когда разрешение появится, реестр перезапустит модуль;
4. иначе `activate()`; исключение → `failed(сообщение)`.

Разрешения запрашиваются только в `setEnabled(true)` — не при запуске приложения.

Общие системные сервисы (`WindowDiscoveryService`, `WindowActivator`, `WindowThumbnailService`, `ShortcutManager`, `PermissionManager`, `OverlayCoordinator`) существуют в одном экземпляре внутри `ModuleContext` и не дублируются модулями. `OverlayCoordinator` гарантирует, что одновременно видна только одна наша панель.

## Настройки

Каждый тип настроек — `struct …: PersistedSettings` со значениями по умолчанию в объявлениях полей:

- файл `Settings/<storageKey>.json` формата `{"schemaVersion": N, "settings": {...}}`;
- при загрузке сохранённый словарь *накладывается* на словарь значений по умолчанию, поэтому новые поля не ломают старые файлы и не требуют ручных `init(from:)`;
- если поле не декодируется (сменился тип), отбрасывается только это поле;
- нечитаемый файл сохраняется как `*.corrupt-*.json`, используются значения по умолчанию;
- миграции: `static let migrations: [Int: (inout [String: Any]) -> Void]` — функция переводит словарь из версии `key` в `key + 1`; после миграции файл перезаписывается.

Модуль хранит настройки в `var settings` с `didSet`, который сохраняет файл и применяет изменения к работающему модулю. Состояние SwiftUI не является источником истины.

## Горячие клавиши

`ShortcutManager` использует Carbon `RegisterEventHotKey`: он не требует разрешений и не перехватывает все нажатия (в отличие от `CGEventTap`). Модуль объявляет сочетание через `update(id, title, combo, active, handler)` при каждом запуске, остановке и изменении настроек. Менеджер:

- регистрирует только активные сочетания и не регистрирует одно и то же повторно;
- определяет конфликты между действиями (детерминированно: побеждает меньший `ShortcutID`), известные системные сочетания и сочетания без модификаторов;
- на время записи нового сочетания снимает все регистрации (`isSuspended`);
- даёт *временные* сочетания (`registerTemporary`) — стрелки, ↩, Esc на время показа переключателя окон, чтобы панели не нужно было забирать фокус клавиатуры.

## Clipboard History

- `ClipboardMonitor` опрашивает `NSPasteboard.changeCount` (интервал 0,2–3 с, по умолчанию 0,5 с, таймер с tolerance) — в macOS нет уведомления об изменении буфера. Содержимое читается только при изменении счётчика.
- `ClipboardContentReader` читает **все** представления каждого `NSPasteboardItem` без изменения буфера, пропускает file promises, данные с маркерами nspasteboard.org (`ConcealedType`, `TransientType`, …) и слишком крупные элементы. Классификация: файлы → изображение (если нет содержательного текста) → ссылка → форматированный текст → текст → изображение → другое.
- Дедупликация по SHA-256 «канонических» данных типа (текст, байты изображения, пути файлов…). Дубликат поднимает существующую запись наверх.
- `ClipboardStore`: порядок по времени последнего использования; лимит действует только на незакреплённые элементы — при превышении удаляются самые давно использованные незакреплённые; срок хранения тоже не трогает закреплённые.
- `ClipboardStorage`: `FileClipboardStorage` (индекс JSON + бинарные файлы, запись на фоновой очереди) или `MemoryClipboardStorage` (режим без сохранения). Переключение переносит данные и удаляет файлы.
- `ClipboardContentWriter` восстанавливает все представления; собственная запись не попадает в историю (`ignoreChange(upTo:)`).
- Панель — `FloatingPanel` (неактивирующая `NSPanel`): фокус остаётся у приложения пользователя, поэтому после выбора можно сразу нажать ⌘V. Автовставка отправляет ⌘V через `CGEvent` и требует Accessibility.

## Window Switcher и Dock Preview

- `WindowDiscoveryService` перечисляет окна через AX (`kAXWindowsAttribute` каждого обычного приложения, таймаут 0,25 с на приложение, параллельно) и берёт порядок по глубине из `CGWindowListCopyWindowInfo`. `CGWindowID` для миниатюр получается через недокументированную `_AXUIElementGetWindow` (загружается через `dlsym`, при отсутствии — сопоставление по рамке).
- `WindowActivator`: снимает свёрнутость, делает приложение frontmost через `kAXFrontmostAttribute`, поднимает окно (`kAXRaiseAction`) и делает его главным.
- `WindowThumbnailService`: `SCScreenshotManager` по `SCContentFilter(desktopIndependentWindow:)`, только при выданном Screen Recording (без системного запроса), кэш `NSCache` в памяти, последняя миниатюра используется для свёрнутых окон.
- `DockObserver`: `AXObserver` на `AXList` процесса Dock, уведомление `kAXSelectedChildrenChangedNotification`; переподключение после перезапуска Dock.

## Как добавить новый модуль

1. Добавьте случай в `ModuleID` (`Core/ModuleProtocol.swift`).
2. Создайте папку `Otvertka/Modules/<Name>/` (Xcode подхватит файлы автоматически).
3. Настройки:
   ```swift
   struct MyToolSettings: PersistedSettings {
       static let storageKey = "myTool"
       static let defaultValue = MyToolSettings()
       var isEnabled = false
       var shortcut: KeyCombo? = nil
   }
   ```
4. Модуль:
   ```swift
   @MainActor @Observable
   final class MyToolModule: AppModule {
       let id = ModuleID.myTool
       let title = "My Tool"; let summary = "…"; let systemImage = "wand.and.stars"
       let requiredPermissions: [PermissionKind] = []
       let context: ModuleContext
       var runState: ModuleRunState = .disabled
       var settings: MyToolSettings {
           didSet { guard settings != oldValue else { return }
                    context.settingsStore.save(settings)
                    if settings.isEnabled == oldValue.isEnabled, runState == .running { try? activate() } }
       }
       var isEnabled: Bool { get { settings.isEnabled } set { settings.isEnabled = newValue } }
       var shortcuts: [ModuleShortcutInfo] { [] }

       init(context: ModuleContext) {
           self.context = context
           settings = context.settingsStore.load(MyToolSettings.self)
       }
       func activate() throws { /* таймеры, наблюдатели, context.shortcuts.update(..., active: true) */ }
       func deactivate() { /* освободить всё, что создал activate() */ }
       func makeSettingsView() -> AnyView { AnyView(MyToolSettingsView(module: self)) }
       func makeQuickSettingsView() -> AnyView { AnyView(EmptyView()) }
   }
   ```
5. Зарегистрируйте модуль в `AppCoordinator.init`: `registry.register(MyToolModule(context: context))`. Он автоматически появится в боковой панели, на Dashboard, в меню строки меню и в разделе «Разрешения».
6. Чистую логику вынесите в отдельный тип и покройте тестами в `OtvertkaTests/`.
