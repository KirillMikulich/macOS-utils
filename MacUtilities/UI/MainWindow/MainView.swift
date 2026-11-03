import SwiftUI

/// Главное окно: собственная боковая панель и фон вместо системного NavigationSplitView.
struct MainView: View {
    let coordinator: AppCoordinator
    @Bindable private var navigation: NavigationModel

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.navigation = coordinator.navigation
    }

    private var selection: SidebarSection { navigation.selection ?? .dashboard }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(coordinator: coordinator, selection: $navigation.selection)
                .frame(width: 236)
            // Явный минимум: формы настроек сообщают «идеальную» высоту всего содержимого
            // (до 1100+ pt), и без этого окно растягивалось на весь экран или содержимое
            // вылезало за его края. Теперь длинные формы прокручиваются внутри окна.
            detail
                .id(selection)
                .transition(.opacity.combined(with: .offset(y: 6)))
                .frame(minWidth: 520, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
                .background(AppBackdrop(tint: selectionTint))
        }
        .animation(.easeOut(duration: 0.18), value: selection)
        // Формы «плавают» карточками на общем фоне, а не на системной серой подложке.
        .scrollContentBackground(.hidden)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var selectionTint: Color {
        switch selection {
        case .dashboard: return .blue
        case .module(let id): return id.tint
        case .general, .about: return .gray
        case .permissions: return .green
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .dashboard:
            DashboardView(coordinator: coordinator)
                .padding(.top, 28)
        case .module(let id):
            if let module = coordinator.registry.module(id) {
                VStack(spacing: 0) {
                    PageHeader(title: module.title, subtitle: module.summary,
                               systemImage: module.systemImage, tint: id.tint) {
                        StatusPill(state: module.runState)
                    }
                    if id == .uninstaller {
                        module.makeSettingsView()
                    } else {
                        module.makeSettingsView().readableWidth()
                    }
                }
            }
        case .general:
            page("Основные", "Запуск, значки и оформление панелей", "gearshape", .gray) {
                GeneralSettingsView(coordinator: coordinator)
            }
        case .permissions:
            page("Разрешения", "Доступы macOS, которые нужны модулям", "lock.shield", .green) {
                PermissionsView(coordinator: coordinator)
            }
        case .about:
            page("О программе", "Версия, данные и использованный код", "info.circle", .gray) {
                AboutView(coordinator: coordinator)
            }
        }
    }

    private func page(_ title: String, _ subtitle: String, _ icon: String, _ tint: Color,
                      @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            PageHeader(title: title, subtitle: subtitle, systemImage: icon, tint: tint) { EmptyView() }
            content().readableWidth()
        }
    }
}

private extension View {
    /// Формы не растягиваются на всё окно — колонка по центру.
    func readableWidth() -> some View {
        frame(maxWidth: 760).frame(maxWidth: .infinity)
    }
}

// MARK: - Фон

/// Фон содержимого: мягкие цветные «пятна» в цвет раздела поверх базового цвета окна.
private struct AppBackdrop: View {
    let tint: Color

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [tint.opacity(0.22), .clear], center: .topTrailing, startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color.purple.opacity(0.10), .clear], center: .bottomLeading, startRadius: 0, endRadius: 600)
        }
        .animation(.easeInOut(duration: 0.35), value: tint)
        .ignoresSafeArea()
    }
}

// MARK: - Боковая панель

private struct Sidebar: View {
    let coordinator: AppCoordinator
    @Binding var selection: SidebarSection?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Отступ сверху — под кнопки окна (заголовок прозрачный).
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Mac Utilities").font(.headline)
                    Text("набор утилит").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 48)
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row(.dashboard, "Обзор", "square.grid.2x2", .blue)

                    groupTitle("Модули")
                    ForEach(coordinator.registry.modules, id: \.id) { module in
                        row(.module(module.id), module.title, module.systemImage, module.id.tint) {
                            Circle()
                                .fill(module.runState.color)
                                .frame(width: 6, height: 6)
                                .shadow(color: module.runState.color.opacity(0.8), radius: 3)
                                .help(module.runState.title)
                        }
                    }

                    groupTitle("Приложение")
                    row(.general, "Основные", "gearshape", .gray)
                    row(.permissions, "Разрешения", "lock.shield", .green) {
                        if missingPermissions {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    row(.about, "О программе", "info.circle", .gray)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)

            pauseFooter
        }
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                LinearGradient(colors: [.blue.opacity(0.06), .purple.opacity(0.05)], startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1).ignoresSafeArea()
        }
    }

    private var missingPermissions: Bool {
        coordinator.registry.modules
            .filter(\.isEnabled)
            .flatMap(\.requiredPermissions)
            .contains { !coordinator.permissions.isGranted($0) }
    }

    private func groupTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }

    private func row(_ section: SidebarSection, _ title: String, _ icon: String, _ tint: Color,
                     @ViewBuilder accessory: () -> some View = { EmptyView() }) -> some View {
        SidebarRow(title: title, icon: icon, tint: tint, isSelected: (selection ?? .dashboard) == section,
                   accessory: accessory()) {
            selection = section
        }
    }

    /// Глобальная пауза — прямо в панели, без похода в строку меню.
    private var pauseFooter: some View {
        let paused = coordinator.registry.isPaused
        return Button {
            coordinator.registry.setPaused(!paused)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: paused ? "play.fill" : "pause.fill")
                Text(paused ? "Возобновить модули" : "Пауза всех модулей")
                Spacer()
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(paused ? Color.orange : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(12)
    }
}

private struct SidebarRow<Accessory: View>: View {
    let title: String
    let icon: String
    let tint: Color
    let isSelected: Bool
    let accessory: Accessory
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SectionIcon(systemImage: icon, tint: tint, size: 24)
                Text(title)
                    .font(.body.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 4)
                accessory
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                if isSelected {
                    shape.fill(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.14)],
                                              startPoint: .leading, endPoint: .trailing))
                        .overlay(shape.strokeBorder(tint.opacity(0.35)))
                        .shadow(color: tint.opacity(0.25), radius: 6, y: 2)
                } else if isHovered {
                    shape.fill(Color.primary.opacity(0.06))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Шапка страницы

private struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            SectionIcon(systemImage: systemImage, tint: tint, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 26, weight: .bold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .frame(maxWidth: 760 - 40)
        .padding(.horizontal, 20)
        .padding(.top, 40)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
    }
}

private struct StatusPill: View {
    let state: ModuleRunState

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(state.color).frame(width: 7, height: 7)
                .shadow(color: state.color.opacity(0.8), radius: 3)
            Text(state.title).font(.callout.weight(.medium)).foregroundStyle(state.color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(state.color.opacity(0.13), in: Capsule())
        .overlay(Capsule().strokeBorder(state.color.opacity(0.3)))
    }
}
