import SwiftUI

struct DockPreviewSettingsView: View {
    @Bindable var module: DockPreviewModule

    var body: some View {
        let permissions = module.context.permissions
        Form {
            Section("Основное") {
                Toggle("Включить Превью в Dock", isOn: Binding(get: { module.isEnabled }, set: { module.setEnabled($0) }))
                if module.isEnabled && !permissions.isGranted(.accessibility) {
                    PermissionBanner(kind: .accessibility, permissions: permissions)
                }
                if module.isEnabled && !permissions.isGranted(.screenRecording) {
                    PermissionBanner(kind: .screenRecording, permissions: permissions, isRequired: false)
                }
                if case .failed(let message) = module.runState {
                    Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
                SettingsCaption(text: "Как это работает: приложение следит за Dock через Accessibility и показывает собственную панель рядом со значком. Системный Dock не изменяется и не заменяется — встроиться в него сторонние приложения не могут. При автоскрытии Dock и увеличении значков панель позиционируется по фактическому положению значка.")
            }

            Section("Поведение") {
                Toggle("Показывать при наведении на значок в Dock", isOn: $module.settings.showOnDockHover)
                Toggle("Только когда курсор остановился на значке", isOn: $module.settings.requireCursorStop)
                    .disabled(!module.settings.showOnDockHover)
                SettingsCaption(text: "Если курсор просто проходит через Dock — даже медленно, — превью не открывается. Задержка ниже отсчитывается до остановки курсора.")
                SliderField(title: "Задержка перед показом", value: $module.settings.hoverDelay,
                            range: DockPreviewSettings.delayRange, step: 0.05, unit: "с", fractionDigits: 2)
                Picker("При выборе окна поднять", selection: $module.settings.activationScope) {
                    ForEach(WindowActivationScope.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Окна активного приложения") {
                    ShortcutRecorder(id: .dockPreviewPanel, combo: $module.settings.panelShortcut,
                                     defaultCombo: .dockPreviewPanelDefault, manager: module.context.shortcuts)
                }
                SettingsCaption(text: "Горячая клавиша открывает ту же панель с окнами текущего активного приложения по центру экрана. Esc или щелчок вне панели — закрыть.")
                SettingsCaption(text: "Кнопки на миниатюре: − свернуть окно, ⏻ завершить приложение со всеми окнами, ✕ закрыть только это окно. Оранжевый ✕ — окно последнее и включён «Автовыход»: после закрытия приложение завершится.")
            }

            Section("Отображение") {
                ThumbnailAppearanceControls(settings: $module.settings)
                Toggle("Название приложения над окнами", isOn: $module.settings.showAppName)
                Toggle("Показывать свёрнутые окна", isOn: $module.settings.showMinimized)
                Toggle("Группировать окна по дисплеям", isOn: $module.settings.groupByDisplay)
                SettingsCaption(text: "Группировка по дисплеям действует, когда подключено больше одного монитора. Свёрнутые окна нельзя захватить заново — показывается последняя миниатюра из текущего сеанса или значок приложения.")
            }

            Section("Исключения") {
                AppExclusionEditor(bundleIDs: $module.settings.excludedBundleIDs,
                                   emptyText: "Предпросмотр показывается для всех приложений")
            }
        }
        .formStyle(.grouped)
    }
}

struct DockPreviewQuickSettingsView: View {
    @Bindable var module: DockPreviewModule

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("При наведении на Dock", isOn: $module.settings.showOnDockHover)
            LabeledContent("Задержка") {
                Text("\(module.settings.hoverDelay, specifier: "%.2f") с")
            }
        }
    }
}
