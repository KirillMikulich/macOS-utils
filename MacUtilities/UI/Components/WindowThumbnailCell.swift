import AppKit
import Observation
import SwiftUI

/// Наблюдаемое состояние оверлея со списком окон.
@MainActor
@Observable
final class WindowOverlayModel {
    var windows: [WindowInfo] = []
    var selectedID: String?
    var images: [String: CGImage] = [:]
    var columns = 1

    func reset(windows: [WindowInfo], selectedID: String?) {
        self.windows = windows
        self.selectedID = selectedID
        // Старые изображения оставляем только для окон, которые всё ещё в списке.
        let ids = Set(windows.map(\.id))
        images = images.filter { ids.contains($0.key) }
    }
}

/// Общие настройки внешнего вида миниатюр (Переключение окон и Превью в Dock).
protocol ThumbnailAppearanceSettings {
    var thumbnailSize: Double { get set }
    var showTitles: Bool { get set }
    var showThumbnails: Bool { get set }
    var iconSize: Double { get set }
    var cellPadding: Double { get set }
    var itemSpacing: Double { get set }
    var panelPadding: Double { get set }
}

enum ThumbnailAppearanceRange {
    static let thumbnail = 40.0...400.0
    static let icon = 16.0...128.0
    static let cellPadding = 0.0...24.0
    static let spacing = 0.0...24.0
    static let panelPadding = 0.0...40.0
}

extension ThumbnailAppearanceSettings {
    var thumbnailStyle: WindowThumbnailStyle {
        WindowThumbnailStyle(thumbnailWidth: thumbnailSize, showTitles: showTitles, showThumbnails: showThumbnails,
                             iconSize: iconSize, cellPadding: cellPadding, spacing: itemSpacing, panelPadding: panelPadding)
    }
}

struct WindowThumbnailStyle {
    var thumbnailWidth: CGFloat
    var showTitles: Bool
    /// false — вместо миниатюры окна показывается только значок приложения.
    var showThumbnails = true
    var iconSize: CGFloat = 48
    var cellPadding: CGFloat = 8
    var spacing: CGFloat = 6
    var panelPadding: CGFloat = 14
    var showAppIcon = true

    /// Размер «плитки»: миниатюра окна или (в режиме значков) квадрат значка.
    var tileWidth: CGFloat { showThumbnails ? thumbnailWidth : iconSize }
    var tileHeight: CGFloat { showThumbnails ? (thumbnailWidth * 0.62).rounded() : iconSize }
    /// В режиме значков подпись шире самого значка, иначе её было бы не прочитать.
    var contentWidth: CGFloat { (!showThumbnails && showTitles) ? max(tileWidth, 96) : tileWidth }
    var titleHeight: CGFloat { showTitles ? 28 : 0 }
    var cellWidth: CGFloat { contentWidth + cellPadding * 2 }
    var cellHeight: CGFloat { tileHeight + titleHeight + cellPadding * 2 }

    /// Вертикальный список Переключение окон.
    static let listWidth: CGFloat = 440
    var listRowHeight: CGFloat { max(iconSize, 34) + cellPadding * 2 }
}

/// Действия над окном из оверлея (кнопки на миниатюре).
struct WindowCellActions {
    var close: (WindowInfo) -> Void
    var minimize: (WindowInfo) -> Void
    var quitApp: (WindowInfo) -> Void
}

/// Ячейка: миниатюра окна (или значок приложения, если миниатюры нет) + заголовок.
struct WindowThumbnailCell: View {
    let window: WindowInfo
    let image: CGImage?
    let isSelected: Bool
    let style: WindowThumbnailStyle
    var actions: WindowCellActions?

    @State private var isHovered = false

    var body: some View {
        content
            .overlay(alignment: .topTrailing) {
                if let actions, isSelected || isHovered {
                    HStack(spacing: 4) {
                        actionButton("minus", help: L("Свернуть окно (⌥M)")) { actions.minimize(window) }
                            .disabled(window.isMinimized)
                        actionButton("power", help: L("Завершить «\(window.appName)» со всеми окнами (⌥Q)")) { actions.quitApp(window) }
                        if QuitOnClosePolicy.closeQuitsApp(window) {
                            // Последнее окно: «Автовыход» завершит приложение после закрытия.
                            actionButton("xmark", help: L("Это последнее окно — после закрытия «Автовыход» завершит «\(window.appName)» (⌥W)"),
                                         tint: .orange) { actions.close(window) }
                        } else {
                            actionButton("xmark", help: L("Закрыть только это окно (⌥W)"), tint: .red) { actions.close(window) }
                        }
                    }
                    .padding(style.cellPadding + 4)
                }
            }
            .onHover { isHovered = $0 }
    }

    private func actionButton(_ symbol: String, help: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.separator))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var content: some View {
        VStack(spacing: 6) {
            ZStack {
                if !style.showThumbnails {
                    if let icon = window.appIcon {
                        Image(nsImage: icon).resizable().frame(width: style.iconSize, height: style.iconSize)
                    }
                } else if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary.opacity(0.6))
                        .overlay {
                            if let icon = window.appIcon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: min(style.iconSize, style.tileHeight * 0.7), height: min(style.iconSize, style.tileHeight * 0.7))
                            }
                        }
                }
                if window.isMinimized || window.isAppHidden {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Label(window.isMinimized ? L("Свёрнуто") : L("Скрыто"), systemImage: window.isMinimized ? "minus.square" : "eye.slash")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.thinMaterial, in: Capsule())
                                .padding(4)
                        }
                    }
                }
            }
            .frame(width: style.tileWidth, height: style.tileHeight)

            if style.showTitles {
                HStack(spacing: 5) {
                    if style.showAppIcon, style.showThumbnails, let icon = window.appIcon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    }
                    Text(window.displayTitle)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(width: style.contentWidth, height: 22)
                .help("\(window.appName) — \(window.displayTitle)")
            }
        }
        .frame(width: style.contentWidth)
        .padding(style.cellPadding)
        .background(isSelected ? OverlayStyle.shared.accent.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? OverlayStyle.shared.accent : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
}

/// Общий блок настроек внешнего вида миниатюр для Переключение окон и Превью в Dock.
struct ThumbnailAppearanceControls<Settings: ThumbnailAppearanceSettings>: View {
    @Binding var settings: Settings

    var body: some View {
        ThumbnailAppearancePreview(style: settings.thumbnailStyle)
        Toggle(L("Показывать миниатюры окон"), isOn: $settings.showThumbnails)
        SettingsCaption(text: settings.showThumbnails
            ? L("Миниатюры требуют разрешения «Запись экрана»; без него вместо них показываются значки.")
            : L("Вместо миниатюр показываются только значки приложений — компактно и без «Записи экрана»."))
        if settings.showThumbnails {
            slider(L("Размер миниатюр"), value: $settings.thumbnailSize, range: ThumbnailAppearanceRange.thumbnail, step: 4, unit: "pt")
        }
        slider(L("Размер значка"), value: $settings.iconSize, range: ThumbnailAppearanceRange.icon, step: 2, unit: "pt")
        slider(L("Отступ внутри ячейки"), value: $settings.cellPadding, range: ThumbnailAppearanceRange.cellPadding, step: 1, unit: "pt")
        slider(L("Расстояние между ячейками"), value: $settings.itemSpacing, range: ThumbnailAppearanceRange.spacing, step: 1, unit: "pt")
        slider(L("Отступ панели"), value: $settings.panelPadding, range: ThumbnailAppearanceRange.panelPadding, step: 1, unit: "pt")
        Toggle(L("Показывать заголовки окон"), isOn: $settings.showTitles)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        SliderField(title: title, value: value, range: range, step: step, unit: unit)
    }
}

/// Живой предпросмотр панели в настройках: те же ячейки, что в настоящей панели,
/// для нескольких запущенных приложений (без захвата экрана — вместо миниатюр заглушки).
struct ThumbnailAppearancePreview: View {
    let style: WindowThumbnailStyle
    private let maxWidth: CGFloat = 460

    private var sampleWindows: [WindowInfo] {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.localizedName != nil }
            .prefix(3)
        return apps.enumerated().map { index, app in
            WindowInfo(id: "preview-\(index)", windowID: nil, pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                       appName: app.localizedName ?? "", title: app.localizedName ?? "", frame: .zero, zIndex: index)
        }
    }

    var body: some View {
        let windows = sampleWindows
        let width = CGFloat(windows.count) * (style.cellWidth + style.spacing) - style.spacing + style.panelPadding * 2
        let height = style.cellHeight + style.panelPadding * 2
        let scale = min(1, maxWidth / max(width, 1))
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Предпросмотр")).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: style.spacing) {
                ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                    WindowThumbnailCell(window: window, image: nil, isSelected: index == 1, style: style)
                }
            }
            .padding(style.panelPadding)
            .background(OverlayBackground(opacity: 0.95))
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: width * scale, height: height * scale, alignment: .topLeading)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: style.cellWidth + style.cellHeight + style.spacing + style.panelPadding)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 4)
    }
}
