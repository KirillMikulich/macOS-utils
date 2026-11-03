import XCTest
@testable import MacUtilities

/// Тестовая модель с миграцией: в v1 поле называлось `size`, в v2 — `thumbnailSize`.
private struct MigratingSettings: PersistedSettings {
    static let storageKey = "migrating"
    static let schemaVersion = 2
    static let defaultValue = MigratingSettings()
    static let migrations: [Int: (inout [String: Any]) -> Void] = [
        1: { dict in
            if let size = dict.removeValue(forKey: "size") { dict["thumbnailSize"] = size }
        },
    ]

    var thumbnailSize = 100.0
    var title = "default"
}

final class SettingsStoreTests: XCTestCase {
    private var directory: URL!
    private var store: SettingsStore!

    override func setUp() {
        directory = TestSupport.temporaryDirectory()
        store = SettingsStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDefaultsWhenFileMissing() {
        let settings = store.load(ClipboardSettings.self)
        XCTAssertEqual(settings, ClipboardSettings.defaultValue)
        XCTAssertEqual(settings.historyLimit, 20)
        XCTAssertEqual(settings.shortcut, .clipboardPanelDefault)
        XCTAssertEqual(store.lastOutcome[ClipboardSettings.storageKey], .defaults)
    }

    func testSaveAndRestore() {
        var settings = ClipboardSettings.defaultValue
        settings.historyLimit = 50
        settings.privateMode = true
        settings.shortcut = KeyCombo(keyCode: 9, modifiers: [.command, .shift])
        settings.excludedBundleIDs = ["com.example.secret"]
        store.save(settings)

        let restored = SettingsStore(directory: directory).load(ClipboardSettings.self)
        XCTAssertEqual(restored, settings)
    }

    func testMissingFieldsGetDefaults() throws {
        // Файл от «старой версии», где было только одно поле.
        let json = #"{"schemaVersion":1,"settings":{"historyLimit":77}}"#
        try json.write(to: store.fileURL(for: ClipboardSettings.self), atomically: true, encoding: .utf8)

        let settings = store.load(ClipboardSettings.self)
        XCTAssertEqual(settings.historyLimit, 77)
        XCTAssertEqual(settings.pollInterval, ClipboardSettings.defaultValue.pollInterval)
        XCTAssertEqual(settings.isEnabled, true)
    }

    func testCorruptedFileFallsBackToDefaultsAndKeepsBackup() throws {
        try "{ this is not json".write(to: store.fileURL(for: ClipboardSettings.self), atomically: true, encoding: .utf8)

        let settings = store.load(ClipboardSettings.self)
        XCTAssertEqual(settings, ClipboardSettings.defaultValue)
        XCTAssertEqual(store.lastOutcome[ClipboardSettings.storageKey], .recoveredFromCorruption)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(files.contains { $0.contains("corrupt") })
    }

    func testInvalidFieldIsDroppedOthersKept() throws {
        let json = #"{"schemaVersion":1,"settings":{"historyLimit":"many","privateMode":true}}"#
        try json.write(to: store.fileURL(for: ClipboardSettings.self), atomically: true, encoding: .utf8)

        let settings = store.load(ClipboardSettings.self)
        XCTAssertEqual(settings.historyLimit, 20, "некорректное значение заменяется значением по умолчанию")
        XCTAssertTrue(settings.privateMode, "корректные поля сохраняются")
        XCTAssertEqual(store.lastOutcome[ClipboardSettings.storageKey], .partiallyRecovered(droppedKeys: ["historyLimit"]))
    }

    func testMigration() throws {
        let json = #"{"schemaVersion":1,"settings":{"size":240,"title":"old"}}"#
        try json.write(to: store.fileURL(for: MigratingSettings.self), atomically: true, encoding: .utf8)

        let settings = store.load(MigratingSettings.self)
        XCTAssertEqual(settings.thumbnailSize, 240)
        XCTAssertEqual(settings.title, "old")
        XCTAssertEqual(store.lastOutcome[MigratingSettings.storageKey], .migrated(from: 1))

        // После миграции файл переписан в новой версии.
        let data = try Data(contentsOf: store.fileURL(for: MigratingSettings.self))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(root?["schemaVersion"] as? Int, 2)
    }

    func testClipboardMigrationSwitchesToPasteOnSelect() throws {
        let json = #"{"schemaVersion":1,"settings":{"selectionAction":"copyToClipboard","historyLimit":50}}"#
        try json.write(to: store.fileURL(for: ClipboardSettings.self), atomically: true, encoding: .utf8)
        let settings = store.load(ClipboardSettings.self)
        XCTAssertEqual(settings.selectionAction, .copyAndPaste)
        XCTAssertEqual(settings.historyLimit, 50)
        XCTAssertEqual(store.lastOutcome[ClipboardSettings.storageKey], .migrated(from: 1))
    }

    func testModulesAreStoredIndependently() {
        var clipboard = ClipboardSettings.defaultValue
        clipboard.isEnabled = false
        store.save(clipboard)

        var switcher = WindowSwitcherSettings.defaultValue
        switcher.isEnabled = true
        store.save(switcher)

        XCTAssertFalse(store.load(ClipboardSettings.self).isEnabled)
        XCTAssertTrue(store.load(WindowSwitcherSettings.self).isEnabled)
        XCTAssertFalse(store.load(DockPreviewSettings.self).isEnabled)
        XCTAssertNotEqual(store.fileURL(for: ClipboardSettings.self), store.fileURL(for: WindowSwitcherSettings.self))
    }

    func testGeneralSettingsRoundTrip() {
        var general = GeneralSettings.defaultValue
        general.showDockIcon = true
        general.appearance = .dark
        store.save(general)
        XCTAssertEqual(SettingsStore(directory: directory).load(GeneralSettings.self), general)
    }
}

@MainActor
final class LocalizationTests: XCTestCase {
    override func tearDown() {
        Localization.shared.language = .english
        super.tearDown()
    }

    func testEnglishTranslationIsLoadedAndApplied() {
        Localization.shared.language = .english
        XCTAssertTrue(Localization.shared.hasEnglish("Основные"))
        XCTAssertEqual(L("Основные"), "General")
        Localization.shared.language = .russian
        XCTAssertEqual(L("Основные"), "Основные")
    }

    func testInterpolatedArgumentsAreSubstitutedInOrder() {
        Localization.shared.language = .russian
        let running = 3, total = 7
        XCTAssertEqual(L("Работает модулей: \(running) из \(total)"), "Работает модулей: 3 из 7")
    }

    func testDefaultLanguageIsEnglish() {
        XCTAssertEqual(GeneralSettings().language, .english)
    }
}
