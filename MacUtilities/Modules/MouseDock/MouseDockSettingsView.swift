import SwiftUI

struct MouseDockSettingsView: View {
    @Bindable var module: MouseDockModule

    var body: some View {
        Form {
            Section {
                Toggle(L("Включить «Мышь и Dock»"), isOn: Binding(get: { module.isEnabled }, set: { module.setEnabled($0) }))
                SettingsCaption(text: L("Главный переключатель: включает всё, что отмечено ниже. При выключении колесо работает как обычно, а Dock возвращается к вашим прежним настройкам."))
            }

            Section(L("Колесо мыши")) {
                Toggle(L("Плавная прокрутка"), isOn: $module.settings.wheel.smooth)
                Toggle(L("Обратное направление по вертикали"), isOn: $module.settings.wheel.reverseVertical)
                Toggle(L("Обратное направление по горизонтали"), isOn: $module.settings.wheel.reverseHorizontal)
                if module.settings.wheel.smooth {
                    SliderField(title: L("Шаг щелчка"), value: $module.settings.wheel.smoothStep,
                                range: WheelSettings.smoothStepRange, step: 0.1, fractionDigits: 1)
                    SliderField(title: L("Скорость"), value: $module.settings.wheel.smoothSpeed,
                                range: WheelSettings.smoothSpeedRange, step: 0.05, fractionDigits: 2)
                    SliderField(title: L("Длительность доката"), value: $module.settings.wheel.smoothDuration,
                                range: WheelSettings.smoothDurationRange, step: 0.05, fractionDigits: 2)
                    HStack {
                        Spacer()
                        Button(L("Сбросить по умолчанию")) {
                            module.settings.wheel.smoothStep = 33.6
                            module.settings.wheel.smoothSpeed = 2.7
                            module.settings.wheel.smoothDuration = 4.35
                        }
                    }
                    Toggle(L("⌥ + колесо — быстрая прокрутка (×3)"), isOn: $module.settings.wheel.fastScrollWithOption)
                    LabeledContent(L("Без плавности в приложениях")) {
                        AppExclusionEditor(bundleIDs: $module.settings.wheel.excludedBundleIDs,
                                           emptyText: L("Плавно во всех приложениях"))
                    }
                }
                if module.isEnabled && module.wheelActive && !module.context.permissions.isGranted(.accessibility) {
                    PermissionBanner(kind: .accessibility, permissions: module.context.permissions)
                }
                if module.isEnabled && module.wheelActive, let other = Self.conflictingScrollApp {
                    Label(L("Запущен \(other) — он тоже управляет колесом мыши. Два таких приложения одновременно мешают друг другу: закройте \(other) или выключите здесь плавность и направление."),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if let error = module.wheelError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                SettingsCaption(text: L("Только для колеса мыши — трекпад и Magic Mouse не затрагиваются. Докат остаётся в том окне и панели, где начали крутить. С ⌘ или ⌃ (масштаб) колесо работает как обычно."))
                HStack(spacing: 4) {
                    Text(L("Плавная прокрутка перенесена из Mos, автор — Caldis (CC BY-NC 4.0):"))
                        .font(.caption).foregroundStyle(.secondary)
                    Link("github.com/Caldis/Mos", destination: URL(string: "https://github.com/Caldis/Mos")!)
                        .font(.caption)
                }
            }
            .disabled(!module.isEnabled)

            Section("Dock") {
                Toggle(L("Быстрое появление Dock (при автоскрытии)"), isOn: $module.settings.dockTweaksEnabled)
                if module.settings.dockTweaksEnabled {
                    SliderField(title: L("Пауза перед появлением"), value: $module.settings.dockDelay,
                                range: MouseDockSettings.delayRange, step: 0.05, unit: L("с"), fractionDigits: 2)
                    SliderField(title: L("Анимация выезда"), value: $module.settings.dockAnimation,
                                range: MouseDockSettings.animationRange, step: 0.05, unit: L("с"), fractionDigits: 2)
                    HStack {
                        Button(L("Мгновенно")) { module.settings.dockDelay = 0; module.settings.dockAnimation = 0 }
                        Button(L("Быстро")) { module.settings.dockDelay = 0; module.settings.dockAnimation = 0.25 }
                        Button(L("Как в системе")) { module.settings.dockDelay = 0.5; module.settings.dockAnimation = 1 }
                    }
                    if !Self.isDockAutohideEnabled {
                        Label(L("Автоскрытие Dock выключено — эти настройки действуют только при автоскрытии (Системные настройки → Рабочий стол и Dock)."),
                              systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                SettingsCaption(text: L("Значения записываются в настройки Dock и действуют, даже когда Mac Utilities не запущена. При применении Dock на мгновение перезапускается — окна не закрываются. Выключите, чтобы вернуть прежние значения."))
            }
            .disabled(!module.isEnabled)

            Section(L("Указатель")) {
                LabeledContent(L("Ускорение указателя")) {
                    Text(module.isPointerLinear ? L("Выключено — курсор движется линейно") : L("Включено (стандарт macOS)"))
                        .foregroundStyle(.secondary)
                }
                Button(L("Открыть настройки мыши")) { module.openMouseSettings() }
                SettingsCaption(text: L("Ускорение и скорость указателя меняются в Системных настройках → Мышь: применить их на лету может только сама macOS."))
            }
        }
        .formStyle(.grouped)
    }


    /// Другие утилиты, которые тоже перехватывают колесо мыши.
    static var conflictingScrollApp: String? {
        let known = ["com.caldis.Mos": "Mos", "com.pilotmoon.scroll-reverser": "Scroll Reverser",
                     "com.lujjjh.LinearMouse": "LinearMouse", "com.galvanizedlogic.SmoothScroll": "SmoothScroll"]
        return NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier.flatMap { known[$0] } }.first
    }

    static var isDockAutohideEnabled: Bool {
        (CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) as? Bool) ?? false
    }
}

struct MouseDockQuickSettingsView: View {
    @Bindable var module: MouseDockModule

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(L("Плавная прокрутка колесом"), isOn: $module.settings.wheel.smooth)
            Toggle(L("Быстрое появление Dock"), isOn: $module.settings.dockTweaksEnabled)
        }
    }
}
