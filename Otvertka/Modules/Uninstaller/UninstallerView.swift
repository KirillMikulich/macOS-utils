import SwiftUI
import UniformTypeIdentifiers

struct UninstallerView: View {
    let module: UninstallerModule

    @State private var apps: [AppBundleInfo] = []
    @State private var query = ""
    @State private var selected: AppBundleInfo?
    @State private var leftovers: [LeftoverItem] = []
    @State private var appSize: Int64?
    @State private var isScanning = false
    @State private var isRemoving = false
    @State private var confirm = false
    @State private var report: UninstallReport?
    @State private var hasFullDiskAccess = UninstallerModule.hasFullDiskAccess

    var body: some View {
        HStack(spacing: 0) {
            appList
                .frame(width: 260)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await reloadApps() }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension == "app" }), let info = AppBundleInfo(url: url) else { return false }
            select(info)
            return true
        }
    }

    // MARK: - Список приложений

    private var appList: some View {
        VStack(spacing: 0) {
            TextField("Поиск приложений", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            List(filteredApps, id: \.bundleID, selection: Binding(
                get: { selected?.bundleID },
                set: { id in if let app = apps.first(where: { $0.bundleID == id }) { select(app) } })) { app in
                HStack(spacing: 8) {
                    Image(nsImage: app.icon).resizable().frame(width: 22, height: 22)
                    Text(app.name).lineLimit(1)
                }
                .tag(app.bundleID)
            }
            .listStyle(.sidebar)
            HStack {
                Button("Выбрать .app…", action: chooseApp)
                Spacer()
                Button { Task { await reloadApps() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Обновить список")
            }
            .padding(10)
        }
    }

    private var filteredApps: [AppBundleInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return apps }
        return apps.filter { $0.name.localizedStandardContains(trimmed) || $0.bundleID.localizedStandardContains(trimmed) }
    }

    // MARK: - Детали

    @ViewBuilder
    private var detail: some View {
        if let app = selected {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(nsImage: app.icon).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.title2.weight(.semibold))
                        Text([app.bundleID, app.version.map { "версия \($0)" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(app.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                }

                if !hasFullDiskAccess {
                    HStack(alignment: .top) {
                        Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Без «Полного доступа к диску» часть файлов может быть не видна, а macOS будет отдельно спрашивать доступ к данным других приложений.")
                                .font(.caption)
                            Button("Открыть настройки доступа") { module.openFullDiskAccessSettings() }.controlSize(.small)
                        }
                    }
                    .padding(8)
                    .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                if isScanning {
                    ProgressView("Поиск файлов…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    leftoverList(app)
                }

                if let report {
                    reportView(report)
                }

                HStack {
                    Text("Будет перемещено в Корзину: \(selectedCount + 1) объект(ов), \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))")
                        .font(.callout)
                    Spacer()
                    Button("Удалить в Корзину", role: .destructive) { confirm = true }
                        .keyboardShortcut(.delete, modifiers: .command)
                        .disabled(isRemoving || isScanning)
                }
            }
            .padding(16)
            .confirmationDialog("Переместить «\(app.name)» и выбранные файлы в Корзину?", isPresented: $confirm) {
                Button("Переместить в Корзину", role: .destructive) { remove(app) }
            } message: {
                Text(NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
                     ? "Файлы можно будет вернуть из Корзины."
                     : "Приложение запущено — оно будет закрыто. Файлы можно будет вернуть из Корзины.")
            }
        } else {
            ContentUnavailableView("Выберите приложение",
                                   systemImage: "trash.square",
                                   description: Text("Выберите программу в списке или перетащите .app сюда. Mac Utilities найдёт её настройки, кэши и другие файлы."))
        }
    }

    private func leftoverList(_ app: AppBundleInfo) -> some View {
        List {
            Section("Приложение") {
                HStack {
                    Image(systemName: "checkmark.square.fill").foregroundStyle(.secondary)
                    Text(app.url.lastPathComponent)
                    Spacer()
                    Text(appSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Section(leftovers.isEmpty ? "Связанные файлы не найдены" : "Связанные файлы (\(leftovers.count))") {
                ForEach($leftovers) { $item in
                    HStack(alignment: .firstTextBaseline) {
                        Toggle("", isOn: $item.isSelected).labelsHidden()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .lineLimit(1).truncationMode(.middle)
                            HStack(spacing: 6) {
                                Text(item.category)
                                Text("· \(item.match.title)")
                                if item.isSystemWide { Text("· может потребоваться пароль") }
                            }
                            .font(.caption).foregroundStyle(item.match == .bundleID ? Color.secondary : Color.orange)
                        }
                        Spacer()
                        Text(item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                            .foregroundStyle(.secondary).monospacedDigit()
                        Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "magnifyingglass") }
                            .buttonStyle(.borderless)
                            .help("Показать в Finder")
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func reportView(_ report: UninstallReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Перемещено в Корзину: \(report.trashed.count)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            ForEach(report.failed, id: \.url) { failure in
                Label("\(failure.url.lastPathComponent): \(failure.reason)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
    }

    private var selectedCount: Int { leftovers.filter(\.isSelected).count }

    private var totalSize: Int64 {
        (appSize ?? 0) + leftovers.filter(\.isSelected).compactMap(\.size).reduce(0, +)
    }

    // MARK: - Действия

    private func reloadApps() async {
        apps = await Task.detached(priority: .userInitiated) { UninstallerModule.installedApps() }.value
        hasFullDiskAccess = UninstallerModule.hasFullDiskAccess
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let info = AppBundleInfo(url: url) else { return }
        select(info)
    }

    private func select(_ app: AppBundleInfo) {
        selected = app
        report = nil
        leftovers = []
        appSize = nil
        guard !app.isProtected else {
            report = UninstallReport(failed: [(app.url, "Системные приложения Apple защищены macOS и не удаляются")])
            return
        }
        isScanning = true
        Task {
            let found = await Task.detached(priority: .userInitiated) { LeftoverScanner().scan(app) }.value
            guard selected == app else { return }
            leftovers = found
            isScanning = false
            // Размеры считаются в фоне и подставляются по мере готовности.
            appSize = await Task.detached(priority: .utility) { LeftoverScanner.size(of: app.url) }.value
            for item in found {
                let size = await Task.detached(priority: .utility) { LeftoverScanner.size(of: item.url) }.value
                guard selected == app, let index = leftovers.firstIndex(where: { $0.id == item.id }) else { continue }
                leftovers[index].size = size
            }
        }
    }

    private func remove(_ app: AppBundleInfo) {
        isRemoving = true
        Task {
            let result = await module.uninstall(app, items: leftovers)
            report = result
            isRemoving = false
            if result.failed.isEmpty {
                leftovers = []
                appSize = nil
                await reloadApps()
            }
        }
    }
}
