import SwiftUI

struct WindowSwitcherSettingsView: View {
    @Bindable var module: WindowSwitcherModule

    var body: some View {
        let permissions = module.context.permissions
        Form {
            Section(L("Основное")) {
                Toggle(L("Включить переключатель окон"), isOn: Binding(get: { module.isEnabled }, set: { module.setEnabled($0) }))
                if module.isEnabled && !permissions.isGranted(.accessibility) {
                    PermissionBanner(kind: .accessibility, permissions: permissions)
                }
                if module.isEnabled && !permissions.isGranted(.screenRecording) {
                    PermissionBanner(kind: .screenRecording, permissions: permissions, isRequired: false)
                }
            }

            Section(L("Горячие клавиши")) {
                Toggle(L("⌘⇥ открывает переключатель окон (вместо системного)"), isOn: $module.settings.replaceCommandTab)
                SettingsCaption(text: L("⌘⇥ — следующее окно, ⌘⇧⇥ — предыдущее, отпустите ⌘ — переход. Пока панель открыта: ⌘Q — завершить приложение, ⌘W — закрыть окно, ⌘M — свернуть, стрелки — выбор, Esc — отмена. Системный ⌘⇥ перехватывается только пока Mac Utilities запущена; ⌘` (окна одного приложения) не меняется."))
                if let error = module.commandTabError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                LabeledContent(L("Следующее окно")) {
                    ShortcutRecorder(id: .switcherForward, combo: $module.settings.forwardShortcut,
                                     defaultCombo: .switcherForwardDefault, manager: module.context.shortcuts)
                }
                LabeledContent(L("Предыдущее окно")) {
                    ShortcutRecorder(id: .switcherBackward, combo: $module.settings.backwardShortcut,
                                     defaultCombo: .switcherBackwardDefault, manager: module.context.shortcuts)
                }
                Toggle(L("Подтверждать выбор отпусканием модификатора"), isOn: $module.settings.confirmOnModifierRelease)
                SettingsCaption(text: module.settings.confirmOnModifierRelease
                    ? L("Удерживайте модификатор (например, ⌥) и нажимайте ⇥ — отпустите, чтобы переключиться. Пока панель открыта: ←/→/↑/↓ — выбор, ↩ — подтвердить, Esc — отмена, щелчок мышью — выбрать окно.")
                    : L("Панель остаётся открытой после отпускания модификатора: ←/→/↑/↓ — выбор, ↩ — переключиться, Esc — отмена."))
                SettingsCaption(text: L("Дополнительно к ⌘⇥ можно назначить своё сочетание (по умолчанию ⌥⇥) — оно работает всегда."))
            }

            Section(L("Список окон")) {
                Picker(L("Сортировка"), selection: $module.settings.sortOrder) {
                    ForEach(WindowSortOrder.allCases) { Text($0.title).tag($0) }
                }
                Toggle(L("Группировать по приложениям"), isOn: $module.settings.groupByApp)
                Toggle(L("Показывать свёрнутые окна"), isOn: $module.settings.showMinimized)
                Toggle(L("Показывать окна скрытых приложений"), isOn: $module.settings.showHiddenApps)
                Toggle(L("Только окна с экрана, где курсор"), isOn: $module.settings.onlyMouseScreen)
                Picker(L("После переключения поднять"), selection: $module.settings.activationScope) {
                    ForEach(WindowActivationScope.allCases) { Text($0.title).tag($0) }
                }
                SettingsCaption(text: L("Ограничение macOS: через публичный API видны окна только текущего рабочего стола (Space). Свёрнутые окна показываются с последней известной миниатюрой или значком приложения."))
            }

            Section(L("Внешний вид")) {
                Picker(L("Вид"), selection: $module.settings.layout) {
                    ForEach(SwitcherLayout.allCases) { Text($0.title).tag($0) }
                }
                SliderField(title: L("Непрозрачность фона"), value: $module.settings.backgroundOpacity,
                            range: WindowSwitcherSettings.opacityRange, unit: "%", scale: 100)
                Picker(L("Положение"), selection: $module.settings.position) {
                    ForEach(OverlayPosition.allCases) { Text($0.title).tag($0) }
                }
                Picker(L("Тема панели"), selection: $module.settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle(L("Выбирать окно наведением мыши"), isOn: $module.settings.selectOnHover)
            }

            Section(L("Размеры и отступы")) {
                ThumbnailAppearanceControls(settings: $module.settings)
            }

            Section(L("Исключения")) {
                AppExclusionEditor(bundleIDs: $module.settings.excludedBundleIDs,
                                   emptyText: L("Окна всех приложений показываются в переключателе"))
            }
        }
        .formStyle(.grouped)
    }
}

struct WindowSwitcherQuickSettingsView: View {
    @Bindable var module: WindowSwitcherModule

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(L("Сортировка"), selection: $module.settings.sortOrder) {
                ForEach(WindowSortOrder.allCases) { Text($0.title).tag($0) }
            }
            Toggle(L("Показывать свёрнутые окна"), isOn: $module.settings.showMinimized)
        }
    }
}
