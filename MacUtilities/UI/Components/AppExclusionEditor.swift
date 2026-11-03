import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Редактор списка приложений-исключений (по bundle identifier).
struct AppExclusionEditor: View {
    @Binding var bundleIDs: [String]
    var emptyText = L("Исключений нет")

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if bundleIDs.isEmpty {
                Text(emptyText).foregroundStyle(.secondary).font(.callout)
            }
            ForEach(bundleIDs, id: \.self) { bundleID in
                HStack(spacing: 8) {
                    Image(nsImage: AppInfo.icon(for: bundleID))
                        .resizable()
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(AppInfo.name(for: bundleID))
                        Text(bundleID).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { bundleIDs.removeAll { $0 == bundleID } } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(L("Убрать из исключений"))
                }
            }
            HStack {
                Menu(L("Добавить запущенное")) {
                    ForEach(runningApps, id: \.bundleIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "") {
                            add(app.bundleIdentifier)
                        }
                    }
                }
                .fixedSize()
                Button(L("Выбрать приложение…"), action: chooseApp)
            }
        }
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && !bundleIDs.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func add(_ bundleID: String?) {
        guard let bundleID, !bundleIDs.contains(bundleID) else { return }
        bundleIDs.append(bundleID)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            add(Bundle(url: url)?.bundleIdentifier)
        }
    }
}

enum AppInfo {
    static func url(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func name(for bundleID: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first, let name = app.localizedName {
            return name
        }
        if let url = url(for: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    static func icon(for bundleID: String) -> NSImage {
        if let url = url(for: bundleID) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: .application)
    }
}
