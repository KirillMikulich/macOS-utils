import SwiftUI

struct ClipboardSettingsView: View {
    @Bindable var module: ClipboardHistoryModule
    @State private var tab = Tab.history

    enum Tab: String, CaseIterable, Identifiable {
        case history = "История"
        case settings = "Настройки"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
            .padding(.vertical, 10)

            switch tab {
            case .history: ClipboardHistoryBrowser(module: module)
            case .settings: ClipboardSettingsForm(module: module)
            }
        }
    }
}

/// Просмотр и управление историей прямо в главном окне.
private struct ClipboardHistoryBrowser: View {
    let module: ClipboardHistoryModule
    @State private var query = ""
    @State private var selection: UUID?

    var body: some View {
        let found = module.store.search(query)
        let items = found.filter(\.isPinned) + found.filter { !$0.isPinned }
        VStack(spacing: 0) {
            HStack {
                TextField("Поиск", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Spacer()
                Text("\(module.store.unpinnedItems.count) из \(module.settings.clampedHistoryLimit) · закреплено \(module.store.pinnedItems.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Menu("Очистить") {
                    Button("Очистить, кроме закреплённых") { module.clearHistory(includingPinned: false) }
                    Button("Удалить всё, включая закреплённые", role: .destructive) { module.clearHistory(includingPinned: true) }
                }
                .fixedSize()
                .disabled(module.store.items.isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            if items.isEmpty {
                ContentUnavailableView(query.isEmpty ? "История пуста" : "Ничего не найдено",
                                       systemImage: "doc.on.clipboard",
                                       description: Text(module.isEnabled ? "Скопируйте что-нибудь — элемент появится здесь." : "Модуль выключен."))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(items) { item in
                        ClipboardItemRow(item: item, module: module, isSelected: false, showsActions: true,
                                         onCopy: { module.restore(item, paste: false) })
                            .tag(item.id)
                            .contextMenu {
                                Button("Скопировать в буфер") { module.restore(item, paste: false) }
                                Button(item.isPinned ? "Открепить" : "Закрепить") { module.store.togglePin(item.id) }
                                Divider()
                                Button("Удалить", role: .destructive) { module.delete(item) }
                            }
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: UUID.self) { _ in } primaryAction: { ids in
                    if let id = ids.first, let item = module.store.item(id) { module.restore(item, paste: false) }
                }
            }
            HStack {
                SettingsCaption(text: "Двойной щелчок — скопировать элемент в буфер. Затем вставьте его обычным ⌘V.")
                Spacer()
            }
            .padding(10)
        }
    }
}

private struct ClipboardSettingsForm: View {
    @Bindable var module: ClipboardHistoryModule
    @State private var customLimit = false

    var body: some View {
        Form {
            Section("Основное") {
                Toggle("Включить историю буфера", isOn: Binding(get: { module.isEnabled }, set: { module.setEnabled($0) }))
                LabeledContent("Открыть панель истории") {
                    ShortcutRecorder(id: .clipboardPanel, combo: $module.settings.shortcut,
                                     defaultCombo: .clipboardPanelDefault, manager: module.context.shortcuts)
                }
                Picker("При выборе элемента", selection: $module.settings.selectionAction) {
                    ForEach(ClipboardSelectionAction.allCases) { Text($0.title).tag($0) }
                }
                if module.settings.selectionAction == .copyAndPaste {
                    if !module.context.permissions.isGranted(.accessibility) {
                        PermissionBanner(kind: .accessibility, permissions: module.context.permissions)
                    }
                    SettingsCaption(text: "Как Win+V в Windows: щелчок или ↩ сразу вставляет элемент в активное окно (отправляется ⌘V). ⇧↩ или кнопка «Скопировать» только кладёт элемент в буфер. Вставка зависит от приложения-получателя: защищённые поля ввода её не принимают.")
                }
                Picker("Положение панели", selection: $module.settings.panelPosition) {
                    ForEach(ClipboardPanelPosition.allCases) { Text($0.title).tag($0) }
                }
            }

            Section("История") {
                Picker("Хранить элементов", selection: limitBinding) {
                    ForEach(ClipboardSettings.presetLimits, id: \.self) { Text("\($0)").tag($0) }
                    Text("Другое…").tag(-1)
                }
                if customLimit || !ClipboardSettings.presetLimits.contains(module.settings.historyLimit) {
                    Stepper(value: $module.settings.historyLimit, in: ClipboardSettings.allowedHistoryLimit, step: 5) {
                        Text("Своё значение: \(module.settings.historyLimit)")
                    }
                }
                SettingsCaption(text: "Лимит действует на незакреплённые элементы: когда он превышен, удаляются самые давно использованные из них. Закреплённые элементы не удаляются ни лимитом, ни сроком хранения, ни корзиной в панели. Повторное копирование того же содержимого не создаёт дубликат — элемент поднимается наверх.")
                Picker("Удалять старше", selection: $module.settings.retentionDays) {
                    Text("Никогда").tag(0)
                    Text("1 дня").tag(1)
                    Text("7 дней").tag(7)
                    Text("30 дней").tag(30)
                    Text("90 дней").tag(90)
                }
            }

            Section("Хранение") {
                Toggle("Сохранять историю между перезапусками", isOn: $module.settings.persistHistory)
                SettingsCaption(text: module.settings.persistHistory
                                ? "История хранится локально: ~/Library/Application Support/Mac Utilities/ClipboardHistory. Данные не шифруются отдельно (защищены шифрованием диска FileVault, если оно включено) и никуда не отправляются."
                                : "История хранится только в памяти и исчезнет при выходе. Файлы на диске удалены.")
                Toggle("Сохранять изображения", isOn: $module.settings.saveImages)
                Picker("Максимальный размер элемента", selection: $module.settings.maxItemSizeMB) {
                    ForEach([5, 10, 25, 50, 100], id: \.self) { Text("\($0) МБ").tag($0) }
                }
            }

            ScreenshotSettingsSection(module: module)

            Section("Приватность") {
                Toggle("Режим приватности (временно не записывать)", isOn: $module.settings.privateMode)
                Toggle("Пропускать данные, помеченные как секретные", isOn: $module.settings.ignoreConcealedContent)
                Toggle("Пропускать временные данные", isOn: $module.settings.ignoreTransientContent)
                SettingsCaption(text: "Многие менеджеры паролей помечают скопированные пароли специальным типом (соглашение nspasteboard.org) — такие данные не записываются. Это не гарантия: приложения, которые не ставят метку, распознать надёжно нельзя. Будьте осторожны с паролями, ключами и кодами — используйте исключения или режим приватности.")
                LabeledContent("Не записывать из приложений") {
                    AppExclusionEditor(bundleIDs: $module.settings.excludedBundleIDs)
                }
            }

            Section("Мониторинг") {
                SliderField(title: "Интервал проверки", value: $module.settings.pollInterval,
                            range: ClipboardSettings.allowedPollInterval, step: 0.05, unit: "с", fractionDigits: 2)
                SettingsCaption(text: "macOS не уведомляет об изменениях буфера, поэтому приложение периодически сравнивает счётчик изменений. Проверка очень дешёвая; меньший интервал — быстрее реакция.")
                if let event = module.lastEvent {
                    LabeledContent("Последнее событие", value: event)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var limitBinding: Binding<Int> {
        Binding(
            get: {
                customLimit || !ClipboardSettings.presetLimits.contains(module.settings.historyLimit) ? -1 : module.settings.historyLimit
            },
            set: { value in
                if value == -1 {
                    customLimit = true
                } else {
                    customLimit = false
                    module.settings.historyLimit = value
                }
            }
        )
    }
}

/// Основные настройки на карточке Dashboard.
struct ClipboardQuickSettingsView: View {
    @Bindable var module: ClipboardHistoryModule

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Хранить", selection: $module.settings.historyLimit) {
                ForEach(Array(Set(ClipboardSettings.presetLimits + [module.settings.historyLimit])).sorted(), id: \.self) {
                    Text("\($0) элементов").tag($0)
                }
            }
            Toggle("Режим приватности", isOn: $module.settings.privateMode)
            Text("В истории: \(module.store.items.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Снимки экрана: попадание в историю и буфер + где macOS их сохраняет.
private struct ScreenshotSettingsSection: View {
    @Bindable var module: ClipboardHistoryModule
    @State private var error: String?
    @State private var applied = false

    var body: some View {
        Section("Снимки экрана") {
            Toggle("Добавлять снимки экрана в историю", isOn: $module.settings.captureScreenshotFiles)
                .disabled(!module.settings.saveImages)
            Toggle("Сразу копировать новый снимок в буфер", isOn: $module.settings.copyScreenshotsToClipboard)
                .disabled(!module.settings.saveImages || !module.settings.captureScreenshotFiles)

            LabeledContent("Отслеживаемые папки") {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(module.screenshots.directories, id: \.self) { url in
                        Button(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                            NSWorkspace.shared.open(url)
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            LabeledContent("Папка и миниатюра") {
                Button("Открыть настройки снимков (⌘⇧5)") { Self.openScreenshotUtility() }
            }
            SettingsCaption(text: "Куда сохранять снимки, выбирается в системной утилите: ⌘⇧5 → «Параметры» → «Сохранить в» → «Другое место…» (например, Документы → Снимки экрана). Там же снимите «Показывать плавающую миниатюру»: пока она видна (~5 с), macOS не сохраняет файл, и снимок попадает в буфер с задержкой. Mac Utilities ловит снимки и на Рабочем столе, и в «Документы/Снимки экрана».")

            if #unavailable(macOS 26) {
                // До macOS 26 папку и миниатюру можно задать напрямую через com.apple.screencapture.
                Button(applied ? "Применено" : "Сохранять в «Документы/Снимки экрана», без миниатюры") {
                    do {
                        try ScreenshotSystemSettings.setLocation(ScreenshotSystemSettings.defaultFolder)
                        ScreenshotSystemSettings.showsThumbnail = false
                        applied = true
                        error = nil
                    } catch {
                        self.error = "Не удалось создать папку: \(error.localizedDescription)"
                    }
                    module.restartScreenshotWatcher()
                }
                .disabled(applied)
            }
            if let message = error ?? module.screenshots.lastError {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        .onAppear {
            // Папка «Документы/Снимки экрана» создаётся заранее, чтобы её можно было выбрать в ⌘⇧5.
            try? FileManager.default.createDirectory(at: ScreenshotSystemSettings.defaultFolder, withIntermediateDirectories: true)
        }
    }

    static func openScreenshotUtility() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
