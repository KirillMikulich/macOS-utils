import SwiftUI

struct DashboardView: View {
    let coordinator: AppCoordinator

    /// Минимальная ширина плитки; число колонок подбирается по ширине окна.
    private let minCardWidth: CGFloat = 320

    var body: some View {
        GeometryReader { geometry in
            content(width: geometry.size.width)
        }
    }

    private func content(width: CGFloat) -> some View {
        let columns = max(1, min(3, Int((width - 40 + 16) / (minCardWidth + 16))))
        let modules = coordinator.registry.modules
        let rows = stride(from: 0, to: modules.count, by: columns).map { Array(modules[$0..<min($0 + columns, modules.count)]) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if coordinator.registry.isPaused {
                    HStack {
                        Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                        Text(L("Все модули приостановлены. Настройки включения сохранены."))
                        Spacer()
                        Button(L("Возобновить")) { coordinator.registry.setPaused(false) }
                    }
                    .padding(12)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
                // Grid: все плитки ряда одной высоты (по самой высокой), колонки одной ширины.
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 16) {
                    ForEach(rows.indices, id: \.self) { index in
                        GridRow {
                            ForEach(rows[index], id: \.id) { module in
                                ModuleCard(module: module) {
                                    coordinator.navigation.selection = .module(module.id)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            }
                            // Неполный последний ряд — пустые ячейки, чтобы плитки не растягивались.
                            ForEach(0..<(columns - rows[index].count), id: \.self) { _ in
                                Color.clear.gridCellUnsizedAxes([.vertical])
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private var header: some View {
        let modules = coordinator.registry.modules
        let running = modules.filter { $0.runState == .running }.count
        let off = modules.filter { !$0.isEnabled }.count
        let attention = modules.filter {
            switch $0.runState {
            case .waitingForPermissions, .failed: return true
            default: return false
            }
        }.count
        return HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Mac Utilities").font(.largeTitle.weight(.bold))
                Text(coordinator.registry.isPaused ? L("Все модули на паузе") : L("Всё под рукой — выберите модуль, чтобы настроить"))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                StatTile(value: running, title: L("работают"), color: .green)
                StatTile(value: off, title: L("выключены"), color: .secondary)
                if attention > 0 {
                    StatTile(value: attention, title: L("требуют внимания"), color: .orange)
                }
            }
        }
        .padding(20)
        .background {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            ZStack {
                shape.fill(.background.secondary)
                shape.fill(LinearGradient(colors: [.blue.opacity(0.22), .purple.opacity(0.14), .teal.opacity(0.08)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                shape.strokeBorder(.white.opacity(0.08))
            }
        }
    }
}

private struct StatTile: View {
    let value: Int
    let title: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title.weight(.semibold).monospacedDigit()).foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 84)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ModuleCard: View {
    let module: any AppModule
    let openDetails: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                SectionIcon(systemImage: module.systemImage, tint: module.id.tint, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.title).font(.headline)
                    HStack(spacing: 5) {
                        Circle().fill(module.runState.color).frame(width: 6, height: 6)
                        Text(statusText).font(.caption.weight(.medium)).foregroundStyle(module.runState.color)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(module.runState.color.opacity(0.12), in: Capsule())
                }
                Spacer()
                Toggle("", isOn: Binding(get: { module.isEnabled }, set: { module.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            // Описание всегда занимает 3 строки — разделитель ниже на одной высоте во всех плитках.
            Text(module.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3, reservesSpace: true)

            // Место под две горячие клавиши резервируется даже у модулей без них.
            VStack(alignment: .leading, spacing: 4) {
                    ForEach(module.shortcuts) { shortcut in
                        HStack {
                            Text(shortcut.title).font(.caption)
                            Spacer()
                            Text(shortcut.combo?.displayString ?? "—")
                                .font(.caption.monospaced())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                            let status = module.context.shortcuts.status(for: shortcut.id)
                            if status.isProblem {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help(status.message)
                            }
                        }
                    }
            }
            .frame(minHeight: 44, alignment: .top)

            if module.isEnabled {
                ForEach(module.context.permissions.missing(module.requiredPermissions)) { kind in
                    PermissionBanner(kind: kind, permissions: module.context.permissions)
                }
            }

            if case .failed(let message) = module.runState {
                Label(message, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()
            module.makeQuickSettingsView()
                .disabled(!module.isEnabled)

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(action: openDetails) {
                    Label(L("Настроить"), systemImage: "chevron.right")
                        .labelStyle(TrailingIconLabelStyle())
                }
                .buttonStyle(.borderedProminent)
                .tint(module.id.tint)
                .controlSize(.regular)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            ZStack {
                shape.fill(.background.secondary)
                // Цвет модуля размыто «подсвечивает» верх карточки.
                shape.fill(LinearGradient(colors: [module.id.tint.opacity(isHovered ? 0.2 : 0.12), .clear],
                                          startPoint: .top, endPoint: .center))
            }
            .shadow(color: .black.opacity(isHovered ? 0.22 : 0.1), radius: isHovered ? 14 : 6, y: isHovered ? 6 : 2)
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(isHovered ? module.id.tint.opacity(0.45) : Color.primary.opacity(0.08)))
        .scaleEffect(isHovered ? 1.01 : 1)
        .animation(.spring(duration: 0.25), value: isHovered)
        .onHover { isHovered = $0 }
    }

    private var statusText: String {
        switch module.runState {
        case .waitingForPermissions(let kinds):
            return L("Ожидает разрешения: ") + kinds.map { $0 == .accessibility ? "Accessibility" : "Screen Recording" }.joined(separator: ", ")
        default:
            return module.runState.title
        }
    }
}

/// Подпись слева, значок справа («Настроить ›»).
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.font(.caption.weight(.bold))
        }
    }
}
