import SwiftUI

/// Содержимое плавающей панели истории (вызывается горячей клавишей).
struct ClipboardHistoryPanelView: View {
    let module: ClipboardHistoryModule
    @Bindable var model: ClipboardPanelModel
    let controller: ClipboardPanelController
    @FocusState private var searchFocused: Bool

    var body: some View {
        let items = model.visibleItems(in: module.store)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Поиск в истории"), text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searchFocused)
                if module.settings.privateMode {
                    Label(L("Приватно"), systemImage: "eye.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(L("Режим приватности: новые копирования не записываются"))
                }
                Button {
                    module.clearHistory(includingPinned: false)
                    model.selectedID = nil
                    model.ensureSelection(in: model.visibleItems(in: module.store))
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(module.store.unpinnedItems.isEmpty)
                .help(L("Очистить историю (закреплённые останутся)"))
            }
            .padding(12)

            Divider()

            if items.isEmpty {
                ContentUnavailableView(model.query.isEmpty ? L("История пуста") : L("Ничего не найдено"),
                                       systemImage: model.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass",
                                       description: Text(model.query.isEmpty ? L("Скопируйте что-нибудь — элемент появится здесь.") : ""))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                ClipboardItemRow(item: item,
                                                 module: module,
                                                 index: index,
                                                 isSelected: item.id == model.selectedID,
                                                 showsActions: true,
                                                 onPaste: { controller.choose(item, action: .copyAndPaste) },
                                                 onCopy: { controller.choose(item, action: .copyToClipboard) })
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { controller.choose(item) }
                                    .onHover { if $0 { model.selectedID = item.id } }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: model.selectedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }

        }
        .frame(minWidth: 380, minHeight: 300)
        .background(OverlayBackground(opacity: 1))
        .overlayStyled()
        .onChange(of: model.query) { _, _ in
            model.selectedID = nil
            model.ensureSelection(in: model.visibleItems(in: module.store))
        }
        .onChange(of: model.focusToken, initial: true) { _, _ in
            DispatchQueue.main.async { searchFocused = true }
        }
    }
}

/// Строка элемента истории — используется в панели и в главном окне.
struct ClipboardItemRow: View {
    let item: ClipboardItem
    let module: ClipboardHistoryModule
    var index: Int?
    var isSelected: Bool
    var showsActions: Bool
    /// Кнопки «Вставить» и «Скопировать» (показываются, если заданы).
    var onPaste: (() -> Void)?
    var onCopy: (() -> Void)?

    @State private var thumbnail: NSImage?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            preview
                .frame(width: 44, height: 44)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 3) {
                Text(primaryText)
                    .lineLimit(2)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Label(item.kind.title, systemImage: item.kind.systemImage)
                        .labelStyle(.titleAndIcon)
                    if let app = item.sourceAppName { Text("· \(app)") }
                    Text("· \(item.lastUsedAt.formatted(.relative(presentation: .named)))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)

            if item.isPinned {
                Image(systemName: "pin.fill").foregroundStyle(.orange).font(.caption)
            }
            if showsActions && (isHovered || isSelected) {
                if let onPaste {
                    Button(action: onPaste) { Image(systemName: "arrow.down.doc") }
                        .buttonStyle(.borderless)
                        .help(L("Вставить в активное приложение"))
                }
                if let onCopy {
                    Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help(L("Скопировать в буфер (вставить потом — ⌘V)"))
                }
                Button { module.store.togglePin(item.id) } label: {
                    Image(systemName: item.isPinned ? "pin.slash" : "pin")
                }
                .buttonStyle(.borderless)
                .help(item.isPinned ? L("Открепить (⌘P)") : L("Закрепить — не удаляется лимитом и очисткой (⌘P)"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? OverlayStyle.shared.accent.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { isHovered = $0 }
        .task(id: item.id) {
            if item.kind == .image {
                thumbnail = await module.thumbnails.thumbnail(for: item, store: module.store)
            }
        }
    }

    private var primaryText: String {
        switch item.kind {
        case .files:
            return item.previewText.split(separator: "\n").map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        case .image:
            return item.imageSizeDescription.map { L("Изображение \($0)") } ?? item.previewText
        default:
            let text = item.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? L("(пробелы)") : text.replacingOccurrences(of: "\n", with: " ⏎ ")
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let thumbnail {
            Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
        } else if item.kind == .files, let path = item.previewText.split(separator: "\n").first {
            Image(nsImage: NSWorkspace.shared.icon(forFile: String(path))).resizable().padding(4)
        } else {
            Image(systemName: item.kind.systemImage)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
        }
    }
}
