import AppKit
import ApplicationServices

/// Снимок информации об одном окне другого приложения.
/// Структура не содержит изображений: миниатюры загружаются отдельно и по требованию.
struct WindowInfo: Identifiable, Hashable {
    /// Стабильный в пределах жизни окна идентификатор.
    let id: String
    let windowID: CGWindowID?
    let pid: pid_t
    let bundleID: String?
    let appName: String
    let title: String
    /// Рамка в координатах AX (начало — левый верхний угол главного экрана).
    let frame: CGRect
    let isMinimized: Bool
    let isAppHidden: Bool
    /// Порядок по глубине: 0 — самое верхнее окно. Свёрнутые и скрытые окна идут после видимых.
    let zIndex: Int
    /// AX-элемент окна; nil в тестах или если окно получено только из CGWindowList.
    let element: AXUIElement?

    init(id: String? = nil,
         windowID: CGWindowID?,
         pid: pid_t,
         bundleID: String?,
         appName: String,
         title: String,
         frame: CGRect,
         isMinimized: Bool = false,
         isAppHidden: Bool = false,
         zIndex: Int,
         element: AXUIElement? = nil) {
        self.id = id ?? "\(pid)-\(windowID.map(String.init) ?? "\(title.hashValue)-\(Int(frame.minX))-\(Int(frame.minY))")"
        self.windowID = windowID
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
        self.isAppHidden = isAppHidden
        self.zIndex = zIndex
        self.element = element
    }

    var displayTitle: String {
        title.isEmpty ? appName : title
    }

    /// Экран, на котором находится большая часть окна.
    var screen: NSScreen? {
        let cocoaFrame = frame.flippedToCocoa
        return NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(cocoaFrame).area < rhs.frame.intersection(cocoaFrame).area
        }
    }

    var appIcon: NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.isMinimized == rhs.isMinimized
            && lhs.zIndex == rhs.zIndex && lhs.frame == rhs.frame && lhs.isAppHidden == rhs.isAppHidden
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
