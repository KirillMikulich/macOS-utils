import SwiftUI

struct WindowSwitcherSettingsView: View {
    @Bindable var module: WindowSwitcherModule

    var body: some View {
        let permissions = module.context.permissions
        Form {
            Section("Основное") {
                Toggle("Включить переключатель окон", isOn: Binding(get: { module.isEnabled }, set: { module.setEnabled($0) }))
                if module.isEnabled && !permissions.isGranted(.accessibility) {
                    PermissionBanner(kind: .accessibility, permissions: permissions)
                }
                if module.isEnabled && !permissions.isGranted(.screenRecording) {
                    PermissionBanner(kind: .screenRecording, permissions: permissions, isRequired: false)
                }
            }

            Section("Горячие клавиши") {
                Toggle("⌘⇥ открывает переключатель окон (вместо системного)", isOn: $module.settings.replaceCommandTab)
                SettingsCaption(text: "⌘⇥ — следующее окно, ⌘⇧⇥ — предыдущее, отпустите ⌘ — переход. Пока панель открыта: ⌘Q — завершить приложение, ⌘W — закрыть окно, ⌘M — свернуть, стрелки — выбор, Esc — отмена. Системный ⌘⇥ перехватывается только пока Mac Utilities запущена; ⌘` (окна одного приложения) не меняется.")
                if let error = module.commandTabError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                LabeledContent("Следующее окно") {
                    ShortcutRecorder(id: .switcherForward, combo: $module.settings.forwardShortcut,
                                     defaultCombo: .switcherForwardDefault, manager: module.context.shortcuts)
                }
                LabeledContent("Предыдущее окно") {
                    ShortcutRecorder(id: .switcherBackward, combo: $module.settings.backwardShortcut,
                                     defaultCombo: .switcherBackwardDefault, manager: module.context.shortcuts)
                }
                Toggle("Подтверждать выбор отпусканием модификатора", isOn: $module.settings.confirmOnModifierRelease)
                SettingsCaption(text: module.settings.confirmOnModifierRelease
                    ? "Удерживайте модификатор (например, ⌥) и нажимайте ⇥ — отпустите, чтобы переключиться. Пока панель открыта: ←/→/↑/↓ — выбор, ↩ — подтвердить, Esc — отмена, щелчок мышью — выбрать окно."
                    : "Панель остаётся открытой после отпускания модификатора: ←/→/↑/↓ — выбор, ↩ — переключиться, Esc — отмена.")
                SettingsCaption(text: "Дополнительно к ⌘⇥ можно назначить своё сочетание (по умолчанию ⌥⇥) — оно работает всегда.")
            }

            Section("Список окон") {
                Picker("Сортировка", selection: $module.settings.sortOrder) {
                    ForEach(WindowSortOrder.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Группировать по приложениям", isOn: $module.settings.groupByApp)
                Toggle("Показывать свёрнутые окна", isOn: $module.settings.showMinimized)
                Toggle("Показывать окна скрытых приложений", isOn: $module.settings.showHiddenApps)
                Toggle("Только окна с экрана, где курсор", isOn: $module.settings.onlyMouseScreen)
                Picker("После переключения поднять", selection: $module.settings.activationScope) {
                    ForEach(WindowActivationScope.allCases) { Text($0.title).tag($0) }
                }
                SettingsCaption(text: "Ограничение macOS: через публичный API видны окна только текущего рабочего стола (Space). Свёрнутые окна показываются с последней известной миниатюрой или значком приложения.")
            }

            Section("Внешний вид") {
                Picker("Вид", selection: $module.settings.layout) {
                    ForEach(SwitcherLayout.allCases) { Text($0.title).tag($0) }
                }
                SliderField(title: "Непрозрачность фона", value: $module.settings.backgroundOpacity,
                            range: WindowSwitcherSettings.opacityRange, unit: "%", scale: 100)
                Picker("Положение", selection: $module.settings.position) {
                    ForEach(OverlayPosition.allCases) { Text($0.title).tag($0) }
                }
                Picker("Тема панели", selection: $module.settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Выбирать окно наведением мыши", isOn: $module.settings.selectOnHover)
            }

            Section("Размеры и отступы") {
                ThumbnailAppearanceControls(settings: $module.settings)
            }

            Section("Исключения") {
                AppExclusionEditor(bundleIDs: $module.settings.excludedBundleIDs,
                                   emptyText: "Окна всех приложений показываются в переключателе")
            }
        }
        .formStyle(.grouped)
    }
}

struct WindowSwitcherQuickSettingsView: View {
    @Bindable var module: WindowSwitcherModule

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Сортировка", selection: $module.settings.sortOrder) {
                ForEach(WindowSortOrder.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Показывать свёрнутые окна", isOn: $module.settings.showMinimized)
        }
    }
}
