import SwiftUI

struct MouseDockSettingsView: View {
    @Bindable var module: MouseDockModule

    var body: some View {
        Form {
            Section {
                Toggle("Включить «Мышь и Dock»", isOn: Binding(get: { module.isEnabled }, set: { module.setEnabled($0) }))
                SettingsCaption(text: "Главный переключатель: включает всё, что отмечено ниже. При выключении колесо работает как обычно, а Dock возвращается к вашим прежним настройкам.")
            }

            Section("Колесо мыши") {
                Toggle("Плавная прокрутка", isOn: $module.settings.wheel.smooth)
                Toggle("Обратное направление по вертикали", isOn: $module.settings.wheel.reverseVertical)
                Toggle("Обратное направление по горизонтали", isOn: $module.settings.wheel.reverseHorizontal)
                if module.settings.wheel.smooth {
                    SliderField(title: "Шаг щелчка", value: $module.settings.wheel.smoothStep,
                                range: WheelSettings.smoothStepRange, step: 0.1, fractionDigits: 1)
                    SliderField(title: "Скорость", value: $module.settings.wheel.smoothSpeed,
                                range: WheelSettings.smoothSpeedRange, step: 0.05, fractionDigits: 2)
                    SliderField(title: "Длительность доката", value: $module.settings.wheel.smoothDuration,
                                range: WheelSettings.smoothDurationRange, step: 0.05, fractionDigits: 2)
                    HStack {
                        Spacer()
                        Button("Сбросить по умолчанию") {
                            module.settings.wheel.smoothStep = 33.6
                            module.settings.wheel.smoothSpeed = 2.7
                            module.settings.wheel.smoothDuration = 4.35
                        }
                    }
                    Toggle("⌥ + колесо — быстрая прокрутка (×3)", isOn: $module.settings.wheel.fastScrollWithOption)
                    LabeledContent("Без плавности в приложениях") {
                        AppExclusionEditor(bundleIDs: $module.settings.wheel.excludedBundleIDs,
                                           emptyText: "Плавно во всех приложениях")
                    }
                }
                if module.isEnabled && module.wheelActive && !module.context.permissions.isGranted(.accessibility) {
                    PermissionBanner(kind: .accessibility, permissions: module.context.permissions)
                }
                if module.isEnabled && module.wheelActive, let other = Self.conflictingScrollApp {
                    Label("Запущен \(other) — он тоже управляет колесом мыши. Два таких приложения одновременно мешают друг другу: закройте \(other) или выключите здесь плавность и направление.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if let error = module.wheelError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                SettingsCaption(text: "Только для колеса мыши — трекпад и Magic Mouse не затрагиваются. Докат остаётся в том окне и панели, где начали крутить. С ⌘ или ⌃ (масштаб) колесо работает как обычно.")
                HStack(spacing: 4) {
                    Text("Плавная прокрутка перенесена из Mos, автор — Caldis (CC BY-NC 4.0):")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("github.com/Caldis/Mos", destination: URL(string: "https://github.com/Caldis/Mos")!)
                        .font(.caption)
                }
            }
            .disabled(!module.isEnabled)

            Section("Dock") {
                Toggle("Быстрое появление Dock (при автоскрытии)", isOn: $module.settings.dockTweaksEnabled)
                if module.settings.dockTweaksEnabled {
                    SliderField(title: "Пауза перед появлением", value: $module.settings.dockDelay,
                                range: MouseDockSettings.delayRange, step: 0.05, unit: "с", fractionDigits: 2)
                    SliderField(title: "Анимация выезда", value: $module.settings.dockAnimation,
                                range: MouseDockSettings.animationRange, step: 0.05, unit: "с", fractionDigits: 2)
                    HStack {
                        Button("Мгновенно") { module.settings.dockDelay = 0; module.settings.dockAnimation = 0 }
                        Button("Быстро") { module.settings.dockDelay = 0; module.settings.dockAnimation = 0.25 }
                        Button("Как в системе") { module.settings.dockDelay = 0.5; module.settings.dockAnimation = 1 }
                    }
                    if !Self.isDockAutohideEnabled {
                        Label("Автоскрытие Dock выключено — эти настройки действуют только при автоскрытии (Системные настройки → Рабочий стол и Dock).",
                              systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                SettingsCaption(text: "Значения записываются в настройки Dock и действуют, даже когда Mac Utilities не запущена. При применении Dock на мгновение перезапускается — окна не закрываются. Выключите, чтобы вернуть прежние значения.")
            }
            .disabled(!module.isEnabled)

            Section("Указатель") {
                LabeledContent("Ускорение указателя") {
                    Text(module.isPointerLinear ? "Выключено — курсор движется линейно" : "Включено (стандарт macOS)")
                        .foregroundStyle(.secondary)
                }
                Button("Открыть настройки мыши") { module.openMouseSettings() }
                SettingsCaption(text: "Ускорение и скорость указателя меняются в Системных настройках → Мышь: применить их на лету может только сама macOS.")
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
            Toggle("Плавная прокрутка колесом", isOn: $module.settings.wheel.smooth)
            Toggle("Быстрое появление Dock", isOn: $module.settings.dockTweaksEnabled)
        }
    }
}
