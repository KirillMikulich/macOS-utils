import SwiftUI

struct WindowSwitcherView: View {
    let model: WindowOverlayModel
    let settings: WindowSwitcherSettings
    var actions: WindowCellActions?
    let onSelect: (WindowInfo) -> Void
    let onHover: (WindowInfo) -> Void

    private var style: WindowThumbnailStyle {
        settings.thumbnailStyle
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                Group {
                    switch settings.layout {
                    case .horizontal: grid
                    case .vertical: list
                    }
                }
                .padding(style.panelPadding)
            }
            .scrollIndicators(.never)
            .onChange(of: model.selectedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .background(OverlayBackground(opacity: settings.backgroundOpacity))
        .overlayStyled()
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(style.cellWidth), spacing: style.spacing), count: max(1, model.columns)),
                  spacing: style.spacing) {
            // При группировке окна одного приложения уже идут подряд (см. WindowListBuilder).
            ForEach(model.windows) { window in
                WindowThumbnailCell(window: window, image: model.images[window.id],
                                    isSelected: window.id == model.selectedID, style: style, actions: actions)
                .id(window.id)
                .onTapGesture { onSelect(window) }
                .onHover { if $0 && settings.selectOnHover { onHover(window) } }
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: style.spacing) {
            ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
                if settings.groupByApp, index == 0 || model.windows[index - 1].pid != window.pid {
                    Text(window.appName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, index == 0 ? 0 : 6)
                        .padding(.leading, 6)
                }
                HStack(spacing: 10) {
                    Group {
                        if style.showThumbnails, let image = model.images[window.id] {
                            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        } else if let icon = window.appIcon {
                            Image(nsImage: icon).resizable().frame(width: style.iconSize, height: style.iconSize)
                        }
                    }
                    .frame(width: style.showThumbnails ? style.iconSize * 1.6 : style.iconSize, height: style.iconSize)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(window.displayTitle).lineLimit(1)
                        Text(window.isMinimized ? L("\(window.appName) · свёрнуто") : window.appName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(style.cellPadding)
                .frame(width: WindowThumbnailStyle.listWidth)
                .background(window.id == model.selectedID ? OverlayStyle.shared.accent.opacity(0.28) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .id(window.id)
                .onTapGesture { onSelect(window) }
                .onHover { if $0 && settings.selectOnHover { onHover(window) } }
            }
        }
    }
}
