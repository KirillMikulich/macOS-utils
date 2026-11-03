import SwiftUI

struct DockPreviewSection: Identifiable {
    let id: String
    let title: String?
    let windows: [WindowInfo]
}

/// Содержимое панели предпросмотра окон одного приложения.
struct WindowPreviewView: View {
    let model: WindowOverlayModel
    let appName: String
    var showAppName = false
    let sections: [DockPreviewSection]
    let style: WindowThumbnailStyle
    var actions: WindowCellActions?
    let onSelect: (WindowInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showAppName {
                Text(appName)
                    .font(.headline)
                    .padding(.horizontal, 6)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(sections) { section in
                        if let title = section.title {
                            Label(title, systemImage: "display")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 6)
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(style.cellWidth), spacing: style.spacing),
                                                 count: max(1, min(model.columns, section.windows.count))),
                                  alignment: .leading, spacing: style.spacing) {
                            ForEach(section.windows) { window in
                                WindowThumbnailCell(window: window, image: model.images[window.id],
                                                    isSelected: window.id == model.selectedID, style: style, actions: actions)
                                    .onTapGesture { onSelect(window) }
                                    .onHover { hovering in
                                        if hovering { model.selectedID = window.id }
                                    }
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(style.panelPadding)
        .background(OverlayBackground(opacity: 0.96))
        .overlayStyled()
    }
}
