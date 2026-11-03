import SwiftUI

struct PermissionsView: View {
    let coordinator: AppCoordinator

    var body: some View {
        let permissions = coordinator.permissions
        Form {
            Section {
                SettingsCaption(text: "Mac Utilities не запрашивает разрешения заранее — только когда вы включаете модуль, которому они нужны. Глобальные горячие клавиши работают без дополнительных разрешений (Carbon RegisterEventHotKey). Разрешение «Мониторинг ввода» не используется.")
            }
            ForEach(PermissionKind.allCases) { kind in
                Section {
                    HStack {
                        Label(kind.title, systemImage: kind.systemImage).font(.headline)
                        Spacer()
                        if permissions.isGranted(kind) {
                            Label("Выдано", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Label("Не выдано", systemImage: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                    Text(kind.purpose).font(.callout)
                    LabeledContent("Используется модулями", value: modules(using: kind))
                    SettingsCaption(text: kind.instructions)
                    HStack {
                        if !permissions.isGranted(kind) {
                            Button("Запросить / открыть настройки") { permissions.request(kind) }
                        } else {
                            Button("Открыть настройки macOS") { permissions.openSettings(for: kind) }
                        }
                        Button("Проверить снова") { permissions.refresh() }
                        if kind == .screenRecording && !permissions.isGranted(kind) {
                            Button("Перезапустить приложение") { Self.relaunch() }
                                .help("macOS иногда применяет разрешение на запись экрана только после перезапуска")
                        }
                    }
                }
            }
            if let date = permissions.lastChecked {
                Section {
                    LabeledContent("Последняя проверка", value: date.formatted(date: .omitted, time: .standard))
                    SettingsCaption(text: "При ad-hoc подписи (сборка без Apple ID) macOS привязывает разрешения к конкретной сборке, и после пересборки их может понадобиться выдать заново: удалите Mac Utilities из списка кнопкой «–» и добавьте снова.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func modules(using kind: PermissionKind) -> String {
        let names = coordinator.registry.modules.compactMap { module -> String? in
            if module.requiredPermissions.contains(kind) { return "\(module.title) (обязательно)" }
            if module.optionalPermissions.contains(kind) { return "\(module.title) (по желанию)" }
            return nil
        }
        return names.isEmpty ? "—" : names.joined(separator: ", ")
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
