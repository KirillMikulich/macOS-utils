import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FinderMenuSettingsView: View {
    @Bindable var module: FinderMenuModule

    var body: some View {
        Form {
            Section(L("Основное")) {
                Toggle(L("Включить «Меню Finder»"), isOn: Binding(get: { module.isEnabled }, set: { module.setEnabled($0) }))
                LabeledContent(L("Расширение Finder")) {
                    HStack(spacing: 8) {
                        Label(module.isExtensionEnabled ? L("Включено") : L("Выключено"),
                              systemImage: module.isExtensionEnabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(module.isExtensionEnabled ? .green : .orange)
                        Button(L("Открыть настройки"), action: module.openExtensionSettings)
                    }
                }
                SettingsCaption(text: L("Пункты появляются в меню правого клика по файлу, папке или пустому месту окна Finder. Если их нет — включите расширение Mac Utilities в Системных настройках → Основные → Объекты входа и расширения → Расширения → Finder."))
            }

            Section(L("Пункты меню")) {
                if module.settings.items.isEmpty {
                    Text(L("Пунктов нет — добавьте ниже")).foregroundStyle(.secondary)
                }
                ForEach($module.settings.items) { $item in
                    FinderMenuItemRow(item: $item,
                                      canMoveUp: item.id != module.settings.items.first?.id,
                                      canMoveDown: item.id != module.settings.items.last?.id,
                                      move: { move(item.id, by: $0) },
                                      remove: { module.settings.items.removeAll { $0.id == item.id } })
                }
                HStack {
                    Button(L("Открыть в приложении…"), action: chooseApp)
                    Menu(L("Другое")) {
                        Button(L("Скопировать путь")) {
                            module.settings.items.append(FinderMenuItem(title: L("Скопировать путь"), action: .copyPath))
                        }
                        Button(L("Новый текстовый файл")) {
                            module.settings.items.append(FinderMenuItem(title: L("Новый текстовый файл"), action: .newFile, forFiles: false))
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Button(L("Сбросить по умолчанию")) { module.settings.items = FinderMenuModule.defaultItems() }
                }
                SettingsCaption(text: L("Название можно изменить прямо в списке. Галочки — где показывать пункт: на файлах, на папках, на пустом месте окна (тогда действие применяется к открытой папке)."))
            }
        }
        .formStyle(.grouped)
        .onAppear { module.refreshExtensionState() }
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = module.settings.items.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard module.settings.items.indices.contains(target) else { return }
        module.settings.items.swapAt(index, target)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("Выбрать")
        if panel.runModal() == .OK, let url = panel.url {
            module.addOpenWithApp(url)
        }
    }
}

private struct FinderMenuItemRow: View {
    @Binding var item: FinderMenuItem
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                icon.resizable().frame(width: 20, height: 20)
                TextField("", text: $item.title)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                Button { move(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(!canMoveUp)
                    .help(L("Выше"))
                Button { move(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(!canMoveDown)
                    .help(L("Ниже"))
                Button(action: remove) { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                    .help(L("Удалить пункт"))
            }
            .buttonStyle(.borderless)
            HStack(spacing: 14) {
                Text(actionDescription).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Toggle(L("Файлы"), isOn: $item.forFiles)
                Toggle(L("Папки"), isOn: $item.forFolders)
                Toggle(L("Фон окна"), isOn: $item.forBackground)
            }
            .toggleStyle(.checkbox)
            .font(.caption)
        }
        .padding(.vertical, 2)
    }

    private var icon: Image {
        switch item.action {
        case .openWithApp:
            return Image(nsImage: NSWorkspace.shared.icon(forFile: item.appPath ?? "/Applications"))
        case .copyPath:
            return Image(systemName: "doc.on.doc")
        case .newFile:
            return Image(systemName: "doc.badge.plus")
        }
    }

    private var actionDescription: String {
        switch item.action {
        case .openWithApp:
            let name = item.appPath.map { FileManager.default.displayName(atPath: $0) } ?? "?"
            return L("Открывает в «\(name)»")
        case .copyPath:
            return L("Копирует путь в буфер обмена")
        case .newFile:
            return L("Создаёт пустой .txt и выделяет его")
        }
    }
}

struct FinderMenuQuickView: View {
    @Bindable var module: FinderMenuModule

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Пунктов в меню: \(module.settings.items.count)")).font(.caption).foregroundStyle(.secondary)
            if module.isEnabled && !module.isExtensionEnabled {
                Button(L("Включить расширение Finder…"), action: module.openExtensionSettings)
            }
        }
    }
}
