import SwiftUI

struct GeneralSettingsView: View {
    let coordinator: AppCoordinator
    @Bindable private var appSettings: AppSettingsModel
    private let loginItem: LoginItemService

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.appSettings = coordinator.appSettings
        self.loginItem = coordinator.loginItem
    }

    var body: some View {
        Form {
            Section(L("Запуск")) {
                Toggle(L("Запускать при входе в систему"),
                       isOn: Binding(get: { loginItem.isEnabled || loginItem.requiresApproval },
                                     set: { loginItem.setEnabled($0) }))
                LabeledContent(L("Состояние"), value: loginItem.statusDescription)
                if loginItem.requiresApproval {
                    Button(L("Открыть «Объекты входа»")) { loginItem.openSystemSettings() }
                }
                if let error = loginItem.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                Toggle(L("Открывать это окно при запуске"), isOn: $appSettings.general.openMainWindowAtLaunch)
                SettingsCaption(text: L("Если выключено, приложение запускается в фоне — модули работают, окно не появляется."))
                Toggle(L("Автоматически запускать включённые модули"), isOn: $appSettings.general.restoreModulesOnLaunch)
                SettingsCaption(text: L("Если выключено, после запуска все модули на паузе до команды «Возобновить» в строке меню."))
            }

            Section(L("Отображение")) {
                Toggle(L("Значок в строке меню"), isOn: $appSettings.general.showMenuBarIcon)
                Toggle(L("Значок в Dock"), isOn: $appSettings.general.showDockIcon)
                if !appSettings.general.showMenuBarIcon && !appSettings.general.showDockIcon {
                    SettingsCaption(text: L("Оба значка скрыты. Чтобы открыть настройки, запустите Mac Utilities ещё раз из Finder или Launchpad."))
                }
                Picker(L("Тема"), selection: $appSettings.general.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                // Названия языков — на самих языках, чтобы найти переключатель при любом текущем.
                Picker(appSettings.general.language == .english ? "Language" : L("Язык") + " · Language", selection: $appSettings.general.language) {
                    ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0) }
                }
            }

            Section(L("Оформление панелей")) {
                OverlayStylePreview()
                Picker(L("Тема"), selection: $appSettings.general.overlay.theme) {
                    ForEach(OverlayStyleSettings.Theme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent(L("Цвет выделения")) {
                    HStack(spacing: 6) {
                        ForEach(OverlayStyleSettings.Accent.allCases) { accent in
                            Button { appSettings.general.overlay.accent = accent } label: {
                                Circle()
                                    .fill(accent == .system ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(accent.color.gradient))
                                    .frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(appSettings.general.overlay.accent == accent ? Color.primary : .clear, lineWidth: 2).padding(-3))
                            }
                            .buttonStyle(.plain)
                            .help(accent.title)
                        }
                    }
                }
                SliderField(title: L("Скругление углов"), value: $appSettings.general.overlay.cornerRadius,
                            range: OverlayStyleSettings.cornerRadiusRange, step: 1, unit: "pt")
                Toggle(L("Тень под панелями"), isOn: $appSettings.general.overlay.shadow)
                SettingsCaption(text: L("Применяется к истории буфера, переключателю окон и превью в Dock."))
            }

            Section(L("Модули")) {
                ForEach(coordinator.registry.modules, id: \.id) { module in
                    Toggle(module.title, isOn: Binding(get: { module.isEnabled }, set: { module.setEnabled($0) }))
                }
                Button(coordinator.registry.isPaused ? L("Возобновить все модули") : L("Приостановить все модули")) {
                    coordinator.registry.setPaused(!coordinator.registry.isPaused)
                }
            }

            Section(L("Данные")) {
                LabeledContent(L("Папка данных")) {
                    Button(L("Показать в Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.supportDirectory])
                    }
                }
                SettingsCaption(text: L("Настройки и история хранятся только на этом Mac в ~/Library/Application Support/Mac Utilities. Приложение не использует сеть."))
            }

            Section {
                Button(L("Завершить Mac Utilities"), role: .destructive) { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
    }
}

/// Маленький пример панели с текущим оформлением.
private struct OverlayStylePreview: View {
    var body: some View {
        let style = OverlayStyle.shared
        HStack(spacing: 8) {
            ForEach(0..<3) { index in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.quaternary)
                        .frame(width: 70, height: 44)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.secondary.opacity(0.5))
                        .frame(width: 50, height: 5)
                }
                .padding(6)
                .background(index == 1 ? style.accent.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(index == 1 ? style.accent : .clear, lineWidth: 2))
            }
        }
        .padding(12)
        .background(OverlayBackground(opacity: 1))
        .shadow(color: .black.opacity(style.settings.shadow ? 0.25 : 0), radius: 10, y: 4)
        .overlayStyled()
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .allowsHitTesting(false)
    }
}
